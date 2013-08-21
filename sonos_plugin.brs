' Plug-in script for BA 3.7.0.6 and greater

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
	s.version = 1.2
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


	' Need to remove once all instances of this are taken out of the Sonos code
	s.mp = msgPort

	' Create the http server for this app, use port 111 since 80 will be used by DWS
	s.server = CreateObject("roHttpServer", { port: 111 })
	if (s.server = invalid) then
		print "Unable to create server on port 111"
		stop
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

	' Create an array to hold the desired devices
	s.desiredDevices = createObject("roArray",0, true)

	' Variable for what is considered the master device
	s.masterDevice = ""

	' Keep track of all the devices that should be grouped for playing together
	s.playingGroup = createObject("roArray",0, true)

	' Create the UDP receiver port for the Sonos commands
	s.udpReceiverPort = 21000
	s.udpReceiver = CreateObject("roDatagramReceiver", s.udpReceiverPort)
	s.udpReceiver.SetPort(msgPort)

	' create the site's hhid 
	bspDevice = CreateObject("roDeviceInfo")
	bspSerial$= bspDevice.GetDeviceUniqueId()
	s.hhid="Sonos_RDM_"+bspSerial$
    if s.userVariables["siteHHID"] <> invalid
	    updateUserVar(s.userVariables,"siteHHID",s.hhid)
    else
        print "siteHHID user variable does not exist"
    end if
	return s
End Function


Function sonos_ProcessEvent(event As Object) as boolean

	retval = false

	if type(event) = "roAssociativeArray" then
        if type(event["EventType"]) = "roString"
             if (event["EventType"] = "SEND_PLUGIN_MESSAGE") then
                if event["PluginName"] = "sonos" then
                    pluginMessage$ = event["PluginMessage"]
					print "SEND_PLUGIN/EVENT_MESSAGE:";pluginMessage$
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
		'print "roHttp event received in Sonos processing"
	else if type(event) = "roTimerEvent" then
		if (event.GetSourceIdentity() = m.timer.GetIdentity()) then
			print "renewing for registering events"
			SonosRenewRegisterForEvents(m)
			retval = true
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
	print "FindAllSonosDevices"

	devices = s.devices
	CreateUPnPDiscoverer(s.msgPort, OnFound, s)
	s.disco.Discover("upnp:rootdevice")

	' make sure we don't leak roDatagramSockets on multiple tries to find units
	' disco.sock.SetUserData(invalid)

End Sub

Sub PrintAllSonosDevices(s as Object) 
    print "-- siteHHID:        "s.hhid
	devices = s.devices
	for each device in s.sonosDevices
		print "++ device url:      "+device.baseURL
		print "++ device model:    "+device.modelNumber
		print "++ device UDN:      "+device.UDN
		print "++ device type:     "+device.deviceType
		print "++ device volume:   "+str(device.volume)
		print "++ device rdm:      "+str(device.rdm)
		print "++ device mute:     "+str(device.mute)
		print "++ device t-state:  "+device.transportstate
		print "++ device t-sid:    "+device.avTransportSID
		print "++ device r-sid:    "+device.renderingSID
		print "++ device hhid:     "+device.hhid
		print "++ device uuid:     "+device.uuid
		print "++ device software: "+device.softwareVersion
		print "++ device bootseq:  "+device.bootseq
		print "++ transportState:  "+device.transportstate
		print "++ AVtransportURI:  "+device.AVTransportURI
		print "++ currentPlayMode: "+device.CurrentPlayMode
		print "++ UV: device:      ";s.userVariables[device.modelNumber].currentvalue$
		print "++ UV: HHID:        ";s.userVariables[device.modelNumber+"HHID"].currentvalue$
		print "++ UV: HHIDStatus:  ";s.userVariables[device.modelNumber+"HHIDstatus"].currentvalue$
		print "+++++++++++++++++++++++++++++++++++++++++"
	end for
End Sub


Sub PrintAllSonosDevicesState(s as Object) 
	devices = s.devices
        print "-- master device:   ";s.masterDevice
	for each device in s.sonosDevices
		print "++ device model:    "+device.modelNumber
		print "++ device t-state:  "+device.transportstate
		print "++ device t-sid:    "+device.avTransportSID
		print "++ device r-sid:    "+device.renderingSID
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
	    'print "@@@@@@@@@@@@@ NOTIFY respose: ";response
		'print "Received NOTIFY event"
		hhid=GetHouseholdFromUPNPMessage(response)
		bootseq=GetBootSeqFromUPNPMessage(response)
		responseLocation = GetLocationFromUPNPMessage(response)
		responseBaseURL = GetBaseURLFromLocation(responseLocation)
		sonosDevice = invalid
		for i = 0 to m.s.sonosDevices.count() - 1
  			if m.s.sonosDevices[i].baseURL = responseBaseURL then
				sonosDevice = m.s.sonosDevices[i]
				sonosDeviceIndex = i				
			endif
		end for

		aliveFound = instr(1,response,"NTS: ssdp:alive")
		rootDeviceString = instr(1,response,"NT: upnp:rootdevice")
		if (aliveFound) then
		    if(rootDeviceString) then
		        print "************ alive found ************ ";responseBaseURL
		        if (sonosDevice <> invalid) then
					print "Received ssdp:alive, device already in list "; responseBaseURL;" hhid: ";hhid;" old bootseq: "sonosDevice.bootseq;" new bootseq: ";bootseq
					sonosDevice.hhid=hhid
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid)
					xfer=rdmPingAsync(m.s.mp,SonosDevice.baseURL,hhid) 
					m.s.postObjects.push(xfer)

					' if this device is in our list but is in factory reset we need to reboot'
					if SonosDevice.hhid="" then
					    print "device has no hhid - rebooting!"					
					    RebootSystem()
					end if

					' if it's bootseq is different we need to punt and treat it as new
					if bootseq<>sonosDevice.bootseq then
					    print "+++ bootseq incremented - treating as a new player"
					    m.s.sonosDevices.delete(sonosDeviceIndex)
					    updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"HHIDStatus","pending")
					    SendXMLQuery(m.s, response)
					    goto done_all_found
					end if

				    ' Set the user variables
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber,"present")
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"Version",SonosDevice.softwareVersion)
					updateUserVar(m.s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid)


				else ' must be a new device
				    print "Received ssdp:alive, querying device..."
				    SendXMLQuery(m.s, response)
				end if ' sonosDevice '
			end if 'rootDeviceFound '
		end if ' aliveFound'

		byebyeFound = instr(1,response,"NTS: ssdp:byebye")
		if (byebyeFound) then
			rootDeviceString = instr(1,response,"NT: upnp:rootdevice")
			if(rootDeviceString) then
   			    print "&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&  Received ssdp:byebye ";responseLocation
				uuidStart=instr(1,response,"USN: uuid:")
				if (uuidStart) then 
					uuidStart=uuidStart+10
					uuidEnd=instr(uuidStart,response,"::")
					uuidString=mid(response,uuidStart,uuidEnd-uuidStart)
					'print "uuid: "+uuidString
					found = false
					i = 0
					numdevices = m.s.sonosDevices.count()
					while (not found) and (i < numdevices)  
						if (uuidString=m.s.sonosDevices[i].uuid) then
						  print "found player to delete "+m.s.sonosDevices[i].modelNumber+"with uuid: " + uuidString 
						  found = true
						  deviceNumToDelete = i
						end if
						i = i + 1
					end while
					if (found) then
						print "Deleting Player"+m.s.sonosDevices[deviceNumToDelete].modelNumber+"with uuid: " + uuidString
						' Indicate the player is no longer present
						if (m.s.userVariables[m.s.sonosDevices[deviceNumToDelete].modelNumber] <> invalid) then
							m.s.userVariables[m.s.sonosDevices[deviceNumToDelete].modelNumber].currentValue$ = "notpresent"
						end if
						m.s.sonosDevices.delete(deviceNumToDelete)
					else
						print "Got byebye but player is not in list:";response	
					end if		
				end if
			end if
		end if ' byebyeFound'
  end if

  done_all_found:
End Sub

Sub SendXMLQuery(s as object, response as string)
	Query = {}
	Query.response = response
	Query.hhid = GetHouseholdFromUPNPMessage(response)
	Query.bootseq = GetBootSeqFromUPNPMessage(response)
	Query.uuid = "none"
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
		'print "**** XML Query NOT Sent ****"
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
	start = instr(1,response,bootseq_string) + len(bootseq_string)
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




function findMatchingValidHHID(s as object)
	for each device in s.sonosDevices
      if (instr(1, device.hhid, "Sonos_RDM_")) then
	    for each d in s.sonosDevices
	        if d.modelNumber=device.modelNumber
	            goto next_device
	        end if
            print "findMatchingValidHHIDs: ";device.modelNumber;" - ";d.modelNumber
            if d.hhid=device.hhid
                ' two matching devices '
                print "devices ";d.modelNumber;"and ";device.modelNumber;" have hhid: "
                return d.hhid
	        end if    
		end for
        next_device:
      end if
	next
	return ""
end function


'function DetermineSiteHHID(s as object)

	' this function will scan a set of SonosDevices and return the HHID string that should be used for the site'

 ''     matchHHID=findMatchingValidHHID(s)
 ''     if matchHHID<>""
 ''       print "two devices have: ";matchHHID;" - using that as siteHHID"
 ''       return matchHHID
 ''     end if
    
	' if we get here we have no idea, so we'll just assume that any valid siteHHID is the right hhid by default
''	for each device in s.sonosDevices
''		if (instr(1, device.hhid, "Sonos_RDM_")) then
''		    print "using ";device.hhid;" as the site HHID"
''	        return device.hhid
''	    end if
 ''   next
''
 ''   ' if we get here, it means we basically have all factory reset players - so we'll make it up later!
  ''  print "no devices have a valid RDM HHID"
   '' return ""

'end function


sub CheckPlayerHHIDs(s as object) as boolean
	' this function will check the players hhid against the site hhid, and if it does not match it will mark it as needsUpdate'
	for each device in s.sonosDevices
	    print "looking at ";device.modelNumber;": [";device.hhid;"]"
        if device.hhid<>s.hhid
            updateUserVar(s.userVariables,device.modelNumber+"HHIDStatus","needsUpdate")
        else 
	        updateUserVar(s.userVariables,device.modelNumber+"HHIDStatus","valid")
	    end if
	end for
end sub


function DeterminePlayerStatus(s as Object, sonosDevice as object)

	stop
	' this function is deprecated and is still here only for refernce until we test the new approach'

	siteHHID="unknown"

	' refresh the masterDevice from user variable - is this the right way?  What's the cannonical location for this value?
	s.masterDevice=s.userVariables["masterDevice"].currentValue$ 


	' master device processing'
	if s.masterDevice=sonosDevice.modelNumber then

	    ' check if it's in factory reset
	    if SonosDevice.hhid=""
	        updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","needsUpdate")
	        goto finish
	    end if

	    if (instr(1, SonosDevice.hhid, "Sonos_RDM_")) then
	        siteHHID=SonosDevice.hhid
	        updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","valid")
	        updateUserVar(s.userVariables,"siteHHID",siteHHID)
	    else
	        updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","needsManualUpdate")
	    end if
	else ' not the master'
	    siteHHID=s.userVariables["siteHHID"].currentValue$

	    'if the siteHHID is not yet set we pretend we didn't find the player yet 
	    if siteHHID="unknown"
  	        updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","pending")
  	    else
  	        if SonosDevice.hhid=siteHHID
  	            'all good'
  	            updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","valid")
  	        else
  	            if SonosDevice.hhid=""
  	            	 updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","needsUpdate")
  	            	 goto finish
  	            else
  	            	 updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHIDStatus","needsManualUpdate")
  	            	 goto finish
  	            end if
  	        end if
  	    end if
	end if

	finish:
	return true
end Function

Sub UPNPDiscoverer_ProcessDeviceXML(ev as Object)
	'print "UPNPDiscoverer_ProcessDeviceXML"
	s = ev.GetUserData()
	deviceList = s.devices
	deviceXML = ev.GetObject()
	print deviceXML
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
	print "Num devices = ";numDevices
	while (i < numDevices) and (not found)
		id = deviceList[i].transfer.GetIdentity()
		if (id = deviceTransferID) then
			print "device matches transfer ID"
			found = true
			deviceList[i].complete = true
			deviceMfg  = deviceXML.device.manufacturer.gettext()
			deviceType = deviceXML.device.deviceType.gettext()
