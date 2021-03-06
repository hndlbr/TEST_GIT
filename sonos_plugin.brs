' Plug-in script for BA 3.8.0.26 and greater

Function sonos_Initialize(msgPort As Object, userVariables As Object, bsp as Object)

    print "Sonos_Initialize - entry"
    print "type of msgPort is ";type(msgPort)
    print "type of userVariables is ";type(userVariables)

    Sonos = newSonos(msgPort, userVariables, bsp)

    return Sonos

End Function


Function newSonos(msgPort As Object, userVariables As Object, bsp as Object)
	print "initSonos"

	' Create the object to return and set it up
	s = {}

	s.version = "3.18"

	s.configVersion = "1.0"
	registrySection = CreateObject("roRegistrySection", "networking")
    if type(registrySection)="roRegistrySection" then
		value$ = registrySection.Read("cfv")
		if Len(value$) > 0 then
			s.configVersion = value$
		else
			' If no time server, assume config 1.1
			value$ = registrySection.Read("ts")
			if Len(value$) = 0 then
				s.configVersion = "1.1"
			end if
		end if
	end if

	s.msgPort = msgPort
	s.userVariables = userVariables
	s.bsp = bsp
	s.ProcessEvent = sonos_ProcessEvent
	s.objectName = "sonos_object"
	s.disco = invalid 
	s.bootseq ="" 'a number that is the number of times rebooted since some start point... factory reset?'

	' Create timer to renew register events, we will renew every hour at 15 mins past the hour
	s.timer=CreateObject("roTimer")  
	s.timer.SetPort(msgPort) 
	s.timer.SetDate(-1, -1, -1) 
	s.timer.SetTime(-1, 25, 0, 0) 
	s.timer.Start()

	s.st=CreateObject("roSystemTime")
	'TIMING print "Sonos Plugin created at: ";s.st.GetLocalDateTime()
	
	' Reset some critical variables
	if (s.userVariables["aliveTimeoutSeconds"] <> invalid) then
		s.userVariables["aliveTimeoutSeconds"].Reset(False)
	end if
	if (s.userVariables["msearchRepeatCount"] <> invalid) then
		s.userVariables["msearchRepeatCount"].Reset(False)
	end if
	if (s.userVariables["subBondTo"] <> invalid) then
		s.userVariables["subBondTo"].Reset(False)
	end if
	if (s.userVariables["requiresManualUpdate"] <> invalid) then
		s.userVariables["requiresManualUpdate"].Reset(False)
	end if

	' Create timer to see if players have gone away
	s.timerAliveCheck=CreateObject("roTimer")  
	s.timerAliveCheck.SetPort(msgPort)
	s.accelerateAliveCheck = False
	StartAliveCheckTimer(s)
	
	' Create timer to check topology (only if SUB bonding is enabled by user var)
	if s.userVariables["subBondTo"] <> invalid and s.userVariables["subBondTo"].currentValue$ <> "none" then
		s.timerTopologyCheck = CreateObject("roTimer")
		s.timerTopologyCheck.SetPort(msgPort)
		StartTopologyCheckTimer(s)
	end if

	' Need to remove once all instances of this are taken out of the Sonos code
	s.mp = msgPort

	' Create the http server for this app, use port 111 since 80 will be used by DWS
	s.server = CreateObject("roHttpServer", { port: 111 })
	if (s.server = invalid) then
		print "Unable to create server on port 111"
		'Need to reboot here - can't stop in the Init function
		RebootSystem()
	end if
	s.server.SetPort(msgPort)

	' Create the arrary to hold the Sonos devices
	s.sonosDevices = CreateObject("roArray",1, True)

	' Create the array to hold all UPnP devices found
	s.devices = CreateObject("roArray",1, True)

	' Create an array to hold roUrlTransferObject that are being used by the SOAP commands
	s.xferObjects = createObject("roArray",0, true)

	' Create an array to hold roUrlTransferObject from normal POSTs 
	s.postObjects = createObject("roArray",0, true)

	' Create an array to hold commands that have come in when the device is busy processing other commands
	s.commandQ = createObject("roArray",0, true)

	' Create the array to hold the deleted devices
	s.deletedDevices = CreateObject("roArray",1, True)

	' Variable for what is considered the master device
	s.masterDevice = "none"
	s.masterDeviceLastTransportURI=""

	' Keep track of all the devices that should be grouped for playing together
	' TODO - is this still used?
	s.playingGroup = createObject("roArray",0, true)

	' Create the UDP receiver port for the Sonos commands
	s.udpReceiverPort = 21000
	s.udpReceiver = CreateObject("roDatagramReceiver", s.udpReceiverPort)
	s.udpReceiver.SetPort(msgPort)

	' create the site's hhid 
	bspDevice = CreateObject("roDeviceInfo")
	bspSerial$= bspDevice.GetDeviceUniqueId()
	s.hhid="Sonos_RDM_"+bspSerial$
	' DND-226 - HHID string must be exactly 32 characters
	hhidlen = Len(s.hhid)
	if hhidlen < 32 then
		s.hhid = s.hhid + "_"
		hhidlen = Len(s.hhid)
		while hhidlen < 32
			s.hhid = s.hhid + "0"
			hhidlen = hhidlen + 1
		end while
	end if
    if s.userVariables["siteHHID"] <> invalid
	    updateUserVar(s.userVariables,"siteHHID",s.hhid,false)
    else
        print "siteHHID user variable does not exist"
    end if
    setDebugPrintBehavior(s)

    print "***************************  Sonos plugin version ";s.version;"*************************** "
    if s.userVariables["pluginVersion"] <> invalid
	    updateUserVar(s.userVariables,"pluginVersion",s.version,false)
    else
        print "pluginVersion user variable does not exist"
    end if

    print "***************************  Sonos config version ";s.configVersion;"*************************** "
    if s.userVariables["configVersion"] <> invalid
	    updateUserVar(s.userVariables,"configVersion",s.configVersion,false)
    else
        print "configVersion user variable does not exist"
    end if
	
	' set up infoString variable with version numbers, if default value = "versions"
	if s.userVariables["infoString"] <> invalid and s.userVariables["infoString"].defaultValue$ = "versions" then
		info$ = s.version + " / " + s.configVersion
		updateUserVar(s.userVariables,"infoString",info$,false)
	end if

    ' make certain that we set the runningState to booting no matter what state we got left in'
    updateUserVar(s.userVariables,"runningState", "booting",true)

	return s
End Function

Sub StartAliveCheckTimer(s as object)
	timeout=s.st.GetLocalDateTime()
	if s.accelerateAliveCheck then
		delay = 60
	else
		delay=600
		if (s.userVariables["aliveTimeoutSeconds"] <> invalid) then
			d=s.userVariables["aliveTimeoutSeconds"].currentValue$
			delay=val(d)
		end if
	end if
	timeout.AddSeconds(delay)
	s.timerAliveCheck.SetDateTime(timeout)
	s.timerAliveCheck.Start()
End Sub

Sub StartTopologyCheckTimer(s as object)
	if s.timerTopologyCheck <> invalid then
		timeout=s.st.GetLocalDateTime()
		timeout.AddSeconds(125)
		s.timerTopologyCheck.SetDateTime(timeout)
		s.timerTopologyCheck.Start()
	end if
End Sub


sub setDebugPrintBehavior(s as object)
    if s.userVariables["debugPrint"] <> invalid
	    debugPrintString=s.userVariables["debugPrint"].currentValue$
		r2 = CreateObject("roRegex", "!", "i")
		fields=r2.split(debugPrintString)
		for each f in fields
		   if f="events"
	           s.debugPrintEvents=true
		   else if f="learn_timing"
		       s.debugPrintLearnTiming=true
		   end if
		end for
    else
       s.debugPrintEvents=false
       s.debugPrintLearnTiming=false
    end if
end sub

Function sonos_ProcessEvent(event As Object) as boolean

	retval = false

	if type(event) = "roAssociativeArray" then
        if type(event["EventType"]) = "roString"
            if (event["EventType"] = "SEND_PLUGIN_MESSAGE") then
                if event["PluginName"] = "sonos" then
                    pluginMessage$ = event["PluginMessage"]
                    retval = ParseSonosPluginMsg(pluginMessage$, m)
                endif
            endif
        endif
	else if type(event) = "roDatagramEvent" and type(event.GetUserData()) = "roAssociativeArray" and type(event.GetUserData().OnEvent) = "roFunction" then
		event.GetUserData().OnEvent(event)
		retval = true
	else if type(event) = "roDatagramEvent" then
		msg$ = event
		if (left(msg$,5) = "sonos") then
			print "*********************************************  UDP EVENT - move to plug in message  ***************************************"
			print msg$
			print "***************************************************************************************************************************"
			' commented out for testing'
			'stop
		end if
		retval = ParseSonosPluginMsg(msg$, m)
	else if (type(event) = "roUrlEvent") and (type(event.GetUserData()) = "roAssociativeArray") and (event.GetUserData().objectName = "sonos_object") then
		'print "Got roUrlEvent - now processing the XML"
		UPNPDiscoverer_ProcessDeviceXML(event)
		retval = true
	else if (type(event) = "roUrlEvent") then
		'print "*****  Got roUrlEvent in Sonos"	
		retval = HandleSonosXferEvent(event, m)
	else if type(event) = "roHttpEvent" then
		'print "###### roHttpEvent received in Sonos, url: ";event.GetUrl()
	else if type(event) = "roTimerEvent" then
		if (event.GetSourceIdentity() = m.timer.GetIdentity()) then
			print "renewing for registering events"
			SonosRenewRegisterForEvents(m)
			retval = true
		else if (event.GetSourceIdentity() = m.timerAliveCheck.GetIdentity()) then
			print "AliveCheck at ";m.st.GetLocalDateTime()
			StartAliveCheckTimer(m)
			for each device in m.sonosDevices
			    if device.alive=true then
			        ' mark it as false - an alive should come by and mark it as true again'
			        device.alive=false
			    else if device.alive=false then
			        deletePlayerByUDN(m,device.UDN)
			        model=device.modelNumber
			        if device.desired=true then
			            m.deletedDevices.push(model)
			        end if
			        print "+++ alive timer expired - device [";device.modelNumber;" - ";device.UDN;"] not seen and is deleted"
			    end if
			end for
			' Now re-scan
			FindAllSonosDevices(m)
	        retval=true
		else if (m.timerTopologyCheck <> invalid) and (event.GetSourceIdentity() = m.timerTopologyCheck.GetIdentity()) then
			StartTopologyCheckTimer(m)
			CheckSonosTopology(m)
	        retval=true
		end if
	end if

	return retval

End Function

Sub isSonosDevicePresent(s as object , devType as string ) as boolean

	found = false
	sonosDevice = invalid
	for each device in s.sonosDevices
		if device.modelNumber = devType
			found = true			
		endif
	end for

	' if (not found) then
		' print "Count not find ";devType;" in scanned device list"
	' else
		' print "Found ";devType;" in scanned device list"
	' end if

	return found
End Sub


Sub FindAllSonosDevices(s as Object) 
	' Conditionally send M-SEARCH multiple times, since devices may occasionally miss UDP M-SEARCH request
	repeatCount = 1
	if (s.userVariables["msearchRepeatCount"] <> invalid) then
		d=s.userVariables["msearchRepeatCount"].currentValue$
		repeatCount=val(d)
	end if
	
	print "*** FindAllSonosDevices (repeat count";str(repeatCount);")"

	CreateUPnPDiscoverer(s.msgPort, OnFound, s)
	if repeatCount <= 1 then
		s.disco.Discover("upnp:rootdevice")
	else
		for count = 1 to repeatCount
			s.disco.Discover("upnp:rootdevice")
			Sleep(10)
		end for
	end if
End Sub

Sub PrintAllSonosDevices(s as Object) 
    print "***************************  Sonos plugin version ";s.version;"***************************"
    print "-- siteHHID:        ";s.hhid
    print "-- master:          ";s.masterDevice
    print "__________________________________________________________________________________________"
	devices = s.devices
	for each device in s.sonosDevices
		print "++ device model:    "+device.modelNumber
		if device.desired=true
		    print "++ desired:         true"
		else
		    print "++ desired:         false"
		end if 
		if device.alive=true
		    print "++ alive:           true"
		else
		    print "++ alive:           false"
		end if 
		print "++ device url:      "+device.baseURL
		print "++ device UDN:      "+device.UDN
		print "++ device type:     "+device.deviceType
		print "++ device volume:   "+str(device.volume)
		print "++ device rdm:      "+str(device.rdm)
		print "++ device mute:     "+str(device.mute)
		print "++ device t-sid:    "+device.avTransportSID
		print "++ device r-sid:    "+device.renderingSID
		print "++ device ac-sid:   "+device.alarmClockSID
		print "++ device zgt-sid:  "+device.zoneGroupTopologySID
		print "++ device hhid:     "+device.hhid
		print "++ device uuid:     "+device.uuid
		print "++ device software: "+device.softwareVersion
		print "++ device bootseq:  "+device.bootseq
		print "++ transportState:  "+device.transportstate
		print "++ AVtransportURI:  "+device.AVTransportURI
		print "++ currentPlayMode: "+device.CurrentPlayMode
		if s.userVariables[device.modelNumber]<>invalid
		    print "++ UV: device:      ";s.userVariables[device.modelNumber].currentvalue$
		endif
		if s.userVariables[device.modelNumber+"HHID"]<>invalid
		   print "++ UV: HHID:        ";s.userVariables[device.modelNumber+"HHID"].currentvalue$
		end if
		if s.userVariables[device.modelNumber+"HHIDstatus"]<>invalid
		   print "++ UV: HHIDStatus:  ";s.userVariables[device.modelNumber+"HHIDstatus"].currentvalue$
		endif 
		print "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
	end for
End Sub

Sub LogAllSonosDevices(s as Object)

	devices = s.devices
	diagId = "Sonos"
	s.bsp.logging.WriteDiagnosticLogEntry(diagId, "Plugin Version " + s.version + ", Config Version " + s.configVersion)
	for each device in s.sonosDevices
		desired$ = " desired: "
		if device.desired=true
		    desired$ = desired$ + "true,"
		else
		    desired$ = desired$ + "false,"
		end if 
		alive$ = " alive: "
		if device.alive=true
		    alive$ = alive$ + "true,"
		else
		    alive$ = alive$ + "false,"
		end if 
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + desired$ + alive$ + " software: " + device.softwareVersion + ", rdm: " + str(device.rdm) + ", bootseq: " + device.bootseq)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " URL: " + device.baseURL)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " UDN: " + device.UDN)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " type: " + device.deviceType)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " hhid: " + device.hhid + ", uuid: " + device.uuid)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " transportState: " + device.transportstate + ", playMode: " + device.CurrentPlayMode + ", volume: " + str(device.volume) + ", mute: " + str(device.mute))
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " transport URI: " + device.AVTransportURI)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " transport sid: " + device.avTransportSID)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " render sid: " + device.renderingSID)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " alarmClock sid: " + device.alarmClockSID)
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, device.modelNumber + " zoneGroupTopology sid: " + device.zoneGroupTopologySID)
	end for

End Sub

Sub PrintAllSonosDevicesState(s as Object) 
	devices = s.devices
        print "-- master device:   ";s.masterDevice
	for each device in s.sonosDevices
		print "++ device model:    "+device.modelNumber
		print "++ device t-sid:    "+device.avTransportSID
		print "++ device r-sid:    "+device.renderingSID
		print "++ device ac-sid:   "+device.alarmClockSID
		print "++ device zgt-sid:  "+device.zoneGroupTopologySID
		print "++ transportState:  "+device.transportstate
		print "++ AVtransportURI:  "+device.AVTransportURI
		print "++ currentPlayMode: "+device.CurrentPlayMode
		print "+++++++++++++++++++++++++++++++++++++++++"
	end for
End Sub

Sub UPnPDiscoverer_OnEvent(ev as Object)
	'print "UPnPDiscoverer_OnEvent"
	response = ev.GetString()

	m.callback(response)
End Sub

Sub UPnPDiscoverer_Discover(name as String)
    lf = chr(10)
    q = chr(34)

    packet = ""
    packet = packet + "M-SEARCH * HTTP/1.1" + lf
    packet = packet + "ST: " + name + lf
    packet = packet + "MX: 5" + lf
    packet = packet + "MAN: " + q + "ssdp:discover" + q + lf
    packet = packet + "HOST: 239.255.255.250:1900" + lf

    count = 0
	ready = false
	while not ready 
		ret=m.sock.SendTo("239.255.255.250", 1900, packet)
		if ret < 0 then
    		print "ERROR SENDING: " + str(ret) 
 			print m.sock.GetFailureReason()
		end if

		' -128 indicates the network is not up
		if ret = -128 then
    		sleep(2000)
    		count = count+1
    		if count > 200 then
    			stop
			end if
		else
			ready = true
		end if
	end while

End Sub



Sub CreateUPnPDiscoverer(mp as Object, callback as Object, s as object) 
	if (s.disco = invalid) then
		o = {}
		o.sock = CreateObject("roDatagramSocket")
		o.sock.SetUserData(o)
		o.OnEvent = UPnPDiscoverer_OnEvent
		o.Discover = UPnPDiscoverer_Discover
		o.callback = callback
		o.ProcessDeviceXML = UPNPDiscoverer_ProcessDeviceXML
		o.mp = mp
		o.list = s.devices
		o.s = s

		o.sock.BindToLocalPort(1900)
		o.port = o.sock.GetLocalPort()
		o.sock.SetPort(mp)
		o.sock.JoinMulticastGroup("239.255.255.250")
		s.disco = o
	end if
End Sub
   