''			if (instr(1, deviceMfg, "Sonos")) then
			if (instr(1, deviceType, "urn:schemas-upnp-org:device:ZonePlayer:1")) then

				print "Found Sonos device on device XML"
				baseURL = GetBaseURLFromLocation(deviceList[i].location)
				model = GetPlayerModelByBaseIP(s.sonosDevices, baseURL)			
				model = lcase(model)

				if (model = "") then
					deviceList[i].deviceXML = deviceXML
					model = deviceXML.device.modelNumber.getText()

					SonosDevice = newSonosDevice(deviceList[i])

					' Set the user variables
					updateUserVar(s.userVariables,SonosDevice.modelNumber,"present")
					updateUserVar(s.userVariables,SonosDevice.modelNumber+"Version",SonosDevice.softwareVersion)
					updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid)


					' if this device was previously skipped on boot, we need to reboot'
					skippedString=model+"Skipped"
					if s.userVariables[skippedString] <> invalid then
					    skipVal=s.userVariables[skippedString].currentValue$ 
					    if skipVal="yes"
					        print "+++ skipped player ";model;" - rebooting!"
					        RebootSystem()
					    end if
					end if

					SonosRegisterForEvents(s, s.mp, SonosDevice)
					s.sonosDevices.push(SonosDevice)
				else
					print "Player ";model;" already exists in device list"
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

' this function is deprecated in favor of dynamically addeing devices '
'Sub PopulateSonosDevices( allDevices as Object, sonosDevices as Object)
''	
''	SonosIndex = 0
''	for i = 0 to allDevices.count() - 1
''		if (allDevices[i].sonosDevice) then
''			sonosDevices[SonosIndex] = newSonosDevice(allDevices[i])
''			SonosIndex = SonosIndex + 1
''		end if
''	end for
'end Sub



Sub newSonosDevice(device as Object) as Object
	sonosDevice = { baseURL: "", deviceXML: invalid, modelNumber: "", modelDescription: "", UDN: "", deviceType: "", hhid: "none", uuid: "", avTransportSID: "",renderingSID: "", softwareVersion: ""}
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
	sonosDevice.SleepTimerGeneration = 0
	sonosDevice.hhid=device.hhid
	sonosDevice.uuid=device.uuid
	sonosDevice.softwareVersion=lcase(device.deviceXML.device.softwareVersion.getText())
	sonosDevice.bootseq=device.bootseq

	print "device HHID:       ["+device.hhid+"]"
	print "device UUID:       ["+device.uuid+"]"
	print "software Version:  ["+sonosDevice.softwareVersion+"]"
	print "boot sequence:     ["+sonosDevice.bootseq+"]"

	return sonosDevice
end Sub

Sub GetPlayerModelByBaseIP(sonosDevices as Object, IP as string) as string
	
	returnModel = ""
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].baseURL = IP) then
			returnModel = sonosDevices[i].modelNumber
		end if
	end for

	return returnModel
end sub


Sub GetBaseIPByPlayerModel(sonosDevices as Object, modelNumber as string) as string
	
	newIP = ""
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].modelNumber = modelNumber) then
			newIP = sonosDevices[i].baseURL
		end if
	end for

	return newIP
end sub

Sub GetDeviceByPlayerModel(sonosDevices as Object, modelNumber as string) as object
	
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].modelNumber = modelNumber) then
			device = sonosDevices[i]
		end if
	end for
	return device

end sub



Function CheckGroupValid(sonosDevices as Object, masterDevice as object) as object
	masterString="x-rincon:"+masterDevice.UDN
	' if any of the devices don't have their AVTransportURI set to the UDN of the master then they are 
	' not grouped'
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].modelNumber <> masterDevice.modelNumber) then
		    'print "+++ comparing [";sonosDevices[i].AVTransportURI;"] to [";masterString;"]"
		    if sonosDevices[i].AVTransportURI<>masterString
		        print "+++ NOT Grouped!"
		        return false
		    end if
		end if
	end for
	print "+++ Grouped!"
	return true
end function