Sub OnFound(response as String)
	uuidString="none"

	' Ignore M-Search requests...
	if left(response,8) = "M-SEARCH"  
	    ' do nothing'

	else if left(response, 15) = "HTTP/1.1 200 OK" then
	    'print "@@@@@@@@@@@@@ 200 response: ";response
		SendXMLQuery(m.s, response)
	else if left(response, 6) = "NOTIFY" then
	    'print "@@@@@@@@@@@@@ NOTIFY response: ";response
		'print "Received NOTIFY event"
		hhid=GetHouseholdFromUPNPMessage(response)
		bootseq=GetBootSeqFromUPNPMessage(response)
		sonosNotification = bootseq.Len() > 0
		responseLocation = GetLocationFromUPNPMessage(response)
		responseBaseURL = GetBaseURLFromLocation(responseLocation)
		UDN = GetUDNfromUPNPMessage(response)
		sonosDevice = invalid
		for i = 0 to m.s.sonosDevices.count() - 1
  			if m.s.sonosDevices[i].baseURL = responseBaseURL then
  			    if m.s.sonosDevices[i].UDN = UDN
  			        ' must match both baseURL and UDN to be considered the same device'
					sonosDevice = m.s.sonosDevices[i]
					sonosDeviceIndex = i			
				end if 	
			endif
		end for

		aliveFound = instr(1,response,"NTS: ssdp:alive")
		rootDeviceString = instr(1,response,"NT: upnp:rootdevice")
		if (aliveFound) then
		    if(rootDeviceString) then
				' No console output for non-Sonos devices
				if sonosNotification then
					print "************ alive found ************ [";responseBaseURL;"]"
				end if
		        if (sonosDevice <> invalid) then
					print "Received ssdp:alive, device already in list "; responseBaseURL;" hhid: ";hhid;" old bootseq: "sonosDevice.bootseq;" new bootseq: ";bootseq;" version: ";sonosDevice.softwareVersion

					sonosDevice.alive=true
					'sonosDevice.hhid=hhid
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid,false)
					xfer=rdmPingAsync(m.s.mp,SonosDevice.baseURL,hhid) 
					m.s.postObjects.push(xfer)

					' if this device is in our list but is in factory reset we need to reboot'
					print "SonosDevice.hhid: ";SonosDevice.hhid
					if SonosDevice.hhid<>"" then
					    if hhid=""
						    print "device previously had hhid=";SonosDevice.hhid;" but now has no hhid - rebooting!"					
						    RebootSystem()
					    end if
					end if

					' if it's bootseq is different we need to punt and treat it as new
					if bootseq<>sonosDevice.bootseq then
					    print "+++ bootseq incremented - treating as a new player"
					    m.s.sonosDevices.delete(sonosDeviceIndex)
					    updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"HHIDStatus","pending",true)
					    SendXMLQuery(m.s, response)
					    goto done_all_found
					end if

				    ' Set the user variables
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber,"present",false)
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"Version",SonosDevice.softwareVersion,false)
					'updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid,false)

				else ' must be a new device
				    ' get the UDN - if we have that already, delete it - it means it's IP address changed out from under us!
				    deviceUDN = GetDeviceByUDN(m.s.sonosDevices, UDN)
				    if deviceUDN <> invalid
		                deleted=deletePlayerByUDN(m.s,UDN)
		                if deleted=true
							'print "+++ detected UIP address change and deleted player with uuid: ";UDN
							print "+++ detected UIP address change for player with uuid: ";UDN;" - rebooting!"
							' DND-221 - Need to reboot here to make sure HHIDs are set up properly for new players
							RebootSystem()
						end if		
				    end if

					if sonosNotification then
						print "Received ssdp:alive, querying device..."
					end if
				    SendXMLQuery(m.s, response)
				end if ' sonosDevice '
			end if 'rootDeviceFound '
		end if ' aliveFound'

		byebyeFound = instr(1,response,"NTS: ssdp:byebye")
		if (byebyeFound) then
			rootDeviceString = instr(1,response,"NT: upnp:rootdevice")
			if(rootDeviceString) then
   			    print "&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&  Received ssdp:byebye ";responseLocation
	                deleted=deletePlayerByUDN(m.s,UDN)
	                if deleted=true
						print "+++ got goodbye and deleted player with uuid: ";UDN
					else
						print "+++ Got byebye but player is not in list:";response	
					end if		
				'end if
			end if
		end if ' byebyeFound'
  end if

  done_all_found:
End Sub


function GetUDNfromUPNPMessage(response as string) as String
	uuidString=""
	uuidStart=instr(1,response,"USN: uuid:")
	if (uuidStart) then 
		uuidStart=uuidStart+10
		uuidEnd=instr(uuidStart,response,"::")
		uuidString=mid(response,uuidStart,uuidEnd-uuidStart)
	end if
	return uuidString
end function


function deletePlayerByUDN(s as object, uuid as String) as object

	print "+++ deletePlayerByUDN ";uuid
	found = false
	i = 0

	numdevices = s.sonosDevices.count()
	while (not found) and (i < numdevices)  
		if (uuid=s.sonosDevices[i].UDN) then
		  found = true
		  deviceNumToDelete = i
		end if
		i = i + 1
	end while
	if (found) then
	    modelBeingDeleted=s.sonosDevices[deviceNumToDelete].modelNumber
		print "!!! Deleting Player "+modelBeingDeleted+" with uuid: " + uuid
		s.sonosDevices.delete(deviceNumToDelete)

		' Indicate the player is no longer present
		if (s.userVariables[modelBeingDeleted] <> invalid) then
			s.userVariables[modelBeingDeleted].currentValue$ = "notpresent"
		end if
		print "current master is: ";s.masterDevice
		if modelBeingDeleted=s.masterDevice
 		    setSonosMasterDevice(s,"sall")
 		end if

		return true
	else
		print "matching uuid not in list: ";uuid
	end if		

end function


Sub SendXMLQuery(s as object, response as string)
	Query = {}
	Query.response = response
	Query.hhid = GetHouseholdFromUPNPMessage(response)
	Query.bootseq = GetBootSeqFromUPNPMessage(response)
	Query.uuid = "none"
	Query.UDN = "none"
	Query.location = GetLocationFromUPNPMessage(response)
	Query.transfer = CreateObject("roURLTransfer")
	Query.transfer.SetURL(Query.location)
	Query.transfer.SetPort(s.mp)
	Query.transfer.SetUserData(s)
	Query.complete = false
	Query.sonosDevice = false

''	print "sending Query, location: ";Query.location
''	print "initial response was:"
''	print response

	Query.uuid = ""
	rootDeviceString = instr(1,response,"ST: upnp:rootdevice")
	if(rootDeviceString) then
		uuidStart=instr(1,response,"USN: uuid:")
		if (uuidStart) then 
			uuidStart=uuidStart+10
			uuidEnd=instr(uuidStart,response,"::")
			uuidString=mid(response,uuidStart,uuidEnd-uuidStart)
			'print "uuid: "+uuidString
			Query.uuid = uuidString
		end if
	end if

	'print "**************"
	good = Query.transfer.AsyncGetToObject("roXMLElement")
	if (good) then 
		'print "XML Query sent"
		s.devices.push(Query)
	else
		print "**** XML Query NOT Sent ****"
	end if
end sub

Function GetHouseholdFromUPNPMessage(response as String) as string
	'print "GetHouseholdFromUPNPMessage: [";response;"]"
	household_string="X-RINCON-HOUSEHOLD:"
	lens=len(household_string)
	start = instr(1,response,household_string)
	if start=0
	  return ""
	end if
	last = instr(start+lens+1,response, chr(13))
	untrimmed = mid(response, start+lens+1, last-(start-lens))
	hhid = untrimmed.trim()
	return hhid
end Function

Function GetBootSeqFromUPNPMessage(response as String) as string
	bootseq_string="X-RINCON-BOOTSEQ:"
	lens = len(bootseq_string)
	start = instr(1,response,bootseq_string)
	if start=0
	  return ""
	end if
	start = start + lens
	last = instr(start+1,response, chr(13))
	untrimmed = mid(response, start, last-start)
	bootseq = untrimmed.trim()
	return bootseq
end Function

Function GetLocationFromUPNPMessage(response as String) as string
	lowerCase = lcase(response)
	start = instr(1,lowerCase,"location:") + 9
	last = instr(start+1,lowerCase, chr(13))
	untrimmed = mid(response, start, last-start)
	location = untrimmed.trim()

	return location
end Function

Function GetBaseURLFromLocation(location as string) as string
	baseURL = left(location, instr(8, location, "/")-1)	

	return baseURL
end Function


sub CheckPlayerHHIDs(s as object) as boolean
	' this function will check the players hhid against the site hhid, and if it does not match it will mark it as needsUpdate'
	for each device in s.sonosDevices
	    print "looking at ";device.modelNumber;": [";device.hhid;"]"
        if device.hhid<>s.hhid
            updateUserVar(s.userVariables,device.modelNumber+"HHIDStatus","needsUpdate",true)
        else 
	        updateUserVar(s.userVariables,device.modelNumber+"HHIDStatus","valid",true)
	    end if
	end for
end sub


Sub UPNPDiscoverer_ProcessDeviceXML(ev as Object)
	'print "UPNPDiscoverer_ProcessDeviceXML"
	s = ev.GetUserData()
	deviceList = s.devices
	deviceXML = ev.GetObject()
	'print deviceXML
	deviceTransferID = ev.GetSourceIdentity()

	if ev.GetResponseCode() / 100 <> 2 then
	    print "Retrieve device descriptor failed: "; ev.GetFailureReason();" response code:";ev.GetResponseCode()
		print "User data on the request was:"
		print s.response
	    return
	end if
	
	i = 0
	found = false
	numDevices = deviceList.count()
	'print "Num devices = ";numDevices
	while (i < numDevices) and (not found)
		id = deviceList[i].transfer.GetIdentity()
		if (id = deviceTransferID) then
			'print "device matches transfer ID"
			found = true
			deviceList[i].complete = true
			deviceMfg  = deviceXML.device.manufacturer.gettext()
			deviceType = deviceXML.device.deviceType.gettext()
''			if (instr(1, deviceMfg, "Sonos")) then
			if (instr(1, deviceType, "urn:schemas-upnp-org:device:ZonePlayer:1")) then

				baseURL = GetBaseURLFromLocation(deviceList[i].location)
				model = GetPlayerModelByBaseIP(s.sonosDevices, baseURL)			
				model = lcase(model)
				print "Found Sonos Device at baseURL ";baseURL;" by device XML"

				if (model = "") then
					deviceList[i].deviceXML = deviceXML
					model = deviceXML.device.modelNumber.getText()
					model = lcase(model)
					
				    ' check to see if we don't already have one and if it's one we already deleted and if so, we need to reboot
					d=GetDeviceByPlayerModel(s.sonosDevices, model)
					if d=invalid then 
					    for each deletedModel in s.deletedDevices
					        if deletedModel=model
					            print "********************* previously deleted player ";model;" detected - rebooting"
					            RebootSystem()
					        end if
					    end for
				    end if

					desired=isModelDesiredByUservar(s,model)
					SonosDevice = newSonosDevice(deviceList[i])
					if desired=true
					    SonosDevice.desired=true

					    print "Sonos at ";baseURL;" is desired"

						' Set the user variables
						updateUserVar(s.userVariables,SonosDevice.modelNumber,"present",false)
						updateUserVar(s.userVariables,SonosDevice.modelNumber+"Version",SonosDevice.softwareVersion,false)
						updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid,true)


						' do the RDM ping'
						xfer=rdmPingAsync(s.mp,sonosDevice.baseURL,s.hhid) 
						s.postObjects.push(xfer)

						' if this device was previously skipped on boot, we need to reboot'
						' but ONLY if we are in a state where we are all the way up and running'
						' if we are still booting up and configuring, we need to let that run it's course
						runningState="unknown"
						if s.userVariables["runningState"] <> invalid then
						    runningState=s.userVariables["runningState"].currentValue$
						end if
						if runningState="running" then
							skippedString=model+"Skipped"
							if s.userVariables[skippedString] <> invalid then
							    skipVal=s.userVariables[skippedString].currentValue$ 
							    if skipVal="yes"
							        updateUserVar(s.userVariables,skippedString, "no",true)
							        print "+++ skipped player ";model;" - rebooting!"
							        RebootSystem()
							    end if
							end if
						end if

						SonosRegisterForEvents(s, s.mp, SonosDevice)
						s.sonosDevices.push(SonosDevice)
					else					    
					    ' if it was previously skipped, we need to mark it as desired'
						' but ONLY if we are in a state where we are all the way up and running'
						' if we are still booting up and configuring, we need to let that run it's course
					    ''print "Sonos at ";baseURL;" is NOT desired - checking if we had skipped it before"

					    ''runningState="unknown"
						''if s.userVariables["runningState"] <> invalid then
						''    runningState=s.userVariables["runningState"].currentValue$
						''end if
						''skippedString=model+"Skipped"
						''if runningState="running" then
						''	if s.userVariables[skippedString] <> invalid then
						''	    skipVal=s.userVariables[skippedString].currentValue$ 
						''	    if skipVal="yes"
						''	        updateUserVar(s.userVariables,skippedString, "no",true)
						''	        print "+++ skipped player ";model;" - has been found, rebooting!"
						''	        RebootSystem()
						''	    end if
						''	else 
						''	    print "+++ player model ";model;" is not in the desired list - ignoring"
						''	end if
						''end if
						s.sonosDevices.push(SonosDevice)
					end if ' desired=true'
				else
					print "Player ";model;" already exists in device list"
					sonosDevice=GetDeviceByPlayerModel(s.sonosDevices, model)
					if sonosDevice<>invalid
					    sonosDevice.alive=true
					    desired=isModelDesiredByUservar(s,model)
						if desired=true
							    SonosDevice.desired=true
							    print "Player ";model;" is DESIRED"
					    else
					        print "Player ";model;" is not desired"
					    end if

					    ' NEW - booting with skipped players may put us here and we need to make sure the player is marked present'
						updateUserVar(s.userVariables,SonosDevice.modelNumber,"present",true)

					end if
				end if
			end if
			deviceList.delete(i)
		end if
		i = i + 1
	end while
	if (not found) then
		stop
		print "Was unable to find a match for transfer"
	end if
end Sub	


Function isModelDesiredByUservar(s as object, model as string)
	if s.userVariables[model+"Desired"] <> invalid then
	    if s.userVariables[model+"Desired"].currentValue$ = "yes"
	        return true
	    end if
	end if
	return false
end Function


Sub newSonosDevice(device as Object) as Object
	sonosDevice = { baseURL: "", deviceXML: invalid, modelNumber: "", modelDescription: "", UDN: "", deviceType: "", hhid: "none", uuid: "", avTransportSID: "", renderingSID: "", alarmClockSID: "", zoneGroupTopologySID: "", softwareVersion: ""}
	sonosDevice.baseURL = GetBaseURLFromLocation(device.location)
	sonosDevice.deviceXML = device.deviceXML
	sonosDevice.modelNumber = lcase(device.deviceXML.device.modelNumber.getText())
	sonosDevice.modelDescription = lcase(device.deviceXML.device.modelDescription.getText())
	sonosDevice.UDN = mid(device.deviceXML.device.UDN.getText(),6)
	sonosDevice.deviceType = device.deviceXML.device.deviceType.getText()
	sonosDevice.volume=-1
	sonosDevice.rdm=-1
	sonosDevice.mute=-1
	sonosDevice.transportState = "STOPPED"
	sonosDevice.CurrentPlayMode = "NORMAL"
	sonosDevice.AVTransportURI = "none"
	sonosDevice.foreignPlaybackURI = false
	sonosDevice.muteCheckNeeded = false
	sonosDevice.SleepTimerGeneration = 0
	sonosDevice.AlarmListVersion = -1
	sonosDevice.AlarmCheckNeeded = "yes"
	sonosDevice.hhid=device.hhid
	sonosDevice.uuid=device.uuid
	sonosDevice.softwareVersion=lcase(device.deviceXML.device.softwareVersion.getText())
	sonosDevice.bootseq=device.bootseq
	sonosDevice.desired=false
	sonosDevice.alive=true

	print "device HHID:       ["+SonosDevice.hhid+"]"
	print "device UDN:        ["+SonosDevice.UDN+"]"
	print "software Version:  ["+sonosDevice.softwareVersion+"]"
	print "boot sequence:     ["+sonosDevice.bootseq+"]"


	return sonosDevice
end Sub

function GetPlayerModelByBaseIP(sonosDevices as Object, IP as string) as string
	
	returnModel = ""
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].baseURL = IP) then
			returnModel = sonosDevices[i].modelNumber
		end if
	end for

	return returnModel
end function


Function GetBaseIPByPlayerModel(sonosDevices as Object, modelNumber as string) as string
	
	newIP = ""
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].modelNumber = modelNumber) then
			newIP = sonosDevices[i].baseURL
		end if
	end for

	return newIP
end function

Function GetDeviceByPlayerModel(sonosDevices as Object, modelNumber as string) as object
	
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].modelNumber = modelNumber) then
			device = sonosDevices[i]
		end if
	end for
	return device

end function

Function GetDeviceByPlayerBaseURL(sonosDevices as Object, baseURL as string) as object
	
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].baseURL = baseURL) then
			device = sonosDevices[i]
		end if
	end for
	return device
end function


function GetDeviceByUDN(sonosDevices as Object, UDN as string) as object
	
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].UDN = UDN) then
			device = sonosDevices[i]
		end if
	end for
	return device
end function

'---------------ParseSonosPluginMsg--------------
Function ParseSonosPluginMsg(origMsg as string, sonos as object) as boolean

	'TIMING print "Received command - ParseSonosPluginMsg: " + origMsg;" at: ";sonos.st.GetLocalDateTime()

	retval = false
		
	' convert the message to all lower case for easier string matching later
	msg = lcase(origMsg)
	print "--- RECEIVED Plugin message: "+msg
	' verify its a SONOS message'
	r = CreateObject("roRegex", "^SONOS", "i")
	match=r.IsMatch(msg)

	' Is this a sonos request
	if match then
		sonos.bsp.logging.WriteDiagnosticLogEntry("Sonos received plugin message", msg)
		retval = true

		' split the string
		r2 = CreateObject("roRegex", "!", "i")
		fields=r2.split(msg)
		numFields = fields.count()
		if (numFields < 3) or (numFields > 4) then
			print "Incorrect number of fields for Sonos command:";msg
			' need to have a least 3 fields and not more than 4 fields to be valid
			return retval
		else if (numFields = 3) then
			' command with no details
			devType=fields[1]
			command=fields[2]
			detail = ""
		else if (numFields = 4) then
			' command with details
			devType=fields[1]
			command=fields[2]
			detail =fields[3]
		end if

		if ((devType = "sall") or (command = "present") or (command = "desired")) then
			' Do not try to validate the device
			sonosDevice = invalid
		else
			'get the IP of the desired device
			sonosDevices=sonos.sonosDevices

			sonosDevice = invalid
			for each device in sonosDevices
				if device.modelNumber=devType
					sonosDevice=device
					exit for				
				endif
			end for

			desired=isModelDesiredByUservar(sonos, devType)

			if (sonosDevice = invalid) or (not desired) then
				print "No device of that type on this network or it is NOT Desired"
				return retval
			endif

			' print command +" " + devType + " " + detail + " " +sonosDevice.baseURL

		end if

		' if the Sonos device is not already processing a command, the process if
		if (not SonosDeviceBusy(sonos, devType)) or (command = "present") or (command = "addplayertogroup") or (devType = "sall") then
			if sonosDevice <> invalid then
				print "Executing:";command +" " + devType + " " + detail + " " + sonosDevice.baseURL
			else
				print "Executing:";command +" " + devType + " " + detail + " " + "No URL Specified"
			end if
			' TODO: should consider putting xferobjects inside functions where they belong!'
			if command="mute" then
			    print "Sending mute"
				xfer = SonosSetMute(sonos.mp, sonosDevice.baseURL,1) 
				sonos.xferObjects.push(xfer)
			else if command="flush" then
				' Flush all of the commands in the command Queue
				print "Flushing Command Queue"
				sonos.commandQ.Clear()
			else if command="unmute" then
				'if sonosDevice.mute=1
				    print "Sending unMute"
					xfer = SonosSetMute(sonos.mp, sonosDevice.baseURL,0) 
					sonos.xferObjects.push(xfer)
				'else
				    'print "+++ device not muted - ignoring command"
					'postNextCommandInQueue(sonos, sonosDevice.baseURL)
				'end if
			else if command="volume" then
				CheckMute(sonos, sonosDevice)
				volume = val(detail)
				print "Setting volume on ";sonosDevice.modelNumber;" to ["volume;"]"
				if sonosDevice.volume<>volume
					xfer = SonosSetVolume(sonos.mp, sonosDevice.baseURL, volume )
					sonos.xferObjects.push(xfer)
				else
				    print "+++ volume already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command="getvol" then
				' print "Getting volume"
				xfer = SonosGetVolume(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command="volup" then
				if detail="" then
					volincrease=1
				else
					volincrease=abs(val(detail))
				end if
				if (devType <> "sall") then
					CheckMute(sonos, sonosDevice)
					sonosDevice.volume = sonosDevice.volume + volincrease
					if (sonosDevice.volume > 100) then
						sonosDevice.volume = 100
					end if
					'TIMING print "Sending Volume Up "+str(volincrease)+ " to "+str(sonosDevice.volume);" at: ";sonos.st.GetLocalDateTime()
					xfer = SonosSetVolume(sonos.mp, sonosDevice.baseURL, sonosDevice.volume)
					sonos.xferObjects.push(xfer)
				else ' sall - increase volume on all devices
					sonosDevices=sonos.sonosDevices
					for each device in sonosDevices
						CheckMute(sonos, device)
						device.volume = device.volume + volincrease
						if (device.volume > 100) then
							device.volume = 100
						end if
						xfer = SonosSetVolume(sonos.mp, device.baseURL, device.volume)
						sonos.xferObjects.push(xfer)
					end for
				end if
			else if command="voldown" then
				if detail="" then
					voldecrease = 1
				else
					voldecrease=abs(val(detail))
				end if
				if (devType <> "sall") then
					CheckMute(sonos, sonosDevice)
					sonosDevice.volume = sonosDevice.volume - voldecrease
					if (sonosDevice.volume < 0) then
						sonosDevice.volume = 0
					end if
					'TIMING print "Sending Volume Down "+str(voldecrease)+ " to "+str(sonosDevice.volume);" at: ";sonos.st.GetLocalDateTime()
					xfer = SonosSetVolume(sonos.mp, sonosDevice.baseURL, sonosDevice.volume)
					sonos.xferObjects.push(xfer)
				else ' sall - increase volume on all devices
					sonosDevices=sonos.sonosDevices
					for each device in sonosDevices
						CheckMute(sonos, device)
						device.volume = device.volume - voldecrease
						if (device.volume < 0) then
							device.volume = 0
						end if
						xfer = SonosSetVolume(sonos.mp, device.baseURL, device.volume)
						sonos.xferObjects.push(xfer)
					end for
				end if
			else if command="setplaymode" then
				SonosSetPlayMode(sonos, sonosDevice)
			else if command="resetbasiceq" then
				xfer = SonosResetBasicEQ(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command="getsleeptimer" then
				xfer = SonosGetSleepTimer(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command="setsleeptimer" then
			    ' parse the detail?
			    timeout=""
				SonosSetSleepTimer(sonos, sonosDevice,timeout)
			else if command="checkalarm" then
				if (devType <> "sall") then
					SonosCheckAlarm(sonos, sonosDevice)
				else
					sonosDevices=sonos.sonosDevices
					for each device in sonosDevices
						SonosCheckAlarm(sonos, device)
					end for
				end if
			else if command="playmp3" then
				' print "Playing MP3"
				'TIMING print "Playing MP3 on "+sonosDevice.modelNumber" at: ";sonos.st.GetLocalDateTime()
				netConfig = CreateObject("roNetworkConfiguration", 0)
				currentNet = netConfig.GetCurrentConfig()
				xfer = SonosSetSong(sonos, currentNet.ip4_address, sonosDevice.baseURL, detail)
				sonos.xferObjects.push(xfer)
			else if command="spdif" then
				' print "Switching to SPDIF input"
				xfer = SonosSetSPDIF(sonos, sonosDevice.baseURL, sonosDevice.UDN)
				sonos.xferObjects.push(xfer)
			else if command="group" then
				if (devType <> "sall") then 
			        ' this groups a given device to the master we already know about'
			        print "+++ grouping all players to master ";s.masterDevice
				    master=GetDeviceByPlayerModel(s.sonosDevices, s.masterDevice)
				    if master<>invalid
					    xfer = SonosSetGroup(sonos.mp, sonosDevice.baseURL, master.UDN)
						sonos.xferObjects.push(xfer)
					end if						
				else ' sall - we just group them'
                    SonosGroupAll(sonos)
				end if
			else if command = "play" then
				xfer = SonosPlaySong(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "subbond" then
				' bond Sub to given device
				if isModelDesiredByUservar(sonos, "sub") then
					subDevice = GetDeviceByPlayerModel(sonos.sonosDevices, "sub")
					if subDevice <> invalid then
						xfer = SonosSubBond(sonos.mp, sonosDevice.baseURL, sonosDevice.UDN, subDevice.UDN)
						sonos.xferObjects.push(xfer)
					end if
				end if
			else if command = "subunbond" then
				subDevice = GetDeviceByPlayerModel(sonos.sonosDevices, "sub")
				if subDevice <> invalid then
					xfer = SonosSubUnBond(sonos.mp, sonosDevice.baseURL, subDevice.UDN)
					sonos.xferObjects.push(xfer)
				end if
			else if command = "setautoplayroom" then
				xfer = SonosSetAutoplayRoomUUID(sonos.mp, sonosDevice.baseURL, sonosDevice.UDN)
				sonos.xferObjects.push(xfer)
			else if command = "checktopology" then
				CheckSonosTopology(sonos)
			else if command = "subon" then
				if sonosDevice.subEnabled = invalid or sonosDevice.subEnabled <> 1 then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "SubEnable", "1")
					sonos.xferObjects.push(xfer)
				else
				    print "+++ SUB already on - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "suboff" then
				if sonosDevice.subEnabled = invalid or sonosDevice.subEnabled <> 0 then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "SubEnable", "0")
					sonos.xferObjects.push(xfer)
				else
				    print "+++ SUB already off - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "subgain" then
				if sonosDevice.subGain = invalid or sonosDevice.subGain <> val(detail) then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "SubGain", detail)
					sonos.xferObjects.push(xfer)
				else
				    print "+++ SubGain already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "subcrossover" then
				if sonosDevice.subCrossover = invalid or sonosDevice.subCrossover <> val(detail) then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "SubCrossover", detail)
					sonos.xferObjects.push(xfer)
				else
				    print "+++ SubCrossover already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "subpolarity" then
				if sonosDevice.subPolarity = invalid or sonosDevice.subPolarity <> val(detail) then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "SubPolarity", detail)
					sonos.xferObjects.push(xfer)
				else
				    print "+++ SubPolarity already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "surroundon" then
				' print "Surround ON"
				xfer = SonosSurroundCtrl(sonos.mp, sonosDevice.baseURL,1)
				sonos.xferObjects.push(xfer)
			else if command = "surroundoff" then
				' print "Surround OFF"
				xfer = SonosSurroundCtrl(sonos.mp, sonosDevice.baseURL,0)
				sonos.xferObjects.push(xfer)
			else if command = "dialoglevel" then
				if sonosDevice.dialogLevel = invalid or sonosDevice.dialogLevel <> val(detail) then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "DialogLevel", detail)
					sonos.xferObjects.push(xfer)
				else
				    print "+++ DialogLevel already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "nightmode" then
				if sonosDevice.nightMode = invalid or sonosDevice.nightMode <> val(detail) then
					xfer = SonosEQCtrl(sonos.mp, sonosDevice.baseURL, "NightMode", detail)
					sonos.xferObjects.push(xfer)
				else
				    print "+++ NightMode already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "mutebuttonbehavior" then
				xfer = SonosMutePauseControl(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "getmute" then
				' print "Getting Mute"
				xfer = SonosGetMute(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "rdmon" then
				xfer = SonosSetRDM(sonos.mp, sonosDevice.baseURL,1)
				sonos.xferObjects.push(xfer)
			else if command = "rdmoff" then
				xfer = SonosSetRDM(sonos.mp, sonosDevice.baseURL,0)
				sonos.xferObjects.push(xfer)
			else if command = "rdmdefault" then
 				xfer = SonosApplyRDMDefaultSettings(sonos.mp, sonosDevice.baseURL)
 				sonos.xferObjects.push(xfer)
			else if command = "getrdm" then
				xfer = SonosGetRDM(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "wifi" then
				xfer = SonosSetWifi(sonos.mp, sonosDevice.baseURL, detail)
				sonos.xferObjects.push(xfer)
			else if command = "software_upgrade" then
				netConfig = CreateObject("roNetworkConfiguration", 0)
				currentNet = netConfig.GetCurrentConfig()
				xfer = SonosSoftwareUpdate(sonos,sonos.mp, sonosDevice.baseURL, currentNet.ip4_address, detail)
				if xfer<>invalid
				    sonos.xferObjects.push(xfer)
				else
				     postNextCommandInQueue(sonos, sonosDevice.baseURL)
				end if
			else if command = "scan" then
				FindAllSonosDevices(sonos)
				sendSelfUDP("scancomplete")
			else if command = "list" then
				PrintAllSonosDevices(sonos)
				LogAllSonosDevices(sonos)
			else if command = "reboot" then
			    xfer=SonosPlayerReboot(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "checkhhid" then
			    CheckPlayerHHIDs(sonos)
			    PrintAllSonosDevices(sonos)
				LogAllSonosDevices(sonos)
			else if command = "rdmping" then
			    xfer=rdmPingAsync(sonos.mp,sonosDevice.baseURL,sonos.hhid) 
			    sonos.postObjects.push(xfer)
			else if command = "sethhid" then
			    varName=sonosDevice.modelNumber+"RoomName"
			    if sonos.userVariables[varName] <> invalid then
			        roomName=sonos.userVariables[varName].currentValue$
			    else
			        print "ERROR:  no room name defined for player ";sonosDevice.modelNumber
			        roomName=sonosDevice.modelNumber
			    end if
			    xfer=rdmHouseholdSetupAsync(sonos.mp,sonosDevice.baseURL,sonos.hhid,roomName,"none",1) 
			    sonos.postObjects.push(xfer)
			    print "hhsetup: ";type(xfer)
		        print "deleting sonos device: ";sonosDevice.modelNumber
		        DeleteSonosDevice(sonos.userVariables,sonosDevices,sonosDevice.baseURL)
''		        PrintAllSonosDevices(sonos)
			else if command = "addmp3" then
				AddMP3(sonos, detail)
			else if command = "addupgradefiles" then
				AddAllSonosUpgradeImages(sonos, detail)
			else if command = "present" then
				present = isSonosDevicePresent(sonos, devType)
				if present then 
					sendSelfUDP(devType + ":present")
				else
					sendSelfUDP(devType + ":notpresent")
				end if	
			else if command = "setmasterdevice" then
			    'sonos.masterDevice = devType
				setSonosMasterDevice(sonos,devType)
			else if command = "addplayertogroup" then
				' TODO - is this still used?
				print "Trying to add ";devType;" to playing group"
				found = false
				print "Number of device is: "; sonos.playingGroup.count()
				for i = 0 to sonos.playingGroup.count() - 1
					if (devType = sonos.playingGroup[i]) then
						print "The device already exists in the playing group: ";devType
						found = true
					end if
				end for
				if (not found) then
					print "Adding ";devType;" to playing group"
					sonos.playingGroup.push(devType)	
				end if
			else if command = "buttonstate" then
				setbuttonstate(sonos, detail)
			else
				print "Discarding UNSUPPORTED command :"; command
				if sonosDevice <> invalid then
					postNextCommandInQueue(sonos, sonosDevice.baseURL)
				endif
			end if
		else
			'TIMING print "Queueing command due to device being busy: ";msg;" at: ";sonos.st.GetLocalDateTime()
			commandToQ = {}
			commandToQ.IP = sonosDevice.baseURL
			commandToQ.msg = msg
			sonos.commandQ.push(commandToQ)	
			print "+++ Queuing:";command +" " + devType + " " + detail + " " +sonosDevice.baseURL		

			for each c in sonos.commandQ
			    print "   +++ ";c.IP;" - ";c.msg
			next

		end if
	end if

	return retval
end Function

function getUserVariableValue(sonos as object, varName as string) as object

    varValue = invalid

    if sonos.UserVariables[varName] <> invalid then
        varValue = sonos.userVariables[varName].currentValue$
        if varValue = "none" then
            varValue = invalid
        end if
    end if

    return varValue

end function

function setSonosMasterDevice(sonos as object,devType as string) as object

	print "*********************************************** setSonosMasterDevice ";devType
	if devType="sall"
	    ' pick a random device'
	    for each device in sonos.sonosDevices

	        desired=isModelDesiredByUservar(sonos,device.modelNumber)
	        if desired=true and device.modelNumber <> "sub" then
		        sonos.masterDevice = device.modelNumber
		        print "+++ setting master device to: ";sonos.masterDevice
				if (sonos.userVariables["masterDevice"] <> invalid) then
					sonos.userVariables["masterDevice"].currentValue$ = sonos.masterDevice
				end if	
		        return sonos.masterDevice
	        end if 
	    end for
	else
	    sonos.masterDevice = devType
        print "+++ setting master device to: ";sonos.masterDevice
		if (sonos.userVariables["masterDevice"] <> invalid) then
			sonos.userVariables["masterDevice"].currentValue$ = sonos.masterDevice
		end if	
	    return sonos.masterDevice 
	end if
	return invalid
end function

Sub CheckSonosTopology(sonos as object)

	runningState="unknown"
	if sonos.userVariables["runningState"] <> invalid then
		runningState=sonos.userVariables["runningState"].currentValue$
	end if
	
	' Do nothing about bonding until the boot sequence is done
	if runningState="running" then
	
		bondMaster$ = "none"
		if sonos.userVariables["subBondTo"] <> invalid then
			bondMaster$ = sonos.userVariables["subBondTo"].currentValue$
		end if
	
		subBondStatus$ = "none"
		if sonos.userVariables["subBondStatus"] <> invalid then
			subBondStatus$ = sonos.userVariables["subBondStatus"].currentValue$
		end if

		print "**** Checking Sonos Topology, master: ";bondMaster$;", subBondStatus: ";subBondStatus$;", time: ";sonos.st.GetLocalDateTime()
		
		if bondMaster$ <> "none" and subBondStatus$ <> "none" then
			bondMaster = GetDeviceByPlayerModel(sonos.sonosDevices, bondMaster$)
			if bondMaster <> invalid then
				subDevice = GetDeviceByPlayerModel(sonos.sonosDevices, "sub")
				if subDevice <> invalid and subBondStatus$ = "Unbonded" then
					sonos.accelerateAliveCheck = False
					' Bond sub to bondMaster
					print "**** Bonding ";bondMaster$;" to SUB"
					xfer = SonosSubBond(sonos.mp, bondMaster.baseURL, bondMaster.UDN, subDevice.UDN)
					sonos.xferObjects.push(xfer)
				else if (subBondStatus$ = "Bonded/missing") or (subDevice = invalid and subBondStatus$.Left(6) = "Bonded") then
					sonos.accelerateAliveCheck = False
					if sonos.masterBondedToSubUDN <> invalid and sonos.masterBondedToSubUDN <> "none" then
						' Unbond sub from master
						print "**** SUB is missing - unbonding ";bondMaster$;" from SUB"
						xfer = SonosSubUnBond(sonos.mp, bondMaster.baseURL, sonos.masterBondedToSubUDN)
						sonos.xferObjects.push(xfer)
					else
						print "**** Need to unbond SUB, but we don't have sub UDN that was bonded"
					end if
				' else if subBondStatus$ = "Bonded/missing" then
					' ' If topology update indicates the bondMaster is bonded, but
					' '  the sub is missing, accelerate alive checks to determine
					' '  when the sub actually goes away
					' ' When that happens, we will unbond the master
					' print "**** SUB is in our list, but bonded master reports SUB missing - accelerating AliveCheck"
					' sonos.timerAliveCheck.Stop()
					' sonos.accelerateAliveCheck = True
					' StartAliveCheckTimer(sonos)
				end if
			end if
		end if
	end if

End Sub

Sub CheckMute(sonos as object, sonosDevice as object)
	doCheck = getUserVariableValue(sonos, sonosDevice.modelNumber +"MuteCheck")
	if doCheck <> invalid and doCheck = "yes" and sonosDevice.muteCheckNeeded then
		commandToQ = {}
		commandToQ.IP = sonosDevice.baseURL
		commandToQ.msg = "sonos!" + sonosDevice.modelNumber + "!unmute"
		sonos.commandQ.push(commandToQ)	
		print "+++ Queuing:unmute ";sonosDevice.modelNumber + " " +sonosDevice.baseURL

		sonosDevice.muteCheckNeeded = false		
	end if
End Sub

sub SonosGetVolume(mp as object, connectedPlayerIP as string) as object

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="GetVolume"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#GetVolume")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	volXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"
	volXML=volXML+chr(34)+"?><s:Envelope s:encodingStyle="+chr(34)
	volXML=volXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)+" xmlns:s=" 
	volXML=volXML+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)+">"
	volXML=volXML+"<s:Body><u:GetVolume xmlns:u=" +chr(34)
	volXML=volXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	volXML=volXML+"><InstanceID>0</InstanceID><Channel>Master</Channel>"
	volXML=volXML+"</u:GetVolume></s:Body></s:Envelope>"

	ok = soapTransfer.AsyncPostFromString(volXML)
	if not ok then
		stop
	end if

	return soapTransfer
end sub



Sub SonosSetVolume(mp as object, connectedPlayerIP as string, volume as integer) as object

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetVolume"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	
	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#SetVolume")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	'volXML = ReadASCIIFile("volume.xml")
	volXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"
	volXML=volXML+chr(34)+"?><s:Envelope s:encodingStyle="+chr(34)
	volXML=volXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)+" xmlns:s=" 
	volXML=volXML+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)+">"
	volXML=volXML+"<s:Body><u:SetVolume xmlns:u=" +chr(34)
	volXML=volXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	volXML=volXML+"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>"
	volXML=volXML+"VOLUMEVALUE</DesiredVolume></u:SetVolume></s:Body></s:Envelope>"

	r = CreateObject("roRegex", "VOLUMEVALUE", "i")
	reqString=r.ReplaceAll(volXML,mid(stri(volume),2))
	' print reqString
	ok = soapTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return soapTransfer