Function ParseSonosPluginMsg(origMsg as string, sonos as object) as boolean

	'TIMING print "Received command - ParseSonosPluginMsg: " + origMsg;" at: ";sonos.st.GetLocalDateTime()

	retval = false
		
	' convert the message to all lower case for easier string matching later
	msg = lcase(origMsg)
	print "Received Plugin message: "+msg
	' verify its a SONOS message'
	r = CreateObject("roRegex", "^SONOS", "i")
	match=r.IsMatch(msg)

	' Is this a sonos request
	if match then
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

			desired = false
			for i = 0 to sonos.desiredDevices.count() - 1
				if (devType = sonos.desiredDevices[i]) then
					'print "Found device ";devType;" in list of desired devices"
					desired = true
				end if
			end for

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
			' TOTO: should consider putting xferobjects inside functions where they belong!'
			if command="mute" then
				'if sonosDevice.mute=0
				    print "Sending mute"
					xfer = SonosSetMute(sonos.mp, sonosDevice.baseURL,1) 
					sonos.xferObjects.push(xfer)
				'else
				    'print "+++ device already muted - ignorning command"
					'postNextCommandInQueue(sonos, sonosDevice.baseURL)
				'end if
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
				    'print "+++ device not muted - ignorning command"
					'postNextCommandInQueue(sonos, sonosDevice.baseURL)
				'end if
			else if command="volume" then
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
				sonosDevice.volume = sonosDevice.volume + volincrease
				if (sonosDevice.volume > 100) then
					sonosDevice.volume = 100
				end if
				'TIMING print "Sending Volume Up "+str(volincrease)+ " to "+str(sonosDevice.volume);" at: ";sonos.st.GetLocalDateTime()
				xfer = SonosSetVolume(sonos.mp, sonosDevice.baseURL, sonosDevice.volume)
				sonos.xferObjects.push(xfer)
			else if command="voldown" then
				if detail="" then
					voldecrease = 1
				else
					voldecrease=abs(val(detail))
				end if
				sonosDevice.volume = sonosDevice.volume - voldecrease
				if (sonosDevice.volume < 0) then
					sonosDevice.volume = 0
				end if
				'TIMING print "Sending Volume Down "+str(voldecrease)+ " to "+str(sonosDevice.volume);" at: ";sonos.st.GetLocalDateTime()
				xfer = SonosSetVolume(sonos.mp, sonosDevice.baseURL, sonosDevice.volume)
				sonos.xferObjects.push(xfer)
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
			else if command="playmp3" then
				' print "Playing MP3"
				'TIMING print "Playing MP3 on "+sonosDevice.modelNumber" at: ";sonos.st.GetLocalDateTime()
				netConfig = CreateObject("roNetworkConfiguration", 0)
				currentNet = netConfig.GetCurrentConfig()
				xfer = SonosSetSong(sonos.mp, currentNet.ip4_address, sonosDevice.baseURL, detail)
				sonos.xferObjects.push(xfer)
			else if command="spdif" then
				' print "Swithching to SPDIF input"
				xfer = SonosSetSPDIF(sonos.mp, sonosDevice.baseURL, sonosDevice.UDN)
				sonos.xferObjects.push(xfer)
			else if command="group" then
				if (devType <> "sall") then 
					' print "Grouping players"
					MasterSonosDevice = invalid
					for each device in sonos.sonosDevices
						if device.modelNumber = detail
							MasterSonosDevice = device			
						endif
					end for
					
					groupValid=CheckGroupValid(sonosDevices, MasterSonosDevice)
					if groupValid=false then
                        print "grouping devices"					
						if MasterSonosDevice = invalid then
							print "No  master device of that type on this network"
						else
							xfer = SonosSetGroup(sonos.mp, sonosDevice.baseURL, MasterSonosDevice.UDN)
							sonos.xferObjects.push(xfer)						
						endif
					else
                        print "devices grouped - taking no action"
						postNextCommandInQueue(sonos, sonosDevice.baseURL)				
					end if
				else
					print "Grouping all devices"
					if (sonos.masterDevice <> "") then
						print "Number of device in playing group is: ";sonos.playingGroup.count()
						for i = 0 to sonos.playingGroup.count() - 1
							print "Comparing ";sonos.playingGroup[i];" to ";sonos.masterDevice
							if (sonos.playingGroup[i] <> sonos.masterDevice) then
								print "Sending plugin message:";"sonos!"+sonos.playingGroup[i]+"!group!"+sonos.masterDevice
								sendPluginMessage(sonos, "sonos!"+sonos.playingGroup[i]+"!group!"+sonos.masterDevice)
							end if
						end for
					end if
				end if
			else if command = "play" then
				xfer = SonosPlaySong(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "subon" then
				' print "Sub ON"
				xfer = SonosSubCtrl(sonos.mp, sonosDevice.baseURL,1)
				sonos.xferObjects.push(xfer)
			else if command = "suboff" then
				' print "Sub OFF"
				xfer = SonosSubCtrl(sonos.mp, sonosDevice.baseURL,0)
				sonos.xferObjects.push(xfer)
			else if command = "surroundon" then
				' print "Surround ON"
				xfer = SonosSurroundCtrl(sonos.mp, sonosDevice.baseURL,1)
				sonos.xferObjects.push(xfer)
			else if command = "surroundoff" then
				' print "Surround OFF"
				xfer = SonosSurroundCtrl(sonos.mp, sonosDevice.baseURL,0)
				sonos.xferObjects.push(xfer)
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
			else if command = "setrdmvalues" then
				print "Setting all of the RDM default values"
				xfer=SonosSetRDMDefaultsAsync(sonos.mp, sonosDevice.baseURL, sonos)
				sonos.postObjects.push(xfer)
				'SonosSetRDMDefaults(sonos.mp, sonosDevice.baseURL, sonos)
			else if command = "getrdm" then
				xfer = SonosGetRDM(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "wifi" then
				xfer = SonosSetWifi(sonos.mp, sonosDevice.baseURL, detail)
				sonos.xferObjects.push(xfer)
			else if command = "software_upgrade" then
				netConfig = CreateObject("roNetworkConfiguration", 0)
				currentNet = netConfig.GetCurrentConfig()
				xfer = SonosSoftwareUpdate(sonos.mp, sonosDevice.baseURL, currentNet.ip4_address, detail)
				sonos.xferObjects.push(xfer)
			else if command = "scan" then
				FindAllSonosDevices(sonos)
				sendSelfUDP("scancomplete")
			else if command = "list" then
				PrintAllSonosDevices(sonos)
			else if command = "checkforeign" then
			   ' this message allows a state to ask if foreign content is actually playing or not'
			   nr=CheckForeignPlayback(sonos)
			   if nr=true
			        print "+++ playing foreign content"
			        sendPluginEvent(sonos,"ForeignTransportStateURI")
			   else if nr=false
			        print "+++ playing local content"
        		    sendPluginEvent(sonos,"LocalTransportStateURI")
			   end if
			else if command = "reboot" then
			    xfer=SonosPlayerReboot(sonos.mp, sonosDevice.baseURL)
				sonos.xferObjects.push(xfer)
			else if command = "checkhhid" then
			    CheckPlayerHHIDs(sonos)
			    PrintAllSonosDevices(sonos)
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
			else if command = "desired" then
				if (detail = "yes") then
					print "Adding ";devType;" to list of desired devices"
					sonos.desiredDevices.push(devType)
				end if	
			else if command = "setmasterdevice" then
				sonos.masterDevice = devType
			else if command = "addplayertogroup" then
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
			end if
		else
			'TIMING print "Queueing command due to device being busy: ";msg;" at: ";sonos.st.GetLocalDateTime()
			commandToQ = {}
			commandToQ.IP = sonosDevice.baseURL
			commandToQ.msg = msg
			sonos.commandQ.push(commandToQ)	
			print "Queuing:";command +" " + devType + " " + detail + " " +sonosDevice.baseURL		
		end if
	else
		' See if it is a Brightsign message
		r = CreateObject("roRegex", "^brightsign", "i")
		match=r.IsMatch(msg)
		if (match) then
			retval = true

			r2 = CreateObject("roRegex", "!", "i")
			fields=r2.split(msg)
			numFields = fields.count()
			if (numFields < 3) or (numFields > 5) then
				print "************ Incorrect number of fields for BrightSign command:";msg
				' need to have a least 3 fields and not more than 4 fields to be valid
				return retval
			else if (numFields = 3) then
				' command with no details
				command =fields[1]
				field1 =fields[2]
				field2 = ""
				field3 = ""
			else if (numFields = 4) then
				' command with details
				command =fields[1]
				field1 =fields[2]
				field2 =fields[3]
				field3 =""
			else if (numFields = 5) then
				' command with details
				command =fields[1]
				field1 =fields[2]
				field2 =fields[3]
				field3 =fields[4]
			end if

			if command = "chpresent" then
				available = ChannelAvailable(sonos, field1, field2, field3)
				if available then 
					print "Channel: ";field2;" ";field1;" is available"
					sendSelfUDP("ATSC")
				else
					print "Channel: ";field2;" ";field1;" is NOT available"
					sendSelfUDP("noATSC")
				end if
			else if (command = "resolution") then
				vm=CreateObject("roVideoMode")
				print "Switching Resolution"
				vm.SetMode(field1+"-noreboot")
			end if
		end if
	end if

	return retval
end Function

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
	sonosReqData["type"]="SubCtrl"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	soapTransfer.SetUrl( connectedPlayerIP + "/wifictrl?wifi="+ setValue)

	print "Executing SonosSetWifi: ";connectedPlayerIP
	ok = soapTransfer.AsyncGetToString()
	if not ok then
		stop
	end if

	return (soapTransfer)
end Sub


Sub SonosSubCtrl(mp as object, connectedPlayerIP as string, enableVal as integer) as object
	
	' print "SonosSubCtrl"

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SubCtrl"
	sonosReqData["dest"]=connectedPlayerIP
	soapTransfer.SetUserData(sonosReqData)

	subXML="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)+"?>"
	subXML=subXML+"<s:Envelope s:encodingStyle="+chr(34)
	subXML=subXML+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	subXML=subXML+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"+chr(34)
	subXML=subXML+"><s:Body><u:SetEQ xmlns:u="+chr(34)
	subXML=subXML+"urn:schemas-upnp-org:service:RenderingControl:1"+chr(34)
	subXML=subXML+"><InstanceID>0</InstanceID>"
	subXML=subXML+"<EQType>SubEnable</EQType><DesiredValue>ENABLEVALUE</DesiredValue></u:SetEQ>"
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


Sub SonosSurroundCtrl(mp as object, connectedPlayerIP as string, enableVal as integer) as object
	
	' print "SonosSurroundCtrl"

	soapTransfer = CreateObject("roUrlTransfer")
	soapTransfer.SetMinimumTransferRate( 500, 1 )
	soapTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SubCtrl"
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
		print "not setting sleep timer since value is already 0"

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



Sub SonosSetPlayMode(sonos as object, sonosDevice as object) 

		connectedPlayerIP = sonosDevice.baseURL
	if (sonosDevice.CurrentPlayMode = "NORMAL") then
		' do nothing save time on the SOAP call

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


Sub SonosSetSong(mp as object, myIP as string, connectedPlayerIP as string, mp3file as string) as object

	'xmlString = readASCIIFile("setsong.xml")

	xmlString="<?xml version="+chr(34)+"1.0"+chr(34)+" encoding="+chr(34)+"utf-8"+chr(34)
	xmlString=xmlString+"?><s:Envelope s:encodingStyle="+chr(34)
	xmlString=xmlString+"http://schemas.xmlsoap.org/soap/encoding/"+chr(34)
	xmlString=xmlString+" xmlns:s="+chr(34)+"http://schemas.xmlsoap.org/soap/envelope/"
	xmlString=xmlString+chr(34)+"><s:Body><u:SetAVTransportURI xmlns:u="+chr(34)
	xmlString=xmlString+"urn:schemas-upnp-org:service:AVTransport:1"+chr(34)
	xmlString=xmlString+"><InstanceID>0</InstanceID><CurrentURI>http://BSPIP:111/MP3STRING"
	xmlString=xmlString+"</CurrentURI><CurrentURIMetaData /></u:SetAVTransportURI>"
	xmlString=xmlString+"</s:Body></s:Envelope>"

	r1 = CreateObject("roRegex", "BSPIP", "i")
	newString1 = r1.ReplaceAll(xmlString, myIP)
	r2 = CreateObject("roRegex", "MP3STRING", "i")
	reqString = r2.ReplaceAll(newString1, mp3file)

	songTransfer = CreateObject("roUrlTransfer")
	songTransfer.SetMinimumTransferRate( 2000, 1 )
	songTransfer.SetPort( mp )

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

Sub SonosSetSPDIF(mp as object, connectedPlayerIP as string, sonosPlayerUDN as string) as object

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

	songTransfer = CreateObject("roUrlTransfer")
	songTransfer.SetMinimumTransferRate( 2000, 1 )
	songTransfer.SetPort( mp )

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
			print "Message.getInt() = ";msg.getInt(); "reqData:";reqData;"  IP:"; connectedPlayerIP
			if (msg.getInt() = 1) then
''				print "HTTP return code: "; eventCode; " request type: ";reqData;" from ";connectedPlayerIP;" at: ";sonos.st.GetLocalDateTime()
				print "HTTP return code: "; eventCode; " request type: ";reqData;" from ";connectedPlayerIP;
				if (eventCode = 200) then 
					if reqData="GetVolume" then
						processSonosVolumeResponse(msg,connectedPlayerIP,sonos)
					else if reqData="SetVolume" then
						processSonosSetVolumeResponse(msg,connectedPlayerIP,sonos)
					else if reqData="GetRDM" then
						processSonosRDMResponse(msg,connectedPlayerIP,sonos)
					else if reqData="GetMute" then
						processSonosMuteResponse(msg,connectedPlayerIP,sonos)
				    else if reqData="RegisterForAVTransportEvent" then
					    OnGenaSubscribeResponse(sonosReqData,msg, sonos)
					else if reqData="RegisterForRenderingControlEvent" then
					    OnGenaSubscribeResponse(sonosReqData,msg, sonos)
				    else if reqData="RenewRegisterForAVTransportEvent" then
					    OnGenaRenewResponse(sonosReqData,msg, sonos)
					else if reqData="RenewRegisterForRenderingControlEvent" then
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

				' delete this transfer object from the transfer object list
				sonos.postObjects.Delete(i)
				found = true
			end if
		end if
		i = i + 1

    end while

	return found
end Function


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



Function ChannelAvailable(sonos as object, virtualChannel as string, modulation as string, rfChannel as string) as boolean
	print "Looking for Virtual Channel: ";virtualChannel;" with modulation type: ";modulation;" on RF Channel: ";rfChannel
	c = CreateObject("roChannelManager")

	channelAvail = false
	' See if there are any cached channels
	count = c.GetChannelCount()
	if (count > 0 ) then
		print "Tuner Channels found"
		cinfo  = CreateObject("roAssociativeArray")
		cinfo["VirtualChannel"] = virtualChannel
		desc = c.CreateChannelDescriptor(cinfo)
		if (desc <> invalid)
			ChannelAvail = true
			print "Channnel: ";virtualChannel;" found, descriptor ="
			print desc
			' Make sure the channel that was cached is really available now
			aa  = CreateObject("roAssociativeArray")
			aa["ChannelMap"] = desc["ChannelMap"]
			aa["FirstRfChannel"] = desc["RfChannel"]
			aa["LastRfChannel"] = desc["RfChannel"]
			' Clear the channel data
			c.ClearChannelData()
			print "Do scan to validate channel is really available now"
			c.Scan(aa)
			cinfo["VirtualChannel"] = virtualChannel
			desc = c.CreateChannelDescriptor(cinfo)
			if (desc <> invalid) then 
				print "Descriptor after confirmation scan"
				print desc
				ChannelAvail = true
			else
				' Do a complete scan to see if we can find the channel
				Print "Doing a complete scan, found cached channel but single scan did not find channel"
				ChannelAvail = FindChannelByScan(modulation, virtualChannel, rfChannel)
			end if
		else
			print "Channel: ";channel;" not in list, scan again..."
			ChannelAvail = FindChannelByScan(modulation, virtualChannel, rfChannel)
		end if
	else
		print "No channels available, run a scan..."
		ChannelAvail = 	FindChannelByScan(modulation, virtualChannel, rfChannel)
	end if

	if (channelAvail) then
		cinfo  = CreateObject("roAssociativeArray")
		cinfo["VirtualChannel"] = virtualChannel
		desc = c.CreateChannelDescriptor(cinfo)
		sonos.channelDesc = desc
	end if
		
	return (channelAvail)
end Function

Function FindChannelByScan(modulation as string, virtualChannel as string, rfChannel as string) as Boolean

	c = CreateObject("roChannelManager")
	aa  = CreateObject("roAssociativeArray")
	if (modulation <> "") then
		aa["ChannelMap"] = modulation
	end if
	if (rfChannel <> "") then
		rfChannelNum = int(val(rfChannel))
		print "RF Channel Number = "; rfChannelNum		
		aa["FirstRfChannel"] = rfChannelNum
		aa["LastRfChannel"] = rfChannelNum
	end if
	c.Scan(aa)
	cinfo  = CreateObject("roAssociativeArray")
	cinfo["VirtualChannel"] = virtualChannel
	desc = c.CreateChannelDescriptor(cinfo)
	if (desc <> invalid)
		ChannelAvail = true
		print "Channnel: ";virtualChannel;" found, descriptor ="
		print desc
	else
		print "Channnel: ";virtualChannel;" NOT found after scan.."
		ChannelAvail = false
	end if

	return ChannelAvail
end function

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
	s.server.AddGetFromFile({ url_path: "/misery.mp3", filename: "SD:/misery.mp3", content_type: "audio/mpeg" })
	s.server.AddGetFromFile({ url_path: "/warning.mp3", filename: "SD:/warning.mp3", content_type: "audio/mpeg" })

	'  add the files 
	filepathmp3 = GetPoolFilePath(s.bsp.syncpoolfiles, "1.mp3")
	s.server.AddGetFromFile({ url_path: "/1.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
	print "File path for 1.mp3 = ";filepathmp3
	filepathmp3 = GetPoolFilePath(s.bsp.syncpoolfiles, "2.mp3")
	s.server.AddGetFromFile({ url_path: "/2.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
	print "File path for 2.mp3 = ";filepathmp3
	filepathmp3 = GetPoolFilePath(s.bsp.syncpoolfiles, "3.mp3")
	s.server.AddGetFromFile({ url_path: "/3.mp3", filename: filepathmp3, content_type: "audio/mpeg" })
	print "File path for 3.mp3 = ";filepathmp3
	filepathmp3 = GetPoolFilePath(s.bsp.syncpoolfiles, "4.mp3")
	s.server.AddGetFromFile({ url_path: "/4.mp3", filename: filepathmp3, content_type: "audio/mpeg" })


'	files = MatchFiles(directory, "*.mp3")
'	print "File count in dir ";directory; files.Count()
'	for each fileName in files
'		transferObj = createObject("roURLTransfer")
'		escapedUrlPath = directory + "/" + transferObj.escape(fileName)
'		print "adding ";escapedUrlPath;" as available MP3 to server"
'		s.server.AddGetFromFile({ url_path: escapedUrlPath, filename: "SD:" + directory + "/" + fileName, content_type: "audio/mpeg" })	
'	end for
End Function

Function SonosRegisterForEvents(sonos as Object, mp as Object,device as Object) as Object
	' SUBSCRIBE to events - requires 4.5.18 or later '
	avtransport_event_handler = { name: "AVTransport", HandleEvent: OnAVTransportEvent, SonosDevice: device, sonos:sonos}
	renderingcontrol_event_handler = { name: "RenderingControl", HandleEvent: OnRenderingControlEvent, SonosDevice: device, sonos:sonos}

	sAVT="/gena/avtransport/"+device.UDN
	sRC ="/gena/renderingconrol/"+device.UDN

	if not sonos.server.AddMethodToString({ method: "NOTIFY", url_path: sAVT, user_data: avtransport_event_handler }) then
		print "FAILURE:  cannot register a local URL for Sonos avtransport notifications"
	end if

	if not sonos.server.AddMethodToString({ method: "NOTIFY", url_path: sRC , user_data: renderingcontrol_event_handler }) then
		print "FAILURE:  cannot register a local URL for Sonos rendering notifications"
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
			end if
		end if
	end for
End Sub

Function SonosRenewRegisterForEvents(sonos as Object)

	' Loop thru all of the devices and renew the register for events
	for each device in sonos.sonosDevices
		' Set up the Transfer Object AV Transport
		eventRegister = CreateObject("roUrlTransfer")
		eventRegister.SetMinimumTransferRate( 2000, 1 )
		eventRegister.SetPort( sonos.msgPort )

		' Set the URL for the AVTransport Events
		sURL=device.baseURL+"/MediaRenderer/AVTransport/Event"
		eventRegister.SetUrl(sURL)

		'  Add the headers for renewing, we only need 2, SID and Timeout
		' avTransportSID: "",renderingSID 
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

		' Set the URL for the AVTransport Events
		sURL2=device.baseURL+"/MediaRenderer/RenderingControl/Event"
		eventRegister2.SetUrl(sURL2)

		'  Add the headers for renewing, we only need 2, SID and Timeout
		' avTransportSID: "",renderingSID 
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
			if (reqType = "RegisterForAVTransportEvent") then
				s.sonosDevices[i].avTransportSID = SID
			else if (reqType = "RegisterForRenderingControlEvent") then
				s.sonosDevices[i].renderingSID = SID
			end if
		end if
	end for
End Sub

Sub OnAVTransportEvent(userdata as Object, e as Object)
	s = userData.sonos
    'print e.GetRequestHeaders()
    'print e.GetRequestBodyString()

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
	end if

	AVTransportURI = event.instanceid.AVTransportURI@val
	if (AVTransportURI <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "AVTransportURI", AVTransportURI)
  	    print "AVTransportURI: [";AVTransportURI;"] "
		nr=CheckForeignPlayback(s)
		if nr=true
		    sendPluginEvent(s,"ForeignTransportStateURI")
		end if
	end if

	CurrentPlayMode = event.instanceid.CurrentPlayMode@val
	if (CurrentPlayMode <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "CurrentPlayMode", CurrentPlayMode)
	end if

	SleepTimerGeneration = event.instanceid.rSleepTimerGeneration@val
	if (SleepTimerGeneration <> invalid) then 
		updateDeviceVariable(s, sonosDevice, "SleepTimerGeneration", SleepTimerGeneration)
	end if

	' Send a plugin message to indicate at least one of the transport state variables has changed
	sendPluginEvent(s, sonosDevice.modelNumber+"TransportState")
	if (sonosDevice.modelNumber = s.masterDevice) then
		sendPluginEvent(s, "masterDevice"+"TransportState")
	end if

	'PrintAllSonosDevicesState(userData.sonos)

    if not e.SendResponse(200) then
		stop
    end if
End Sub



Function CheckForeignPlayback(s as Object) as object
	' check if we're not playing something from our own IP
	master=GetDeviceByPlayerModel(s.sonosDevices, s.masterDevice)
	if master<>invalid
		AVTransportURI=master.AVTransportURI
		netConfig = CreateObject("roNetworkConfiguration", 0)
		currentNet = netConfig.GetCurrentConfig()
		myIP=currentNet.ip4_address
		ipFound = instr(1,AVTransportURI,myIP)
		if ipFound
		    print "************* playing local content  ********************"
		    return false	
		else
		    print "************* playing foreign content  ********************"
		    return true
		end if
	end if
	return invalid
end Function


Sub OnRenderingControlEvent(userdata as Object, e as Object)
	s = userData.sonos
    'TIMING print "Rendering Control Event at: ";s.st.GetLocalDateTime()
    'print e.GetRequestHeaders()

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
		if name="Volume"
			c=x@channel
			v=x@val
			if c="Master"
				updateDeviceVariable(s, sonosDevice, "Volume", v)
				'print "+++ Master volume changed (channel: ";c;")"
				changed = true
			else
				'print "+++ Other volume changed (channel: ";c;")"
			end if
		end if	
		if name="Mute"
			c=x@channel
			v=x@val
			if c="Master"
				updateDeviceVariable(s, sonosDevice, "Mute", v)
				'print "+++ Master muted (channel: ";c;")"
				changed = true
			else
				'print "+++ Other muted (channel: ";c;")"
			end if
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

    if not e.SendResponse(200) then
		stop
    end if
End Sub

Sub updateDeviceVariable(sonos as object, sonosDevice as object, variable as string, value as string)

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
	else if variable = "SleepTimerGeneration" then
		print "SleepTimerGeneration at (";sonosDevice.modelNumber;") {"+sonosDevice.UDN+"} is ["+value+"]"
		sonosDevice.SleepTimerGeneration = val(value)
		updateDeviceUserVariable(sonos, sonosDevice, variable, value)
	end if

end Sub

Sub updateDeviceUserVariable(sonos as object, sonosDevice as object, variable as string, value as string)
	' Update the uservariable for this device
	if (sonos.userVariables[sonosDevice.modelNumber+variable] <> invalid) then
		sonos.userVariables[sonosDevice.modelNumber+variable].currentValue$ = value
	end if	

	' Update the master device user variable if the model number matches the master device
	if (sonos.masterDevice = sonosDevice.modelNumber) then
		if (sonos.userVariables["masterDevice"+variable] <> invalid) then
			print "Setting masterDevice";variable" to: ";value
			sonos.userVariables["masterDevice"+variable].currentValue$ = value
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
	v.reboot=str(reboot)
	v.reboot=v.reboot.trim()
	b = postFormDataAsync(mp,connectedPlayerIP,sURL,v,"rdmHouseholdSetup")
	return b
end Function

Function rdmHouseholdSetup(connectedPlayerIP as string, hhid as string, name as string, icon as string, reboot as integer) as Object

	print "setting hhhid: ";hhid;" for ";connectedPlayerIP

	sURL=connectedPlayerIP+"/rdmhhsetup"
	v={}
	v.hhid=hhid
	v.name=name
	v.icon=icon
	v.reboot=str(reboot)
	v.reboot=v.reboot.trim()
	b = postFormData(sURL,v)
	if b<>true
		print "ERROR setting Household for "+connectedPlayerIP
	else
	    print "set hhid ";hhid;" on ";connectedPlayerIP
	end if

	return v
end Function


Function SonosSetRDMDefaultsAsync(mp as object, connectedPlayerIP as string, sonos as object) as object

	r={}
	' set all of the defaults that don't change
	r["enable"]="1"
	r["tosl"]= "1"
	r["cavt"] = "1"
	r["to"] = "0"
	r.["vol:ZP100"] = "10"
	r.["vol:ZP80"] = "10"
	r.["vol:ZP90"] = "10"
	r.["vol:ZP120"] = "10"
	r.["wto"] = "60"

	' Now set all of the RDM defaults that have user variables
	' rdmwifi = off means that we want to turn off the wifi radio on the device.  To do this we set the post value to 1
	if (sonos.userVariables["rdmwifi"] <> invalid) then
		if (sonos.userVariables["rdmwifi"].currentvalue$ = "off") then
			r["wifi"] = "1"
		else
			r["wifi"] = "0"
		end if
	else
		r["wifi"] = "1"
	end if
	
	' set the s5 default volume level
	if (sonos.userVariables["s5defaultvolume"] <> invalid) then
		r.["vol:S5"] = sonos.userVariables["s5defaultvolume"].currentvalue$
	else
		r.["vol:S5"]= "15"
	end if

	' set the s3 default volume level
	if (sonos.userVariables["s3defaultvolume"] <> invalid) then
		r.["vol:S3"] = sonos.userVariables["s3defaultvolume"].currentvalue$
	else
		r.["vol:S3"]="15"
	end if

	' set the s1 default volume level
	if (sonos.userVariables["s1defaultvolume"] <> invalid) then
		r.["vol:S1"] = sonos.userVariables["s1defaultvolume"].currentvalue$
	else
		r.["vol:S1"]="15"
	end if

	' set the s9 default volume level
	if (sonos.userVariables["s9defaultvolume"] <> invalid) then
		r.["vol:S9"] = sonos.userVariables["s9defaultvolume"].currentvalue$
	else
		r.["vol:S9"]="15"
	end if
	
	sURL = "/rdm"
	b = postFormDataAsync(mp,connectedPlayerIP,sURL,r,"SonosSetRDMDefaults")
	return b
end Function


Sub SonosSetRDMDefaults(mp as object, connectedPlayerIP as string, sonos as object) as object
	r={}
	' set all of the defaults that don't change
	r["enable"]="1"
	r["tosl"]= "1"
	r["cavt"] = "1"
	r["to"] = "0"
	r.["vol:ZP100"] = "10"
	r.["vol:ZP80"] = "10"
	r.["vol:ZP90"] = "10"
	r.["vol:ZP120"] = "10"
	r.["wto"] = "60"

	' Now set all of the RDM defaults that have user variables
	' rdmwifi = off means that we want to turn off the wifi radio on the device.  To do this we set the post value to 1
	if (sonos.userVariables["rdmwifi"] <> invalid) then
		if (sonos.userVariables["rdmwifi"].currentvalue$ = "off") then
			r["wifi"] = "1"
		else
			r["wifi"] = "0"
		end if
	else
		r["wifi"] = "1"
	end if
	
	' set the s5 default volume level
	if (sonos.userVariables["s5defaultvolume"] <> invalid) then
		r.["vol:S5"] = sonos.userVariables["s5defaultvolume"].currentvalue$
	else
		r.["vol:S5"]= "15"
	end if

	' set the s3 default volume level
	if (sonos.userVariables["s3defaultvolume"] <> invalid) then
		r.["vol:S3"] = sonos.userVariables["s3defaultvolume"].currentvalue$
	else
		r.["vol:S3"]="15"
	end if

	' set the s1 default volume level
	if (sonos.userVariables["s1defaultvolume"] <> invalid) then
		r.["vol:S1"] = sonos.userVariables["s1defaultvolume"].currentvalue$
	else
		r.["vol:S1"]="15"
	end if

	' set the s9 default volume level
	if (sonos.userVariables["s9defaultvolume"] <> invalid) then
		r.["vol:S9"] = sonos.userVariables["s9defaultvolume"].currentvalue$
	else
		r.["vol:S9"]="15"
	end if
	
	sURL = connectedPlayerIP + "/rdm"
	good = postFormData(sURL,r)
	if not good then
	    print "ERROR from POST to RDM"
''		stop
	end if

end sub	


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




Function postFormData(sURL as string, vars as Object) as Object
  if sURL=invalid
    return false
  endif 

  fTransfer = CreateObject("roUrlTransfer")
  fTransfer.SetUrl(sURL)

  postString=""
  for each v in vars
		''    print "*** "+v
    if postString<>""
      postString=postString+"&"
    endif
    postString=postString+fTransfer.escape(v)+"="+fTransfer.escape(vars[v])
	'print "postFormData - sURL: "+sURL+"?"+postString
  next

  print "POSTing "+postString+" to "+sURL

  ret=fTransfer.PostFromString(postString)
  print str(ret)
  if ret<>200
    print "ERROR performing POST"
    return false
  end if

  return true
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


Sub SonosSoftwareUpdate(mp as object, connectedPlayerIP as string, serverURL as string, version as string) as object

	print "SonosSoftwareUpdate: "+connectedPlayerIP+" * "+serverURL+" * "+version

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


Function processSonosSoftwareUpdateResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	print "processSonosSoftwareUpdateResponse from " + connectedPlayerIP
	print msg

End Function


Function AddAllSonosUpgradeImages(s as object, version as string)
	
	file18 = version + "-1-8.upd"
	filepath18 = GetPoolFilePath(s.bsp.syncpoolfiles, file18)
	ok = s.server.AddGetFromFile({ url_path: "/" + file18, filename: filepath18, content_type: "application/octet-stream" })
	if (not ok) then	
		print "Unable to add ";file18;" upgrade file to server"
	end if

	file19 = version + "-1-9.upd"
	filepath19 = GetPoolFilePath(s.bsp.syncpoolfiles, file19)
	ok = s.server.AddGetFromFile({ url_path: "/" + file19, filename: filepath19, content_type: "application/octet-stream" })
	if (not ok) then
		print "Unable to add ";file19;" upgrade file to server"
	end if

	file116 = version + "-1-16.upd"
	filepath116 = GetPoolFilePath(s.bsp.syncpoolfiles, file116)
	ok = s.server.AddGetFromFile({ url_path: "/" + file116, filename: filepath116, content_type: "application/octet-stream" })
	if (not ok) then
		print "Unable to add ";file116;" upgrade file to server"
	end if
	

'	ulist=findAttachedilesByExt(s.bsp,".upd") 
'	for each f in ulist
'	  p=directory+"/"+f.name
'	  l="SD:/"+f.link
'	  print "Exposing: ";p;" as local file: ";l
'	  s.server.AddGetFromFile({ url_path: "/update.upd", filename: filepathmp3, content_type: "application/octet-stream" })
'  	b=s.server.AddGetFromFile({ url_path: p, filename: l, content_type: "application/octet-stream" })
'	next

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

sub updateUserVar(uv as object, targetVar as string, newValue as string)
	if newValue=invalid
	    print "updateUserVar: new value for ";targetVar;" is invalid"
	    return
	end if
	if targetVar=invalid
	    print "updateUserVar: targetVar is invalid"
	    return
	end if

	if uv[targetVar] <> invalid then
		if uv[targetVar].currentValue$ <> invalid then
		  'print "updating "+targetVar+": "+newValue
		  uv[targetVar].currentValue$=newValue
		end if
	else
	    print "updateUserVar: error trying to set non-existant user variable ";targetVar
	end if
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


Function processSonosMutePauseControlResponse(msg as object, connectedPlayerIP as string, sonos as Object)

	print "processSonosMutePauseControlResponse from " + connectedPlayerIP
	print msg

End Function


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
		