end sub


Sub SonosSetMute(mp as object, connectedPlayerIP as string, muteVal as integer) as object

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetMute"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	muteXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	muteXML=muteXML+"<s:Envelope s:encodingStyle="+chr(34)
	muteXML=muteXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	muteXML=muteXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	muteXML=muteXML+"><s:Body><u:SetMute xmlns:u="+chr(34)
	muteXML=muteXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	muteXML=muteXML+"><InstanceID>0</InstanceID><Channel>Master</Channel>"
	muteXML=muteXML+"<DesiredMute>MUTEVALUE</DesiredMute></u:SetMute></s:Body></s:Envelope>"
	
	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#SetMute")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	' set the correct Mute value in the request string
	r = CreateObject("roRegex", "MUTEVALUE", "i")
	if muteVal=0 then 
		reqString=r.ReplaceAll(muteXML,"0")
	else
		reqString=r.ReplaceAll(muteXML,"1")
	end if

	print "Executing Mute: ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return soapTransfer
end sub

Sub SonosGetMute(mp as object, connectedPlayerIP as string) as object

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="GetMute"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	muteXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	muteXML=muteXML+"<s:Envelope s:encodingStyle="+chr(34)
	muteXML=muteXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	muteXML=muteXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	muteXML=muteXML+"><s:Body><u:GetMute xmlns:u="+chr(34)
	muteXML=muteXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	muteXML=muteXML+"><InstanceID>0</InstanceID><Channel>Master</Channel>"
	muteXML=muteXML+"</u:GetMute></s:Body></s:Envelope>"
	
	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#GetMute")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	print "Executing GetMute: ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(muteXML)
	if not ok then
		stop
	end if

	return soapTransfer
end sub

Sub SonosMutePauseControl(mp as object, connectedPlayerIP as string) as object

	reqString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+" standalone="+chr(34)+"yes"+chr(34)+"?>"
	reqString=reqString+"<s:Envelope s:encodingStyle="+chr(34)
	reqString=reqString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	reqString=reqString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)+">"
	reqString=reqString+"<s:Body>"
	reqString=reqString+"<u:SetString xmlns:u="+chr(34)+"urn:schemas-upnp-org:service:SystemProperties:1"+chr(34)+">"
	reqString=reqString+"<VariableName>R_ButtonMode</VariableName><StringValue>Mute</StringValue></u:SetString></s:Body>"
	reqString=reqString+"</s:Envelope>"

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 2000, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="MutePauseControl"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/SystemProperties/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:SystemProperties:1#SetString")
	if not ok then
		stop
	end if

	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	' print "strlen: "+str(len(xmlString))
	' print xmlString
	ok = soapTransfer.AsyncPostFromString(reqString)

	return soapTransfer
end sub


Sub SonosSetRDM(mp as object, connectedPlayerIP as string, rdmVal as integer) as object

	' this function is not yet working - the SOAP string appears to be wrong'

	if rdmVal=0 then 
		print "SonosSetRDM "+connectedPlayerIP+" off"
	else
		print "SonosSetRDM "+connectedPlayerIP+" on"
	end if

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="EnableRDM"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	mXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	mXML=mXML+"<s:Envelope s:encodingStyle="+chr(34)
	mXML=mXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	mXML=mXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	mXML=mXML+"><s:Body><u:EnableRDM xmlns:u="+chr(34)
	mXML=mXML+"urn:schemas-upnp-org:service:SystemProperties:1"+chr(34)
	mXML=mXML+"><RDMValue>RDMVALUEVAR</RDMValue></u:EnableRDM></s:Body></s:Envelope>"
	
	soapTransfer.SetUrl( connectedPlayerIP + "/SystemProperties/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:SystemProperties:1#EnableRDM")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	' set the correct Mute value in the request string
	r = CreateObject("roRegex", "RDMVALUEVAR", "i")
	if rdmVal=0 then 
		reqString=r.ReplaceAll(mXML,"0")
	else
		reqString=r.ReplaceAll(mXML,"1")
	end if

	print "Executing SetRDM: ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return soapTransfer
end sub

sub SonosGetRDM(mp as object, connectedPlayerIP as string) as object

	' this function is not yet working - the SOAP string appears to be wrong'


	print "SonosGetRDM "+connectedPlayerIP

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="GetVolume"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/SystemProperties/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:SystemProperties:1#GetRDM")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	rXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"
	rXML=rXML+chr(34)+"?><s:Envelope s:encodingStyle="+chr(34)
	rXML=rXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)+" xmlns:s=" 
	rXML=rXML+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)+">"
	rXML=rXML+"<s:Body><u:GetRDM xmlns:u=" +chr(34)
	rXML=rXML+"urn:schemas-upnp-org:service:SystemProperties:1"+chr(34)
	rXML=rXML+"></u:GetRDM></s:Body></s:Envelope>"

	ok = soapTransfer.AsyncPostFromString(rXML)
	if not ok then
		stop
	end if

	return soapTransfer
end sub

sub SonosApplyRDMDefaultSettings(mp as object, connectedPlayerIP as string) as object

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="ApplyRDMDefaultSettings"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/SystemProperties/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:SystemProperties:1#ApplyRDMDefaultSettings")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	volXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"
	volXML=volXML+chr(34)+"?><s:Envelope s:encodingStyle="+chr(34)
	volXML=volXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)+" xmlns:s=" 
	volXML=volXML+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)+">"
	volXML=volXML+"<s:Body><u:ApplyRDMDefaultSettings xmlns:u=" +chr(34)
	volXML=volXML+"urn:schemas-upnp-org:service:SystemProperties:1"+chr(34)
	volXML=volXML+"></u:ApplyRDMDefaultSettings></s:Body></s:Envelope>"
	
	print "Executing ApplyRDMDefaultSettings: ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(volXML)
	if not ok then
		stop
	end if

	return soapTransfer
end sub


Sub SonosSetWifi(mp as object, connectedPlayerIP as string, setValue as string) as object
	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="WifiCtrl"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	sURL=connectedPlayerIP+"/wifictrl?wifi="+setValue
	soapTransfer.SetUrl(sURL)

	print "Executing SonosSetWifi: ";sURL
	ok = soapTransfer.AsyncGetToString()
	if not ok then
		stop
	end if

	return (soapTransfer)
end Sub

Sub SonosSetAutoplayRoomUUID(mp as object, connectedPlayerIP as string, masterUDN as string) as object

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	xmlString=xmlString+"<s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	xmlString=xmlString+"><s:Body><u:SetAutoplayRoomUUID xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:DeviceProperties:1"+chr(34)
	xmlString=xmlString+"><RoomUUID>UDNSTRING</RoomUUID>"
	xmlString=xmlString+"</u:SetAutoplayRoomUUID>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	r1 = CreateObject("roRegex", "UDNSTRING", "i")
	reqString = r1.ReplaceAll(xmlString, masterUDN)

	sTransfer = CreateObject("roUrlTransfer")
	sTransfer.SetMinimumTransferRate( 2000, 1 )
	sTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetAutoplayRoomUUID"
	sonosReqData["dest"]=connectedPlayerIP
	sTransfer.SetUserData(sonosReqData)

	sTransfer.SetUrl( connectedPlayerIP + "/DeviceProperties/Control")
	ok = sTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:DeviceProperties:1#SetAutoplayRoomUUID")
	if not ok then
		stop
	end if
	ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing SetAutoplayRoomUUID: ";connectedPlayerIP
	ok = sTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return sTransfer
End Sub

Function SonosCreateSetEQBody(key as string, value as string) as string

	eqXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	eqXML=eqXML+"<s:Envelope s:encodingStyle="+chr(34)
	eqXML=eqXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	eqXML=eqXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	eqXML=eqXML+"><s:Body><u:SetEQ xmlns:u="+chr(34)
	eqXML=eqXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	eqXML=eqXML+"><InstanceID>0</InstanceID>"
	eqXML=eqXML+"<EQType>EQ_KEY</EQType><DesiredValue>EQ_VALUE</DesiredValue></u:SetEQ>"
	eqXML=eqXML+"</s:Body></s:Envelope>"

	' set the correct key in the request string
	key_regex = CreateObject("roRegex", "EQ_KEY", "i")
    eqXML = key_regex.ReplaceAll(eqXML, key)
    
	' set the correct value in the request string
	value_regex = CreateObject("roRegex", "EQ_VALUE", "i")
    retXML = value_regex.ReplaceAll(eqXML, value)
    
    return retXML

end Function

Sub SonosEQCtrl(mp as object, connectedPlayerIP as string, EqKey as string, EqVal as string) as object
	
	' print "SonosEQCtrl"

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="EQCtrl/"+EqKey
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#SetEQ")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

    reqString = SonosCreateSetEQBody(EqKey, EqVal)

	print "Executing SubControl/";EqKey;": ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return soapTransfer
end sub

Sub SonosSubBond(mp as object, connectedPlayerIP as string, s9UDN as string, subUDN as string) as object
    
    soapTransfer = CreateObject("roUrlTransfer")
    soapTransfer.SetMinimumTransferRate( 2000, 1 )
    soapTransfer.SetPort( mp )

    sonosReqData=CreateObject("roAssociativeArray")
    sonosReqData["type"]="SubBond"
    sonosReqData["dest"]=connectedPlayerIP
    soapTransfer.SetUserData(sonosReqData)

    subXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="
	subXML=subXML+chr(34)+"utf-8"+chr(34)+"?>"
    subXML=subXML+"<s:Envelope s:encodingStyle="+chr(34)
    subXML=subXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
    subXML=subXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
    subXML=subXML+"><s:Body><u:AddHTSatellite xmlns:u="+chr(34)
    subXML=subXML+"urn:schemas-upnp-org:service:DeviceProperties:1"+chr(34)
    subXML=subXML+"><HTSatChanMapSet>PLAYBAR_UDN:LF,RF;SUB_UDN:SW</HTSatChanMapSet></u:AddHTSatellite>"
    subXML=subXML+"</s:Body></s:Envelope>"

    soapTransfer.SetUrl( connectedPlayerIP + "/DeviceProperties/Control")
    ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:DeviceProperties:1#AddHTSatellite")
    if not ok then
        stop
    end if
    ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
    if not ok then
        stop
    end if

    ' set the correct Playbar UDN in the request string
    playbar_regex = CreateObject("roRegex", "PLAYBAR_UDN", "i")
    subXML = playbar_regex.ReplaceAll(subXML, s9UDN)

    sub_regex = CreateObject("roRegex", "SUB_UDN", "i")
    reqString = sub_regex.ReplaceAll(subXML, subUDN)

    print "Executing SubControl: ";connectedPlayerIP
    ok = soapTransfer.AsyncPostFromString(reqString)
    if not ok then
        stop
    end if

    return soapTransfer

end Sub

Sub SonosSubUnbond(mp as object, connectedPlayerIP as string, subUDN as string) as object

    soapTransfer = CreateObject("roUrlTransfer")
    soapTransfer.SetMinimumTransferRate( 2000, 1 )
    soapTransfer.SetPort( mp )

    sonosReqData=CreateObject("roAssociativeArray")
    sonosReqData["type"]="SubUnbond"
    sonosReqData["dest"]=connectedPlayerIP
    soapTransfer.SetUserData(sonosReqData)

    subXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="
	subXML=subXML+chr(34)+"utf-8"+chr(34)+"?>"
    subXML=subXML+"<s:Envelope s:encodingStyle="+chr(34)
    subXML=subXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
    subXML=subXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
    subXML=subXML+"><s:Body><u:RemoveHTSatellite xmlns:u="+chr(34)
    subXML=subXML+"urn:schemas-upnp-org:service:DeviceProperties:1"+chr(34)
    subXML=subXML+"><SatRoomUUID>SUB_UDN</SatRoomUUID></u:RemoveHTSatellite>"
    subXML=subXML+"</s:Body></s:Envelope>"

    soapTransfer.SetUrl( connectedPlayerIP + "/DeviceProperties/Control")
    ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:DeviceProperties:1#RemoveHTSatellite")
    if not ok then
        stop
    end if
    ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
    if not ok then
        stop
    end if

    sub_regex = CreateObject("roRegex", "SUB_UDN", "i")
    reqString = sub_regex.ReplaceAll(subXML, subUDN)

    print "Executing SubUnbond: ";connectedPlayerIP
    ok = soapTransfer.AsyncPostFromString(reqString)
    if not ok then
        stop
    end if

    return soapTransfer

end Sub


Sub SonosSurroundCtrl(mp as object, connectedPlayerIP as string, enableVal as integer) as object
	
	' print "SonosSurroundCtrl"

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SurroundCtrl"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	subXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	subXML=subXML+"<s:Envelope s:encodingStyle="+chr(34)
	subXML=subXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	subXML=subXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	subXML=subXML+"><s:Body><u:SetEQ xmlns:u="+chr(34)
	subXML=subXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	subXML=subXML+"><InstanceID>0</InstanceID>"
	subXML=subXML+"<EQType>SurroundEnable</EQType><DesiredValue>ENABLEVALUE</DesiredValue></u:SetEQ>"
	subXML=subXML+"</s:Body></s:Envelope>"
	
	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#SetEQ")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	' set the correct Mute value in the request string
	r = CreateObject("roRegex", "ENABLEVALUE", "i")
	if enableVal=0 then 
		reqString=r.ReplaceAll(subXML,"0")
	else
		reqString=r.ReplaceAll(subXML,"1")
	end if

	print "Executing SubControl: ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return soapTransfer
end sub


Sub SonosSetSleepTimer(sonos as object, sonosDevice as object, timeout as string) 

	connectedPlayerIP = sonosDevice.baseURL
	if (timeout = "") and (sonosDevice.SleepTimerGeneration = 0) then
		' don't do the SOAP call since the device is already has the sleep timer disabled
		print "+++ SleepTimer already set to 0 - ignoring command"

		' Post the next command in the queue for this player
		postNextCommandInQueue(sonos, connectedPlayerIP)
	else
		mp = sonos.mp


		xmlString="<s:Envelope xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
		xmlString=xmlString+" s:encodingStyle="+chr(34)+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
		xmlString=xmlString+"><s:Body><u:ConfigureSleepTimer xmlns:u="+chr(34)+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
		xmlString=xmlString+"><InstanceID>0</InstanceID><NewSleepTimerDuration>TIMOUTPERIOD</NewSleepTimerDuration>"
		xmlString=xmlString+"</u:ConfigureSleepTimer>"
		xmlString=xmlString+"</s:Body></s:Envelope>"

		r1 = CreateObject("roRegex", "TIMOUTPERIOD", "i")
		reqString = r1.ReplaceAll(xmlString, timeout)

		sTransfer = CreateObject("roUrlTransfer")
		sTransfer.SetMinimumTransferRate( 2000, 1 )
		sTransfer.SetPort( mp )

		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetSleepTimer"
		sonosReqData["dest"]=connectedPlayerIP
		sTransfer.SetUserData(sonosReqData)

		sTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
		ok = sTransfer.addHeader("SOAPACTION", chr(34)+"urn:schemas-upnp-org:service:AVTransport:1#ConfigureSleepTimer"+chr(34))
		if not ok then
			stop
		end if
		ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
		if not ok then
			stop
		end if
		
		print "Executing SubControl: ";connectedPlayerIP
		ok = sTransfer.AsyncPostFromString(reqString)
		if not ok then
			stop
		end if

		sonos.xferObjects.push(sTransfer)
	end if
end Sub


Sub SonosResetBasicEQ(mp as object, connectedPlayerIP as string) as object

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+" standalone="+chr(34)+"yes"+chr(34)
	xmlString=xmlString+" ?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:ResetBasicEQ xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	xmlString=xmlString+"><InstanceID>0</InstanceID>"
	xmlString=xmlString+"</u:ResetBasicEQ>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	sTransfer = CreateObject("roUrlTransfer")
	sTransfer.SetMinimumTransferRate( 2000, 1 )
	sTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="ResetBasicEQ"
	sonosReqData["dest"]=connectedPlayerIP
	sTransfer.SetUserData(sonosReqData)

	sTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/RenderingControl/Control")
	ok = sTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:RenderingControl:1#ResetBasicEQ")
	if not ok then
		stop
	end if
	ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing ResetBasicEQ: ";connectedPlayerIP
	ok = sTransfer.AsyncPostFromString(xmlString)
	if not ok then
		stop
	end if

	return sTransfer
end Sub


Sub SonosGetSleepTimer(mp as object, connectedPlayerIP as string) as object

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+" standalone="+chr(34)+"yes"+chr(34)
	xmlString=xmlString+" ?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:GetRemainingSleepTimerDuration xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
	xmlString=xmlString+"><InstanceID>0</InstanceID>"
	xmlString=xmlString+"</u:GetRemainingSleepTimerDuration>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	sTransfer = CreateObject("roUrlTransfer")
	sTransfer.SetMinimumTransferRate( 2000, 1 )
	sTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="GetSleepTimer"
	sonosReqData["dest"]=connectedPlayerIP
	sTransfer.SetUserData(sonosReqData)

	sTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
	ok = sTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AVTransport:1#GetRemainingSleepTimerDuration")
	if not ok then
		stop
	end if
	ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing GetSleepTimer: ";connectedPlayerIP
	ok = sTransfer.AsyncPostFromString(xmlString)
	if not ok then
		stop
	end if

	return sTransfer
end Sub

Sub SonosCheckAlarm(sonos as object, sonosDevice as object)

	connectedPlayerIP = sonosDevice.baseURL
	if sonosDevice.AlarmCheckNeeded = "yes" then
	
		' Get Alarm List
		mp = sonos.mp
		
		xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+" standalone="+chr(34)+"yes"+chr(34)
		xmlString=xmlString+" ?><s:Envelope s:encodingStyle="+chr(34)
		xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
		xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
		xmlString=xmlString+chr(34)+"><s:Body><u:ListAlarms xmlns:u="+chr(34)
		xmlString=xmlString+"urn:schemas-upnp-org:service:AlarmClock:1"+chr(34)
		xmlString=xmlString+" /></s:Body></s:Envelope>"

		sTransfer = CreateObject("roUrlTransfer")
		sTransfer.SetMinimumTransferRate( 2000, 1 )
		sTransfer.SetPort( mp )

		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="ListAlarms"
		sonosReqData["dest"]=connectedPlayerIP
		sTransfer.SetUserData(sonosReqData)

		sTransfer.SetUrl( connectedPlayerIP + "/AlarmClock/Control")
		ok = sTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AlarmClock:1#ListAlarms")
		if not ok then
			stop
		end if
		ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
		if not ok then
			stop
		end if
		
		print "Executing ListAlarms: ";connectedPlayerIP
		ok = sTransfer.AsyncPostFromString(xmlString)
		if not ok then
			stop
		end if
		sonos.xferObjects.push(sTransfer)

		if sonos.masterDevice=sonosDevice.modelNumber then
			sonosDevices=sonos.sonosDevices
			for each device in sonosDevices
				device.AlarmCheckNeeded = "no"
			end for
		else
			sonosDevice.AlarmCheckNeeded = "no"
		end if
		
	else
		print "Alarm Check not needed, device: " + sonosDevice.modelNumber
		' Post the next command in the queue for this player
		postNextCommandInQueue(sonos, connectedPlayerIP)
	end if

end Sub

Function SonosDestroyAlarm(mp as object, connectedPlayerIP as string, alarmId as string) as object

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+" standalone="+chr(34)+"yes"+chr(34)
	xmlString=xmlString+" ?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:DestroyAlarm xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:AlarmClock:1"+chr(34)
	xmlString=xmlString+"><ID>"+alarmId+"</ID></u:DestroyAlarm></s:Body></s:Envelope>"

	sTransfer = CreateObject("roUrlTransfer")
	sTransfer.SetMinimumTransferRate( 2000, 1 )
	sTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="DestroyAlarm"
	sonosReqData["dest"]=connectedPlayerIP
	sTransfer.SetUserData(sonosReqData)

	sTransfer.SetUrl( connectedPlayerIP + "/AlarmClock/Control")
	ok = sTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AlarmClock:1#DestroyAlarm")
	if not ok then
		stop
	end if
	ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing DestroyAlarm, ID: "+alarmId+", address: "+connectedPlayerIP
	ok = sTransfer.AsyncPostFromString(xmlString)
	if not ok then
		stop
	end if
	
	return sTransfer
	
end Function

Sub SonosSetPlayMode(sonos as object, sonosDevice as object) 

		connectedPlayerIP = sonosDevice.baseURL
	if (sonosDevice.CurrentPlayMode = "NORMAL") then
		' do nothing save time on the SOAP call
		print "+++ CurrentPlayMode already set to NORMAL - ignoring command"
		' Post the next command in the queue for this player
		postNextCommandInQueue(sonos, connectedPlayerIP)
	else
		mp = sonos.mp

		xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)
		xmlString=xmlString+"?><s:Envelope s:encodingStyle="+chr(34)
		xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
		xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
		xmlString=xmlString+chr(34)+"><s:Body><u:SetPlayMode xmlns:u="+chr(34)
		xmlString=xmlString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
		xmlString=xmlString+"><InstanceID>0</InstanceID><NewPlayMode>NORMAL</NewPlayMode>"
		xmlString=xmlString+"</u:SetPlayMode>"
		xmlString=xmlString+"</s:Body></s:Envelope>"

		sTransfer = CreateObject("roUrlTransfer")
		sTransfer.SetMinimumTransferRate( 2000, 1 )
		sTransfer.SetPort( mp )

		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetPlayMode"
		sonosReqData["dest"]=connectedPlayerIP
		sTransfer.SetUserData(sonosReqData)

		sTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
		ok = sTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AVTransport:1#SetPlayMode")
		if not ok then
			stop
		end if
		ok = sTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
		if not ok then
			stop
		end if
		
		print "Executing SetPlayMode: ";connectedPlayerIP
		ok = sTransfer.AsyncPostFromString(xmlString)
		if not ok then
			stop
		end if

		sonos.xferObjects.push(sTransfer)
	end if
end Sub


Sub SonosSetSong(sonos as object, myIP as string, connectedPlayerIP as string, mp3file as string) as object

	'xmlString = readASCIIFile("setsong.xml")

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)
	xmlString=xmlString+"?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:SetAVTransportURI xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
	xmlString=xmlString+"><InstanceID>0</InstanceID><CurrentURI>URISTRING"
	xmlString=xmlString+"</CurrentURI><CurrentURIMetaData /></u:SetAVTransportURI>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	URIString = "http://" + myIP + ":111/" + mp3file
	r1 = CreateObject("roRegex", "URISTRING", "i")
	reqString = r1.ReplaceAll(xmlString, URIString)

	sonos.masterDeviceLastTransportURI=URIString
	print "setting master AVTransportURI to [";URIString;"]"

	songTransfer = CreateObject("roUrlTransfer")
	songTransfer.SetMinimumTransferRate( 2000, 1 )
	songTransfer.SetPort( sonos.msgPort )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetSong"
	sonosReqData["dest"]=connectedPlayerIP
	songTransfer.SetUserData(sonosReqData)

	songTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
	ok = songTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI")
	if not ok then
		stop
	end if
	ok = songTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing SetSong: ";connectedPlayerIP
	ok = songTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return songTransfer
end Sub

Sub SonosSetSPDIF(sonos as object, connectedPlayerIP as string, sonosPlayerUDN as string) as object

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)
	xmlString=xmlString+"?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:SetAVTransportURI xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
	xmlString=xmlString+"><InstanceID>0</InstanceID><CurrentURI>SPDIFSTRING"
	xmlString=xmlString+"</CurrentURI><CurrentURIMetaData /></u:SetAVTransportURI>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	SPDIFString = "x-sonos-htastream:" + sonosPlayerUDN + ":spdif"
	r1 = CreateObject("roRegex", "SPDIFSTRING", "i")
	reqString = r1.ReplaceAll(xmlString, SPDIFString)

	sonos.masterDeviceLastTransportURI=SPDIFString
	print "setting master AVTransportURI to [";SPDIFString;"]"

	songTransfer = CreateObject("roUrlTransfer")
	songTransfer.SetMinimumTransferRate( 2000, 1 )
	songTransfer.SetPort( sonos.msgPort )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetSPDIF"
	sonosReqData["dest"]=connectedPlayerIP
	songTransfer.SetUserData(sonosReqData)


	songTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
	ok = songTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI")
	if not ok then
		stop
	end if
	ok = songTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing SetSPDIF: ";connectedPlayerIP
	ok = songTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return songTransfer
end Sub

Sub SonosGroupAll(s as object) as object

	print "SonosGroupAll"
	printAllDeviceTransportURI(s)

	' if for some reason we don't have one set, we make one set
	if s.masterDevice="" then
	    setSonosMasterDevice(s,"sall")
	end if

	master=GetDeviceByPlayerModel(s.sonosDevices, s.masterDevice)

	for each device in s.sonosDevices
	    if device.modelNumber<>s.masterDevice then
	        desired=isModelDesiredByUservar(s,device.modelNumber)
	        if desired=true then
	            l = len(device.AVTransportURI)
	            colon = instr(1,device.AVTransportURI,":")
	            uri=right(device.AVTransportURI,l-colon)
	            print "+++ comparing device URI [";uri;"] to master URI [";master.UDN;"]"
	            if uri<>master.UDN then
	                print "+++ grouping device ";device.modelNumber;" with master ";s.masterDevice
					xfer = SonosSetGroup(s.mp, device.baseURL, master.UDN)
					s.xferObjects.push(xfer)						
				else
				    print "+++ device ";device.modelNumber;" is already grouped with master ";s.masterDevice
				end if
			end if
	    end if
	end for
end sub

Sub SonosSetGroup(mp as object, connectedPlayerIP as string, sonosPlayerUDN as string) as object

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)
	xmlString=xmlString+"?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:SetAVTransportURI xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
	xmlString=xmlString+"><InstanceID>0</InstanceID><CurrentURI>UDNSTRING"
	xmlString=xmlString+"</CurrentURI><CurrentURIMetaData /></u:SetAVTransportURI>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	UDNString = "x-rincon:" + sonosPlayerUDN
	r1 = CreateObject("roRegex", "UDNSTRING", "i")
	reqString = r1.ReplaceAll(xmlString, UDNString)

	songTransfer = CreateObject("roUrlTransfer")
	songTransfer.SetMinimumTransferRate( 2000, 1 )
	songTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetGroup"
	sonosReqData["dest"]=connectedPlayerIP
	songTransfer.SetUserData(sonosReqData)


	songTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
	ok = songTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI")
	if not ok then
		stop
	end if
	ok = songTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	
	print "Executing SetGroup: ";connectedPlayerIP
	ok = songTransfer.AsyncPostFromString(reqString)
	if not ok then
		stop
	end if

	return songTransfer
end Sub

Sub SonosPlaySong(mp as object, connectedPlayerIP as string) as object

	'reqString = readASCIIFile("play.xml")
	
	reqString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="
	reqString=reqString+chr(34)+"utf-8"+chr(34)+"?>"
	reqString=reqString+"<s:Envelope s:encodingStyle="+chr(34)
	reqString=reqString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	reqString=reqString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	reqString=reqString+"><s:Body><u:Play xmlns:u="+chr(34)
	reqString=reqString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
	reqString=reqString+"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>"
	reqString=reqString+"</s:Body></s:Envelope>"

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 2000, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="PlaySong"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)


	soapTransfer.SetUrl( connectedPlayerIP + "/MediaRenderer/AVTransport/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:AVTransport:1#Play")
	if not ok then
		stop
	end if
	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if
	print "Executing PlaySong: ";connectedPlayerIP
	ok = soapTransfer.AsyncPostFromString(reqString)

	return soapTransfer
end sub


Function processSonosSetVolumeResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	'TIMING print "processSonosSetVolumeResponse from " + connectedPlayerIP+" at: ";sonos.st.GetLocalDateTime();

End Function


Function processSonosVolumeResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	'TIMING print "processSonosVolumeResponse from " + connectedPlayerIP+" at: ";sonos.st.GetLocalDateTime();
''	print msg

	match="<CurrentVolume>"
	pos1=instr(1,msg,match)
	pos2=instr(pos1+len(match)+1,msg,"</CurrentVolume>")
	if pos1 > 0 then
		pos1=pos1+len(match)
		volStr=mid(msg,pos1,pos2-pos1)
		print "Current Volume: " + volStr

		le = chr(10)
		for each d in sonos.sonosDevices
			ipstring=stripIP(d.baseURL)
			if d.baseURL=connectedPlayerIP then
				d.volume=val(volStr)
			end if
		end for
	end if

End Function


Function processSonosRDMResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	print "processSonosRDMResponse from " + connectedPlayerIP
	' print msg

	match="<CurrentRDM>"
	pos1=instr(1,msg,match)
	pos2=instr(pos1+len(match)+1,msg,"</CurrentRDM>")
	if pos1 > 0 then
		pos1=pos1+len(match)
		rdmStr=mid(msg,pos1,pos2-pos1)
		print "Current RDM: " + rdmStr
	end if

	le = chr(10)

	for each d in sonos.sonosDevices
		ipstring=stripIP(d.baseURL)
		if d.baseURL=connectedPlayerIP then
			d.rdm=val(rdmStr)
		end if

	end for

	' need to match up the device and set the volume value for it'
	' looks like we currently only store a single volme for all devices'
	' I think we need to change that?'

End Function


Function processSonosMuteResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	print "processSonosMuteResponse from " + connectedPlayerIP
	' print msg

	match="<CurrentMute>"
	pos1=instr(1,msg,match)
	pos2=instr(pos1+len(match)+1,msg,"</CurrentMute>")
	if pos1 > 0 then
		pos1=pos1+len(match)
		muteStr=mid(msg,pos1,pos2-pos1)
		print "Current Mute: " + muteStr
	end if

	' Send UDP indicating Mute Status
	netConfig = CreateObject("roNetworkConfiguration", 0)
	currentNet = netConfig.GetCurrentConfig()
	sender = createObject("roDatagramSender")
	ok = sender.SetDestination(currentNet.ip4_address, 5000)
	if not ok then
		stop
	end if

	if muteStr = "0" then 
		retVal = sender.send("mute:off")
		if (retVal <> 0) then 
			stop
		end if
	else
		retVal = sender.send("mute:on")
		if (retVal <> 0) then 
			stop
		end if
	end if
End Function


Function processSonosGroupResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	print "processSonosGroupResponse from " + connectedPlayerIP
	print msg

End Function


Function processSonosAlarmCheck(msg as object, connectedPlayerIP as string, sonos as Object)

	print "processSonosListAlarms from " + connectedPlayerIP

	match="<CurrentAlarmList>"
	pos1=instr(1,msg,match)
	pos2=instr(pos1+len(match)+1,msg,"</CurrentAlarmList>")
	if pos1 > 0 then
		pos1=pos1+len(match)
		s=mid(msg,pos1,pos2-pos1)
		alStr = escapedecode(s)
		print "CurrentAlarmList: " + alStr
		
		xml=CreateObject("roXMLElement")
		xml.Parse(alStr)
		
		alarms = xml.GetNamedElements("Alarm")
		for each x in xml.GetChildElements()
			id = x@ID
			if id <> invalid then
				xfer = SonosDestroyAlarm(sonos.mp, connectedPlayerIP, id)
				sonos.xferObjects.push(xfer)
			end if
		end for
		
	end if
	
end Function

Function stripIP(baseURL as string) as string

	match="//"
	pos1=instr(1,baseURL,match)
	pos2=instr(pos1+len(match)+1,baseURL,":")
	if pos1 > 0 then
		pos1=pos1+len(match)
		if pos2 > 0 then
			ip=mid(baseURL,pos1,pos2-pos1)
		else
			ip=mid(baseURL,pos1,pos2)
		end if
		print "IP: " + ip
	end if
	return ip
end function


Function HandleSonosXferEvent(msg as object, sonos as object) as boolean
	
	eventID = msg.GetSourceIdentity()
	eventCode = msg.GetResponseCode()

	found = false
	numXfers = sonos.xferObjects.count()
	i = 0
	while (not found) and (i < numXfers)
		id = sonos.xferObjects[i].GetIdentity()
		sonosReqData=sonos.xferObjects[i].GetUserData()
		if (id = eventID) then
			' See if this is the transfer being complete
			if (sonosReqData <> invalid) then 
				connectedPlayerIP=sonosReqData["dest"]
				reqData=sonosReqData["type"]
			else
				connectedPlayerIP = ""
				reqData = ""
			end if
			print "Message.getInt() = ";msg.getInt(); " reqData:";reqData;"  IP:"; connectedPlayerIP
			if (msg.getInt() = 1) then
''				print "HTTP return code: "; eventCode; " request type: ";reqData;" from ";connectedPlayerIP;" at: ";sonos.st.GetLocalDateTime()
				print "HTTP return code: "; eventCode; " request type: ";reqData;" from ";connectedPlayerIP
				if (eventCode = 200) then 
					if reqData="GetVolume" then
						processSonosVolumeResponse(msg,connectedPlayerIP,sonos)
					else if reqData="WifiCtrl" then
					    print "WifiCtrl response received"
					else if reqData="SetGroup" then
						processSonosSetGroupResponse(msg,connectedPlayerIP,sonos)
					else if reqData="SetVolume" then
						processSonosSetVolumeResponse(msg,connectedPlayerIP,sonos)
					else if reqData="GetRDM" then
						processSonosRDMResponse(msg,connectedPlayerIP,sonos)
					else if reqData="GetMute" then
						processSonosMuteResponse(msg,connectedPlayerIP,sonos)
					else if reqData="ListAlarms" then
						processSonosAlarmCheck(msg,connectedPlayerIP,sonos)
				    else if reqData="RegisterForAVTransportEvent" then
					    OnGenaSubscribeResponse(sonosReqData,msg, sonos)
					else if reqData="RegisterForRenderingControlEvent" then
					    OnGenaSubscribeResponse(sonosReqData,msg, sonos)
					else if reqData="RegisterForAlarmClockEvent" then
					    OnGenaSubscribeResponse(sonosReqData,msg, sonos)
					else if reqData="RegisterForZoneGroupTopologyEvent" then
					    OnGenaSubscribeResponse(sonosReqData,msg, sonos)
				    else if reqData="RenewRegisterForAVTransportEvent" then
					    OnGenaRenewResponse(sonosReqData,msg, sonos)
					else if reqData="RenewRegisterForRenderingControlEvent" then
					    OnGenaRenewResponse(sonosReqData,msg, sonos)
					else if reqData="RenewRegisterForAlarmClockEvent" then
					    OnGenaRenewResponse(sonosReqData,msg, sonos)
					else if reqData="RenewRegisterForZoneGroupTopologyEvent" then
					    OnGenaRenewResponse(sonosReqData,msg, sonos)
					end if
				end if		
					
				' See if we have a command in the command queue for this player, if so execute it
				postNextCommandInQueue(sonos, connectedPlayerIP)

				' delete this transfer object from the transfer object list
				sonos.xferObjects.Delete(i)
				found = true
			end if
		end if
		i = i + 1
	end while

	' now read from the POST queue'
	numPosts = sonos.postObjects.count()
	i = 0
	while (not found) and (i < numPosts)
		id = sonos.postObjects[i].GetIdentity()
		sonosReqData=sonos.postObjects[i].GetUserData()
		if (id = eventID) then
			' See if this is the transfer being complete
			if (sonosReqData <> invalid) then 
				connectedPlayerIP=sonosReqData["dest"]
				reqData=sonosReqData["type"]
			else
				connectedPlayerIP = ""
				reqData = ""
			end if
			if (msg.getInt() = 1) then
				print "HTTP return code: "; eventCode; " request type: ";reqData;" from ";connectedPlayerIP
				if (eventCode = 200) then 
					if reqData="rdmPing" then
					     print "+++ got reply for rdmPing"
					end if
				end if		

				' pop the next queued up message, if any'
				if connectedPlayerIP<>""
				    postNextCommandInQueue(sonos, connectedPlayerIP)
				end if

				' delete this transfer object from the transfer object list
				sonos.postObjects.Delete(i)
				found = true
			end if
		end if
		i = i + 1

    end while

	return found
end Function


function processSonosSetGroupResponse(msg,connectedPlayerIP,sonos)

	print "processSonosSetGroupResponse: from ";connectedPlayerIP
	print msg


end function

sub postNextCommandInQueue(sonos as object, connectedPlayerIP as string)
	' See how many commands we have the queue
	numCmds = sonos.commandQ.count()
	cmdFound = false
	x = 0
	if (numCmds > 0) then 
'TIMING'		print "+++ There are ";numCmds;" in the queue at ";sonos.st.GetLocalDateTime()
		print "+++ There are ";numCmds;" in the queue"
	end if

	' loop thru all of the commands to see if we can find one that matches this player IP
	while (not cmdFound) and (x < numCmds)
		' if a command is found that matches this IP, post that command
		if (sonos.commandQ[x].IP = connectedPlayerIP) then
			' send plugin message to ourself to execute the next queued command 
			sendPluginMessage(sonos, sonos.commandQ[x].msg)

			' delete this command from the command queue
			sonos.commandQ.Delete(x)
			cmdFound = true
		end if
		x = x + 1
	end while
end sub



Function SonosDeviceBusy(sonos as object, devType as String) as Boolean

	found = false
	IP = GetBaseIPByPlayerModel(sonos.sonosDevices, devType)
	if (IP <> "") then 
		numXfers = sonos.xferObjects.count()
		i = 0
		while (not found) and (i < numXfers)
			sonosReqData=sonos.xferObjects[i].GetUserData()
			if sonosReqData <> invalid
				connectedPlayerIP=sonosReqData["dest"]
				if connectedPlayerIP = IP
					found = true
				end if
			end if
			i = i + 1
		end while
	end if
	
	' if we found the device in the list it means the device is busy processing a request	
	return found
End Function

Function SendSelfUDP( msg as string)

	netConfig = CreateObject("roNetworkConfiguration", 0)
	currentNet = netConfig.GetCurrentConfig()
	sender = createObject("roDatagramSender")
	ok = sender.SetDestination(currentNet.ip4_address, 5000)
	if not ok then
		stop
	end if

	retVal = sender.send(msg)
	if (retVal <> 0) then 
		stop
	end if
End Function

Function AddMP3(s as object, directory as string)

	' Serve up two files to play....
	's.server.AddGetFromFile({ url_path: "/misery.mp3", filename: "SD:/misery.mp3", content_type: "audio/mpeg" })
	's.server.AddGetFromFile({ url_path: "/warning.mp3", filename: "SD:/warning.mp3", content_type: "audio/mpeg" })

	'  add the files 
	filepathmp3 = GetPoolFilePath(s.bsp.assetPoolFiles, "1.mp3")
	if Len(filepathmp3) > 0 then
		s.server.AddGetFromFile({ url_path: "/1.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
		print "File path for 1.mp3 = ";filepathmp3
	end if
	
	filepathmp3 = GetPoolFilePath(s.bsp.assetPoolFiles, "2.mp3")
	if Len(filepathmp3) > 0 then
		s.server.AddGetFromFile({ url_path: "/2.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
		print "File path for 2.mp3 = ";filepathmp3
	end if
	
	filepathmp3 = GetPoolFilePath(s.bsp.assetPoolFiles, "3.mp3")
	if Len(filepathmp3) > 0 then
		s.server.AddGetFromFile({ url_path: "/3.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
		print "File path for 3.mp3 = ";filepathmp3
	end if
	
	filepathmp3 = GetPoolFilePath(s.bsp.assetPoolFiles, "4.mp3")
	if Len(filepathmp3) > 0 then
		s.server.AddGetFromFile({ url_path: "/4.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
		print "File path for 4.mp3 = ";filepathmp3
	end if

End Function

Function SonosRegisterForEvents(sonos as Object, mp as Object, device as Object) as Object
	' SUBSCRIBE to events - requires 4.5.18 or later '
	avtransport_event_handler = { name: "AVTransport", HandleEvent: OnAVTransportEvent, SonosDevice: device, sonos:sonos}
	renderingcontrol_event_handler = { name: "RenderingControl", HandleEvent: OnRenderingControlEvent, SonosDevice: device, sonos:sonos}
	' DND-10 we listen for alarm clock events so we can turn alarms off if they get set
	alarmclock_event_handler = { name: "AlarmClock", HandleEvent: OnAlarmClockEvent, SonosDevice: device, sonos:sonos}
	zoneGroupTopology_event_handler = { name: "ZoneGroupTopology", HandleEvent: OnZoneGroupTopologyEvent, SonosDevice: device, sonos:sonos}

	sAVT="/gena/avtransport/"+device.UDN
	sRC ="/gena/renderingconrol/"+device.UDN
	sACLK = "/gena/alarmclock/"+device.UDN
	sZGT = "/gena/zonegrouptopology/"+device.UDN

	if not sonos.server.AddMethodToString({ method: "NOTIFY", url_path: sAVT, user_data: avtransport_event_handler }) then
		print "FAILURE:  cannot register a local URL for Sonos avtransport notifications"
	end if

	if not sonos.server.AddMethodToString({ method: "NOTIFY", url_path: sRC , user_data: renderingcontrol_event_handler }) then
		print "FAILURE:  cannot register a local URL for Sonos rendering notifications"
	end if

	if not sonos.server.AddMethodToString({ method: "NOTIFY", url_path: sACLK , user_data: alarmclock_event_handler }) then
		print "FAILURE:  cannot register a local URL for Sonos alarm clock notifications"
	end if

	if not sonos.server.AddMethodToString({ method: "NOTIFY", url_path: sZGT , user_data: zoneGroupTopology_event_handler }) then
		print "FAILURE:  cannot register a local URL for Sonos zone group topology notifications"
	end if

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="RegisterForAVTransportEvent"
	sonosReqData["dest"]=device.baseURL

	netConfig = CreateObject("roNetworkConfiguration", 0)
	currentNet = netConfig.GetCurrentConfig()
	'print "IP Address is :";currentNet.ip4_address
	ipAddress = currentNet.ip4_address

	eventRegister = CreateObject("roUrlTransfer")
	eventRegister.SetMinimumTransferRate( 2000, 1 )
	eventRegister.SetPort( mp )

	sURL=device.baseURL+"/MediaRenderer/AVTransport/Event"
	eventRegister.SetUrl(sURL)
	sHeader="<http://"+ipAddress+":111"+sAVT+">"
	eventRegister.AddHeader("Callback", sHeader)
	print "Setting Sonos at ["+sURL+"] to use callback at: ["+sHeader+"]"
	eventRegister.AddHeader("NT", "upnp:event")
	eventRegister.AddHeader("Timeout", "Second-7200")
	eventRegister.SetUserData(sonosReqData)
	sonos.xferObjects.push(eventRegister)

	if not eventRegister.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
		print "Failed to send SUBSCRIBE request: "; eventRegister.GetFailureReason()
		stop
	end if

	sonosReqData2=CreateObject("roAssociativeArray")
	sonosReqData2["type"]="RegisterForRenderingControlEvent"
	sonosReqData2["dest"]=device.baseURL

	eventRegister2 = CreateObject("roUrlTransfer")
	eventRegister2.SetMinimumTransferRate( 2000, 1 )
	eventRegister2.SetPort( mp )
	sURL2=device.baseURL+"/MediaRenderer/RenderingControl/Event"
	sHeader2="<http://"+ipAddress+":111"+sRC+">"
	' print "Setting Sonos at ["+sURL2+"] to use callback at ["+sHeader2+"]"
	eventRegister2.SetUrl(sURL2)
	eventRegister2.AddHeader("Callback", sHeader2)
	eventRegister2.AddHeader("NT", "upnp:event")
	eventRegister2.AddHeader("Timeout", "Second-7200")
  
	eventRegister2.SetUserData(sonosReqData2)
	sonos.xferObjects.push(eventRegister2)

	if not eventRegister2.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
		print "Failed to send SUBSCRIBE request: "; eventRegister2.GetFailureReason()
		stop
	end if

	sonosReqData3=CreateObject("roAssociativeArray")
	sonosReqData3["type"]="RegisterForAlarmClockEvent"
	sonosReqData3["dest"]=device.baseURL

	eventRegister3 = CreateObject("roUrlTransfer")
	eventRegister3.SetMinimumTransferRate( 2000, 1 )
	eventRegister3.SetPort( mp )
	sURL3=device.baseURL+"/AlarmClock/Event"
	sHeader3="<http://"+ipAddress+":111"+sACLK+">"
	' print "Setting Sonos at ["+sURL3+"] to use callback at ["+sHeader3+"]"
	eventRegister3.SetUrl(sURL3)
	eventRegister3.AddHeader("Callback", sHeader3)
	eventRegister3.AddHeader("NT", "upnp:event")
	eventRegister3.AddHeader("Timeout", "Second-7200")
  
	eventRegister3.SetUserData(sonosReqData3)
	sonos.xferObjects.push(eventRegister3)

	if not eventRegister3.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
		print "Failed to send SUBSCRIBE request: "; eventRegister3.GetFailureReason()
		stop
	end if

	sonosReqData4=CreateObject("roAssociativeArray")
	sonosReqData4["type"]="RegisterForZoneGroupTopologyEvent"
	sonosReqData4["dest"]=device.baseURL

	eventRegister4 = CreateObject("roUrlTransfer")
	eventRegister4.SetMinimumTransferRate( 2000, 1 )
	eventRegister4.SetPort( mp )
	sURL4=device.baseURL+"/ZoneGroupTopology/Event"
	sHeader4="<http://"+ipAddress+":111"+sZGT+">"
	' print "Setting Sonos at ["+sURL4+"] to use callback at ["+sHeader4+"]"
	eventRegister4.SetUrl(sURL4)
	eventRegister4.AddHeader("Callback", sHeader4)
	eventRegister4.AddHeader("NT", "upnp:event")
	eventRegister4.AddHeader("Timeout", "Second-7200")
  
	eventRegister4.SetUserData(sonosReqData4)
	sonos.xferObjects.push(eventRegister4)

	if not eventRegister4.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
		print "Failed to send SUBSCRIBE request: "; eventRegister4.GetFailureReason()
		stop
	end if

end Function


Sub OnGenaSubscribeResponse(userData as object,e as Object, s as object)
	
	sonosPlayerBaseUrl = userData.dest
	reqType = userData.type
	print "GENA "+ reqType + " subscribe response from: " + sonosPlayerBaseUrl
	code=e.GetResponseCode()
	headers = e.GetResponseHeaders()

	if headers<>invalid
	  SID = headers["sid"]
	else
	  SID = "none"
	endif

	for i = 0 to s.sonosDevices.count() - 1
		if (s.sonosDevices[i].baseURL = sonosPlayerBaseUrl) then
			if (reqType = "RegisterForAVTransportEvent") then
				s.sonosDevices[i].avTransportSID = SID
			else if (reqType = "RegisterForRenderingControlEvent") then
				s.sonosDevices[i].renderingSID = SID
			else if (reqType = "RegisterForAlarmClockEvent") then
				s.sonosDevices[i].alarmClockSID = SID
			else if (reqType = "RegisterForZoneGroupTopologyEvent") then
				s.sonosDevices[i].zoneGroupTopologySID = SID
			end if
		end if
	end for
End Sub

Function SonosRenewRegisterForEvents(sonos as Object)

	' Loop thru all of the devices and renew the register for events
	for each device in sonos.sonosDevices

	    if device.desired=true

			' Set up the Transfer Object AV Transport
			eventRegister = CreateObject("roUrlTransfer")
			eventRegister.SetMinimumTransferRate( 2000, 1 )
			eventRegister.SetPort( sonos.msgPort )

			' Set the URL for the AVTransport Events
			sURL=device.baseURL+"/MediaRenderer/AVTransport/Event"
			eventRegister.SetUrl(sURL)

			'  Add the headers for renewing, we only need 2, SID and Timeout
			eventRegister.AddHeader("SID", device.avTransportSID)
			eventRegister.AddHeader("Timeout", "Second-7200")

			' Set up the request data so we get http return we know where it came from
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RenewRegisterForAVTransportEvent"
			sonosReqData["dest"]=device.baseURL
			eventRegister.SetUserData(sonosReqData)

			' Start the renew request
			if not eventRegister.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
				print "Failed to send SUBSCRIBE request: "; eventRegister.GetFailureReason()
				stop
			else
				' put the request in the list 
				sonos.xferObjects.push(eventRegister)
			end if

			' Set up the Transfer Object for Rendering Control
			eventRegister2 = CreateObject("roUrlTransfer")
			eventRegister2.SetMinimumTransferRate( 2000, 1 )
			eventRegister2.SetPort( sonos.msgPort )

			' Set the URL for the RenderingControl Events
			sURL2=device.baseURL+"/MediaRenderer/RenderingControl/Event"
			eventRegister2.SetUrl(sURL2)

			'  Add the headers for renewing, we only need 2, SID and Timeout
			eventRegister2.AddHeader("SID", device.renderingSID)
			eventRegister2.AddHeader("Timeout", "Second-7200")

			' Set up the request data so we get http return we know where it came from
			sonosReqData2=CreateObject("roAssociativeArray")
			sonosReqData2["type"]="RenewRegisterForRenderingControlEvent"
			sonosReqData2["dest"]=device.baseURL
			eventRegister2.SetUserData(sonosReqData2)

			' Start the renew request
			if not eventRegister2.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
				print "Failed to send SUBSCRIBE request: "; eventRegister2.GetFailureReason()
				stop
			else
				' put the request in the list 
				sonos.xferObjects.push(eventRegister2)
			end if

			' Set up the Transfer Object for Alarm Clock
			eventRegister3 = CreateObject("roUrlTransfer")
			eventRegister3.SetMinimumTransferRate( 2000, 1 )
			eventRegister3.SetPort( sonos.msgPort )

			' Set the URL for the AlarmClock Events
			sURL3=device.baseURL+"/AlarmClock/Event"
			eventRegister3.SetUrl(sURL3)

			'  Add the headers for renewing, we only need 2, SID and Timeout
			eventRegister3.AddHeader("SID", device.alarmClockSID)
			eventRegister3.AddHeader("Timeout", "Second-7200")

			' Set up the request data so we get http return we know where it came from
			sonosReqData3=CreateObject("roAssociativeArray")
			sonosReqData3["type"]="RenewRegisterForAlarmClockEvent"
			sonosReqData3["dest"]=device.baseURL
			eventRegister3.SetUserData(sonosReqData3)

			' Start the renew request
			if not eventRegister3.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
				print "Failed to send SUBSCRIBE request: "; eventRegister3.GetFailureReason()
				stop
			else
				' put the request in the list 
				sonos.xferObjects.push(eventRegister3)
			end if

			' Set up the Transfer Object for Zone Group Topology
			eventRegister4 = CreateObject("roUrlTransfer")
			eventRegister4.SetMinimumTransferRate( 2000, 1 )
			eventRegister4.SetPort( sonos.msgPort )

			' Set the URL for the ZoneGroupTopology Events
			sURL4=device.baseURL+"/ZoneGroupTopology/Event"
			eventRegister4.SetUrl(sURL4)

			'  Add the headers for renewing, we only need 2, SID and Timeout
			eventRegister4.AddHeader("SID", device.zoneGroupTopologySID)
			eventRegister4.AddHeader("Timeout", "Second-7200")

			' Set up the request data so we get http return we know where it came from
			sonosReqData4=CreateObject("roAssociativeArray")
			sonosReqData4["type"]="RenewRegisterForZoneGroupTopologyEvent"
			sonosReqData4["dest"]=device.baseURL
			eventRegister4.SetUserData(sonosReqData4)

			' Start the renew request
			if not eventRegister4.AsyncMethod({ method: "SUBSCRIBE", response_body_string: true }) then
				print "Failed to send SUBSCRIBE request: "; eventRegister4.GetFailureReason()
				stop
			else
				' put the request in the list 
				sonos.xferObjects.push(eventRegister4)
			end if

		else
			print "player ";device.modelNumber;" is not desired by this presentation"
		end if
	end for

end Function

Sub OnGenaRenewResponse(userData as object,e as Object, s as object)
	
	sonosPlayerBaseUrl = userData.dest
	reqType = userData.type
    print "GENA "+ reqType + " subscribe response from: " + sonosPlayerBaseUrl
    code=e.GetResponseCode()
	headers = e.GetResponseHeaders()
	SID = headers["sid"]

	for i = 0 to s.sonosDevices.count() - 1
		if (s.sonosDevices[i].baseURL = sonosPlayerBaseUrl) then
			if (reqType = "RenewRegisterForAVTransportEvent") then
				s.sonosDevices[i].avTransportSID = SID
			else if (reqType = "RenewRegisterForRenderingControlEvent") then
				s.sonosDevices[i].renderingSID = SID
			else if (reqType = "RenewRegisterForAlarmClockEvent") then
				s.sonosDevices[i].alarmClockSID = SID
			else if (reqType = "RenewRegisterForZoneGroupTopologyEvent") then
				s.sonosDevices[i].zoneGroupTopologySID = SID
			end if
		end if
	end for
End Sub

Sub OnAVTransportEvent(userdata as Object, e as Object)
	s = userData.sonos
    
	if s.debugPrintEvents=true
		print "+++ OnAVTransportEvent:"
	    print e.GetRequestHeaders()
	    print e.GetRequestBodyString()
    end if

	sonosDevice=userData.SonosDevice
    'TIMING print "AV Transport Event [";sonosDevice.modelNumber;"] at: ";s.st.GetLocalDateTime()

    ' Big chunk of XML comes in here.
	rsp=CreateObject("roXMLElement")
	rsp.Parse(e.GetRequestBodyString())
	eventString = rsp.getnamedelements("e:property").lastchange.gettext()

	r = CreateObject("roRegex", "r:SleepTimerGeneration", "i")
    fixedEventString=r.ReplaceAll(eventString,"rSleepTimerGeneration")

	'print fixedEventString

	event = CreateObject("roXMLElement")
	event.parse(fixedEventString)

	'print "lastchange =";eventstring


	transportState = event.instanceid.transportstate@val
	if (transportState <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "TransportState", transportState)
		print "Transport event from ";sonosDevice.modelNumber;" TransportState: [";transportstate;"] "
	end if

	AVTransportURI = event.instanceid.AVTransportURI@val
	if (AVTransportURI <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "AVTransportURI", AVTransportURI)
		print "Transport event from ";sonosDevice.modelNumber;" AVTransportURI: [";AVTransportURI;"] "
		sonosDevice.foreignPlaybackURI = CheckForeignPlayback(s,sonosDevice.modelNumber,AVTransportURI)
		if sonosDevice.foreignPlaybackURI = true then
		    sendPluginEvent(s,"ForeignTransportStateURI")
		end if
	end if

	if (transportState <> invalid) then 
		if sonosDevice.foreignPlaybackURI and transportState="PLAYING" then
			foreignPlayBackActive = "1"
		else
			foreignPlayBackActive = "0"
		end if
		updateDeviceUserVariable(s, sonosDevice, "ForeignPlaybackActive", foreignPlayBackActive)
		if sonosDevice.foreignPlaybackURI = true then
			print "Sending ForeignTransportStateChange plugin event, foreignPlayBackActive = ";foreignPlayBackActive
		    sendPluginEvent(s,"ForeignTransportStateChange")
		end if
	end if
	
	CurrentPlayMode = event.instanceid.CurrentPlayMode@val
	if (CurrentPlayMode <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "CurrentPlayMode", CurrentPlayMode)
		print "Transport event from ";sonosDevice.modelNumber;" CurrentPlayMode: [";currentPlayMode;"] "
	end if

	SleepTimerGeneration = event.instanceid.rSleepTimerGeneration@val
	if (SleepTimerGeneration <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "SleepTimerGeneration", SleepTimerGeneration)
		print "Transport event from ";sonosDevice.modelNumber;" SleepTimerGeneration: [";SleepTimerGeneration;"] "
	end if

	' Send a plugin message to indicate at least one of the transport state variables has changed
	sendPluginEvent(s, sonosDevice.modelNumber+"TransportState")
	if (sonosDevice.modelNumber = s.masterDevice) then
		sendPluginEvent(s, "masterDevice"+"TransportState")
	end if

	'PrintAllSonosDevicesState(userData.sonos)
	diagId = "Sonos AVTransport event"
	s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " transportState: " + sonosDevice.transportstate + ", playMode: " + sonosDevice.CurrentPlayMode + ", sleepTimer: " + str(sonosDevice.SleepTimerGeneration))
	s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " transport URI: " + sonosDevice.AVTransportURI)

    if not e.SendResponse(200) then
		stop
    end if
End Sub



Function CheckForeignPlayback(s as Object, modelNumber as string, AVTransportURI as String) as object

	print "CheckForeignPlayback - device: ";modelNumber;" - ";AVTransportURI

	desired=isModelDesiredByUservar(s,modelNumber)
    if desired=false then
        print "+++ got unexpected messages from ";modelNumber;" which is NOT desired"
        return false
    end if

	if s.masterDevice="none" then
	    print "+++ master device is not yet set"
	    return false
	end if
	
	master=GetDeviceByPlayerModel(s.sonosDevices, s.masterDevice)
	if (master=invalid) then
	    print "+++ unable to find device for master";s.masterDevice
	    return false
	end if

	device=GetDeviceByPlayerModel(s.sonosDevices, modelNumber)
	if (device=invalid) then
	    print "+++ unable to find device for model";modelNumber
	    return false
	end if

	' if it's the master, check if it's the URI we set it to
    if device.modelNumber=s.masterDevice then
        if s.masterDeviceLastTransportURI=AVTransportURI then
            print "+++ master AVTransportURI matches what we set it to - local content"
            return false
        else
            print "+++ master AVTransportURI does NOT match what we set it to - foreign content"
            return true
        end if
    end if

	if master.AVTransportURI="" then
	    print "+++ master AVTransportURI is empty - assuming local content"
	    return false
	end if

    ' otherwise, make sure it's pointed at the master
    print "+++ comparing device URI [";AVTransportURI;"] to master URI [";master.UDN;"]"
    l = len(AVTransportURI)
    colon = instr(1,AVTransportURI,":")
    uri=right(AVTransportURI,l-colon)
    print "+++ comparing device URI [";uri;"] to master URI [";master.UDN;"]"

    if uri=master.UDN then
        print "+++ master AVTransportURI matches master - local content"
        return false
	else
        print "+++ master AVTransportURI does NOT match master - foreign content"
	    return true
	end if

	return false

end Function


Sub OnRenderingControlEvent(userdata as Object, e as Object)
	s = userData.sonos
    'TIMING print "Rendering Control Event at: ";s.st.GetLocalDateTime()
    'print e.GetRequestHeaders()
   	if s.debugPrintEvents=true
		print "+++ OnRenderingControlEvent:"
	    print e.GetRequestHeaders()
	    print e.GetRequestBodyString()
    end if

    sonosDevice=userData.SonosDevice    
    x=e.GetRequestBodyString()
    corrected=escapeDecode(x)
    
    'print corrected
    
    r2 = CreateObject("roRegex", "e:property", "i")
    pstr=r2.ReplaceAll(corrected,"eproperty")

    r=CreateObject("roXMLElement")
    r.Parse(pstr)

	changed = false
    vals=r.eproperty.LastChange.event.InstanceID
    for each x in vals.GetChildElements()
    	name=x.GetName()
	'    print "|"+name"|"	
		v=x@val
		if name="Volume"
			c=x@channel
			if c="Master"
				updateDeviceVariable(s, sonosDevice, "Volume", v)
				print "+++ Master volume changed (channel: ";c;")"
				changed = true
			else
				print "+++ Other volume changed (channel: ";c;")"
			end if
		else if name="Mute"
			c=x@channel
			if v = "1" then
				str$ = "muted"
			else
				str$ = "unmuted"
			end if
			if c="Master"
				updateDeviceVariable(s, sonosDevice, "Mute", v)
				print "+++ Master ";str$;" (channel: ";c;")"
				changed = true
				if v = "1" then
					sonosDevice.muteCheckNeeded = true
				else
					sonosDevice.muteCheckNeeded = false
				end if
			else
				print "+++ Other ";str$;" (channel: ";c;")"
			end if
			else if name="SubEnabled"
				updateDeviceVariable(s, sonosDevice, "subEnabled", v)
				changed = true
			else if name="SubGain"
				updateDeviceVariable(s, sonosDevice, "subGain", v)
				changed = true
			else if name="SubPolarity"
				updateDeviceVariable(s, sonosDevice, "subPolarity", v)
				changed = true
			else if name="SubCrossover"
				updateDeviceVariable(s, sonosDevice, "subCrossover", v)
				changed = true
			else if name="DialogLevel"
				updateDeviceVariable(s, sonosDevice, "dialogLevel", v)
				changed = true
			else if name="NightMode"
				updateDeviceVariable(s, sonosDevice, "nightMode", v)
				changed = true
		end if	
    end for

	' Send a plugin message to indicate at least one of the render state variables has changed
	if (changed) then
		sendPluginEvent(s, sonosDevice.modelNumber+"RenderState")
		if (sonosDevice.modelNumber = s.masterDevice) then
			sendPluginEvent(s, "masterDevice"+"RenderState")
		end if
	end if

	'PrintAllSonosDevicesState(userData.sonos)
	diagId = "Sonos Rendering event"
	s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " volume: " + str(sonosDevice.volume) + ", mute: " + str(sonosDevice.mute))

    if not e.SendResponse(200) then
		stop
    end if
End Sub

Sub OnAlarmClockEvent(userdata as Object, e as Object)
	s = userData.sonos
    'TIMING print "Alarm Clock Event at: ";s.st.GetLocalDateTime()
    'print e.GetRequestHeaders()
   	if s.debugPrintEvents=true
		print "+++ OnAlarmClockEvent:"
	    print e.GetRequestHeaders()
	    print e.GetRequestBodyString()
    end if

    sonosDevice=userData.SonosDevice    

    rsp=CreateObject("roXMLElement")
	rsp.Parse(e.GetRequestBodyString())
	
	rx = CreateObject("roRegex", ":", "i")

	changed = false
    vals = rsp.GetNamedElements("e:property")
    for each x in vals.GetChildElements()
    	name=x.GetName()
		if name="AlarmListVersion"
			ver = x.GetText()
			sec = rx.split(ver)
			if sec.count() > 1 then
				ver = sec[1]
			end if
			updateDeviceVariable(s, sonosDevice, "AlarmListVersion", ver)
		end if	
    end for

	diagId = "Sonos Alarm Clock event"
	s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " alarmCheckNeeded: " + sonosDevice.AlarmCheckNeeded)

    if not e.SendResponse(200) then
		stop
    end if
End Sub

Sub OnZoneGroupTopologyEvent(userdata as Object, e as Object)

	s = userData.sonos
    'TIMING print "Zone Group Topology Event at: ";s.st.GetLocalDateTime()
   	if s.debugPrintEvents=true
		print "+++ OnZoneGroupTopologyEvent:"
	    print e.GetRequestHeaders()
	    print e.GetRequestBodyString()
    end if
	
	' We only need to check messages from the sub and the bond master
	'  if we are only checking sub bonding
    sonosDevice=userData.SonosDevice
	
	bondMaster$ = "none"
	if s.userVariables["subBondTo"] <> invalid then
		bondMaster$ = s.userVariables["subBondTo"].currentValue$
	end if
	
	if sonosDevice.modelNumber = "sub" or sonosDevice.modelNumber = bondMaster$ then

		status$ = ""
		rsp=CreateObject("roXMLElement")
		rsp.Parse(e.GetRequestBodyString())	
		vals = rsp.GetNamedElements("e:property")
		for each x in vals
			element=x.GetChildElements().Simplify()
			name = element.GetName()
			if name="ZoneGroupState"
				status$ = CheckSubBonding(s, element.GetText())
				exit for
			end if	
		end for
		
		curStatus$ = getUserVariableValue(s, "subBondStatus")
		if curStatus$ <> invalid and curStatus$ <>status$ then
			sendPluginEvent(s, "TopologyChanged")
		end if

		if status$.Len() > 0 then
			updateUserVar(s.userVariables, "subBondStatus", status$, true)	
			diagId = "Zone Group Topology event"
			s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " Sub Bonding Status: " + status$)
		end if
		
	end if

    if not e.SendResponse(200) then
		stop
    end if

End Sub

Function CheckSubBonding(s as object, zoneGroupStateXml$ as string) as string

	bondMaster$ = "none"
	if s.userVariables["subBondTo"] <> invalid then
		bondMaster$ = s.userVariables["subBondTo"].currentValue$
	end if

	bondMaster = GetDeviceByPlayerModel(s.sonosDevices, bondMaster$)
	if bondMaster = invalid then
		print "**** CheckSubBonding, bond master not found, NoBonding"
		return "NoBonding"
	end if

	subDevice = GetDeviceByPlayerModel(s.sonosDevices, "sub")
	subUDN = "none"
	if subDevice <> invalid then
		subUDN = subDevice.UDN
	end if
	
	master=GetDeviceByPlayerModel(s.sonosDevices, s.masterDevice)
	if master = invalid then
		master = bondMaster
	end if
	
	'print "******** CheckSubBonding, master= ";master.UDN;", bondMaster = ";bondMaster.UDN;", sub = ";subUDN

	rsp=CreateObject("roXMLElement")
	rsp.Parse(zoneGroupStateXml$)
	groups = rsp.GetNamedElements("ZoneGroup")

	for each group in groups
		'print "** group coordinator: ";group@coordinator
		if group@Coordinator = master.UDN then
			members = group.GetNamedElements("ZoneGroupMember")
			for each member in members
				'print "*** member: ";member@UUID
				if member@UUID = bondMaster.UDN then
					' First check for a channel map, and see if master thinks is bonded to a SUB
					s.masterBondedToSubUDN = "none"
					channelMap = member@HTSatChanMapSet
					if type(channelMap) = "roString" then
						rx = CreateObject("roRegex", ";", "i")
						chans = rx.split(channelMap)
						for each chan in chans
							rx2 = CreateObject("roRegex", ":", "i")
							chanComps = rx2.split(chan)
							if chanComps[1] = "SW" then
								s.masterBondedToSubUDN = chanComps[0]
							end if
						end for
					end if
					if subUDN <> "none" and s.masterBondedToSubUDN <> "none" and s.masterBondedToSubUDN <> subUDN then
						' master is bonded to a different SUB than ours!
						print "**** CheckSubBonding, master bonded to different SUB, status: Bonded/missing"
						return "Bonded/missing"
					end if
					' Look for Satellite entry
					' If our SUB has gone offline, it will not be in this list
					satellites = member.GetNamedElements("Satellite")
					for each satellite in satellites
					    'print "**** satellite: ";satellite@UUID
						if satellite@UUID = subUDN then
							print "**** CheckSubBonding, Bonded"
							return "Bonded"
						end if
					end for
					' Our SUB is either missing or not in the Satellite list
					' If the master is bonded to something, the SUB is therefore missing
					if s.masterBondedToSubUDN <> "none" then
						print "**** CheckSubBonding, master bonded, but our SUB isn't found: Bonded/missing"
						return "Bonded/missing"
					end if
				end if
			end for
		end if
	end for
	
	print "**** CheckSubBonding, Unbonded"
	return "Unbonded"

End Function

Sub updateDeviceVariable(sonos as object, sonosDevice as object, variable as string, value as string)

	print "updateDeviceVariable: ";variable;", device: ";sonosDevice.modelNumber
	
	if variable = "Volume" then
		print "Volume at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.volume=val(value)
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
	else if variable = 	"Mute" then
		print "Mute at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.mute=val(value)
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
	else if variable = "TransportState" then
		print "TransportState at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.transportState = value
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
	else if variable = "CurrentPlayMode" then
		print "CurrentPlayMode at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.CurrentPlayMode = value
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
	else if variable = "AVTransportURI" then
		print "AVTransportURI at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.AVTransportURI = value
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
		printAllDeviceTransportURI(sonos)
	else if variable = "SleepTimerGeneration" then
		print "SleepTimerGeneration at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.SleepTimerGeneration = val(value)
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
	else if variable = "AlarmListVersion" then
		print "AlarmListVersion at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		last = sonosDevice.AlarmListVersion
		sonosDevice.AlarmListVersion = val(value)
		if (last <> sonosDevice.AlarmListVersion) then
			print "AlarmListVersionChanged, set "+sonosDevice.modelNumber+"AlarmCheckNeeded = yes"
			sonosDevice.AlarmCheckNeeded = "yes"
			updateDeviceUserVariable(sonos, sonosDevice, "AlarmCheckNeeded", "yes")
		end if 
	else if variable = 	"subEnabled" then
		sonosDevice.subEnabled=val(value)
		updateUserVar(sonos.userVariables, variable, value, false)
	else if variable = 	"subGain" then
		sonosDevice.subGain=val(value)
		updateUserVar(sonos.userVariables, variable, value, false)
	else if variable = 	"subPolarity" then
		sonosDevice.subPolarity=val(value)
		updateUserVar(sonos.userVariables, variable, value, false)
	else if variable = 	"subCrossover" then
		sonosDevice.subCrossover=val(value)
		updateUserVar(sonos.userVariables, variable, value, false)
	else if variable = 	"dialogLevel" then
		sonosDevice.dialogLevel=val(value)
		updateUserVar(sonos.userVariables, variable, value, false)
	else if variable = 	"nightMode" then
		sonosDevice.nightMode=val(value)
		updateUserVar(sonos.userVariables, variable, value, false)
	end if

end Sub


sub printAllDeviceTransportURI(sonos as object)
	' debug code for comparing states in different scenarios'
	print "printAllDeviceTransportURI - master: ";sonos.masterDevice
	for each device in sonos.sonosDevices
	    if device.desired=true
	        l = len(device.AVTransportURI)
	        colon = instr(1,device.AVTransportURI,":")
	        uri=right(device.AVTransportURI,l-colon)
	        deviceUDN = GetDeviceByUDN(sonos.sonosDevices, uri)
	        if deviceUDN<>invalid
	            print "--- ";device.modelNumber;" AVTransportURI: ";device.AVTransportURI;" - ";deviceUDN.modelNumber
            else
                print "--- ";device.modelNumber;" AVTransportURI: ";device.AVTransportURI
	        end if
        end if
	end for
end sub



Sub updateDeviceUserVariable(sonos as object, sonosDevice as object, variable as string, value as string)
	' Update the uservariable for this device
	if (sonos.userVariables[sonosDevice.modelNumber+variable] <> invalid) then
		sonos.userVariables[sonosDevice.modelNumber+variable].SetCurrentValue(value, true)
	end if	

	' Update the master device user variable if the model number matches the master device
	if (sonos.masterDevice = sonosDevice.modelNumber) then
		if (sonos.userVariables["masterDevice"+variable] <> invalid) then
			print "Setting masterDevice";variable" to: ";value
			sonos.userVariables["masterDevice"+variable].SetCurrentValue(value, true)
		end if
	end if
end sub	

function escapeDecode(str as String) as String
	nstr="" 
	pstr="" 
	n=0
	r = CreateObject("roRegex", "&", "i")
	frags=r.split(str)
	for each s in frags
		if n <> 0 then
			r2 = CreateObject("roRegex", "lt;", "i")
			pstr=r2.ReplaceAll(s,"<")
			r3 = CreateObject("roRegex", "gt;", "i")
			pstr=r3.ReplaceAll(pstr,">")
			r4 = CreateObject("roRegex", "quot;", "i")
			pstr=r4.ReplaceAll(pstr,chr(34))
			r5 = CreateObject("roRegex", "apos;", "i")
			pstr=r5.ReplaceAll(pstr,chr(39))
			nstr=nstr+pstr
		else
			nstr=nstr+s   
		end if
		n=n+1
	end for

	return nstr
end function


Sub PrintXML(element As Object, depth As Integer)
	print tab(depth*3);"Name: ";element.GetName()
	if not element.GetAttributes().IsEmpty() then
		print tab(depth*3);"Attributes: ";
		for each a in element.GetAttributes()
			print a;"=";left(element.GetAttributes()[a], 20);
			if element.GetAttributes().IsNext() then print ", ";
		end for
		print
	end if
	if element.GetText()<>invalid then
		print tab(depth*3);"Contains Text: ";left(element.GetText(), 40)
	end if
	if element.GetChildElements()<>invalid
		print tab(depth*3);"Contains roXMLList:"
		for each e in element.GetChildElements()
			PrintXML(e, depth+1)
		end for
	end if
	print
end sub


Function rdmPingAsync(mp as object,connectedPlayerIP as string, hhid as string) as Object
	print "rdmPingAsync: ";hhid;" for ";connectedPlayerIP

	sURL="/rdmping"
	v={}
	v.hhid=hhid
	b = postFormDataAsync(mp,connectedPlayerIP,sURL,v,"rdmPing")
	return b
end Function


Function rdmHouseholdSetupAsync(mp as object,connectedPlayerIP as string, hhid as string, name as string, icon as string, reboot as integer) as Object

	print "setting hhhid: ";hhid;" for ";connectedPlayerIP

	sURL="/rdmhhsetup"
	v={}
	v.hhid=hhid
	v.name=name
	v.icon=icon
	v.wto="60"
	v.reboot=str(reboot)
	v.reboot=v.reboot.trim()
	b = postFormDataAsync(mp,connectedPlayerIP,sURL,v,"rdmHouseholdSetup")
	return b
end Function


Function postFormDataAsync(mp as object, connectedPlayerIP as object, sURL as string, vars as Object, reqType as object) as Object
	
	targetURL=connectedPlayerIP+sURL
    fTransfer = CreateObject("roUrlTransfer")
    fTransfer.SetUrl(targetURL)
    fTransfer.SetPort(mp)

    sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]=reqType
	sonosReqData["dest"]=connectedPlayerIP
	fTransfer.SetUserData(sonosReqData)

	postString=""
	for each v in vars
			''    print "*** "+v
	    if postString<>""
	      postString=postString+"&"
	    endif
	    postString=postString+fTransfer.escape(v)+"="+fTransfer.escape(vars[v])
	next

	print "POSTing "+postString+" to "+sURL

	ok = fTransfer.AsyncPostFromString(postString)
	if not ok then
		stop
	end if
	return fTransfer
end Function  



Function SonosPlayerReboot(mp as object, connectedPlayerIP as string)
	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="reboot"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP
	print "REBOOT ";connectedPlayerIP


	url=connectedPlayerIP+"/reboot"
	soapTransfer.SetUrl(url)

	ok = soapTransfer.AsyncGetToString()
	if not ok then
		stop
	end if
	return (soapTransfer)
end Function


Sub SonosSoftwareUpdate(s as object, mp as object, connectedPlayerIP as string, serverURL as string, version as string) as object

	print "SonosSoftwareUpdate: "+connectedPlayerIP+" * "+serverURL+" * "+version

	' check if it's too old for us to use
	sonosDevice=GetDeviceByPlayerBaseURL(s.SonosDevices, connectedPlayerIP)
	sv=val(sonosDevice.softwareVersion)
	print "player software is at version ";sv
	if sv<22
	    ' if it is factor reset we have to punt'
	    if sonosDevice.hhid=""
	        playerName=getPlayerNameByModel(SonosDevice.modelNumber)
		    msgString="Sonos device "+playerName+" requires an update or a Household ID - please fix and reboot"
		    updateUserVar(s.userVariables,"manualUpdateMessage",msgString,false)
		    updateUserVar(s.userVariables,"requiresManualUpdate","yes",true)
		    print "+++ HALTING presentation - ";msgString
		    return invalid
	    else
	        print "Sonos device "+sonosDevice.modelNumber+" is at version ";sonosDevice.softwareVersion;" but has an hhid, continuing..."
	    end if
	else
	    print "player software is recent enough for use in this kiosk"
	end if

	reqString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	reqString=reqString+"<s:Envelope s:encodingStyle="+chr(34)
	reqString=reqString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	reqString=reqString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)+">"
	reqString=reqString+"<s:Body>"
	reqString=reqString+"<u:BeginSoftwareUpdate xmlns:u="+chr(34)+"urn:schemas-upnp-org:service:ZoneGroupTopology:1"+chr(34)+">"
	reqString=reqString+"<UpdateURL>http://BSPIP:111/UPDSTRING</UpdateURL><Flags>1</Flags></u:BeginSoftwareUpdate>"
	reqString=reqString+"</s:Body></s:Envelope>"

	r1 = CreateObject("roRegex", "BSPIP", "i")
	newString1 = r1.ReplaceAll(reqString, serverURL)
	r2 = CreateObject("roRegex", "UPDSTRING", "i")
	xmlstring = r2.ReplaceAll(newString1, "^"+version)

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 2000, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="BeginSoftwareUpdate"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/ZoneGroupTopology/Control")
	ok = soapTransfer.addHeader("SOAPACTION", "urn:schemas-upnp-org:service:ZoneGroupTopology:1#BeginSoftwareUpdate")
	if not ok then
		stop
	end if

	ok = soapTransfer.addHeader("Content-Type", "text/xml; charset="+ chr(34) + "utf-8" + chr(34))
	if not ok then
		stop
	end if

	' print "strlen: "+str(len(xmlString))
	' print xmlString
	ok = soapTransfer.AsyncPostFromString(xmlString)

	return soapTransfer
end sub



Function AddAllSonosUpgradeImages(s as object, version as string)
	
	file18 = version + "-1-8.upd"
	filepath18 = GetPoolFilePath(s.bsp.assetPoolFiles, file18)
	ok = s.server.AddGetFromFile({ url_path: "/" + file18, filename: filepath18, content_type: "application/octet-stream" })
	if (not ok) then	
		print "Unable to add ";file18;" upgrade file to server"
	end if

	file19 = version + "-1-9.upd"
	filepath19 = GetPoolFilePath(s.bsp.assetPoolFiles, file19)
	ok = s.server.AddGetFromFile({ url_path: "/" + file19, filename: filepath19, content_type: "application/octet-stream" })
	if (not ok) then
		print "Unable to add ";file19;" upgrade file to server"
	end if

	file116 = version + "-1-16.upd"
	filepath116 = GetPoolFilePath(s.bsp.assetPoolFiles, file116)
	ok = s.server.AddGetFromFile({ url_path: "/" + file116, filename: filepath116, content_type: "application/octet-stream" })
	if (not ok) then
		print "Unable to add ";file116;" upgrade file to server"
	end if

End Function


Function findPoolFilesByExt(extension as string) as object
	sync=CreateObject("roSyncSpec")
	if sync.ReadFromFile("current-sync.xml") then
  else if sync.ReadFromFile("local-sync.xml") then
  else
    return invalid
  end if

  a=[]
  n=0
  matchString=extension+"$"
	list=sync.GetFileList("download")
  r = CreateObject("roRegex", matchString, "i")
	for each l in list 
		match=r.IsMatch(l.name)
		if (match) then
		  file=sync.GetFile("download",n)
		  for each f in file
		    fileObj=newFileObj(file["name"],file["link"])
''		    print fileObj
        a.push(fileObj)
		  next
		endif
		n=n+1
	next
	return a
End Function

function newFileObj(name as string, link as string)

	f={}
	f.name=name
	f.link=link
	return f
end function


Function findAttachedilesByExt(bsp as object,extension as string) as object

	list=bsp.GetAttachedFiles()
  a=[]
  matchString=extension+"$"
	for each l in list 
  	r = CreateObject("roRegex", matchString, "i")
		match=r.IsMatch(l.filename$)
		if (match) then
	    fileObj=newFileObj(l.filename$,l.filepath$)
	    'print fileObj
      a.push(fileObj)
		endif
	next
	return a
End Function


' use this to send plugin events to a BrightAuthor Project
sub sendPluginEvent(sonos as object, message as string)
 	pluginMessageCmd = CreateObject("roAssociativeArray")
	pluginMessageCmd["EventType"] = "EVENT_PLUGIN_MESSAGE"
	pluginMessageCmd["PluginName"] = "sonos"
	pluginMessageCmd["PluginMessage"] = message
	sonos.msgPort.PostMessage(pluginMessageCmd)
end sub

' this is only to emulate sending an advanced command
sub sendPluginMessage(sonos as object, message as string)
	pluginMessageCmd = CreateObject("roAssociativeArray")
	pluginMessageCmd["EventType"] = "SEND_PLUGIN_MESSAGE"
	pluginMessageCmd["PluginName"] = "sonos"
	pluginMessageCmd["PluginMessage"] = message
	sonos.msgPort.PostMessage(pluginMessageCmd)
end sub

sub updateUserVar(uv as object, targetVar as string, newValue as string, postMsg as boolean)
	if newValue=invalid
	    print "updateUserVar: new value for ";targetVar;" is invalid"
	    return
	end if
	if targetVar=invalid
	    print "updateUserVar: targetVar is invalid"
	    return
	end if

	if uv[targetVar] <> invalid then
		uv[targetVar].SetCurrentValue(newValue, postMsg)
	else
	    print "updateUserVar: error trying to set non-existant user variable ";targetVar
	end if
end sub



Sub BubbleSortDeviceList(devices As Object)
	if type(devices) = "roArray" then
		n = devices.Count()
		while n <> 0
			newn = 0
			for i = 1 to (n - 1)
				if devices[i-1].modelNumber > devices[i].modelNumber then
					k = devices[i]
					devices[i] = devices[i-1]
					devices[i-1] = k
					newn = i
				endif
			next
			n = newn
		end while
	endif
End Sub

sub DeleteSonosDevice(userVariables as object, devices as object, baseURL as object)
	
	found = false
	deviceToDelete = 0
	for i=0 to devices.Count() - 1
		if devices[i].baseURL=baseURL then
			found = true
			deviceToDelete = i
		end if
	end for

	if found then
		modelNumber=devices[deviceToDelete].modelNumber
		print "***** deleting device ";modelNumber
		if (userVariables[modelNumber] <> invalid) then
			userVariables[modelNumber].currentValue$ = "notpresent"
		end if
		devices.delete(deviceToDelete)
	end if 
end sub

sub setbuttonstate(sonos as object, state as string)
	' If the user variable ButtonType = EUCapSense then set the two GPIO's to the following
	'        GPIO 3 7
	' learnmore = 1 0  (backward compatible)
	' s1		= 0 0
	' s3		= 0 1
	' s5		= 1 1 

	gpioPort = CreateObject("roControlPort", "BrightSign")
	if sonos.userVariables["ButtonType"] <> invalid then
		if sonos.userVariables["ButtonType"].currentValue$ = "EUCapSense" then
			print "setting EUCapSense button state as ";state
			if state = "s1" then
				gpioPort.SetOutputState(3, false)
				gpioPort.SetOutputState(7, false)
			else if state = "s3" then
				gpioPort.SetOutputState(3, false)
				gpioPort.SetOutputState(7, true)
			else if state = "s5" then
				gpioPort.SetOutputState(3, true)
				gpioPort.SetOutputState(7, true)
			else if state = "learnmore" then
				gpioPort.SetOutputState(3, true)
				gpioPort.SetOutputState(7, false)
			end if
		else
			print "setting button state for non-EUCapSense"
			' set the default state which is GPIO 3 on and GPIO 7 off
			gpioPort.SetOutputState(3, true)
			gpioPort.SetOutputState(7, false)
		end  if
	end if
end sub	
		

function getPlayerNameByModel(model as object) as String
	
	print "getPlayerNameByModel [";model;"]"
	if model="s1" then
	    return "PLAY:1"
	else if model="s3" then
	    return "PLAY:3"
    else if model="s5" then
	    return "PLAY:5"
    else if model="s9" then
	    return "PLAY:9"
	else if model="sub" then
		return "SUB"
	end if
	return model
end function		


