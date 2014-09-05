' Plug-in script for for BrightSign firmware 4.8 or greater
' This plug-in relies on low level BrightSign UPnP support
' Functionally equivalent to 3.18

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

	s.version = "4.00.08"

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
	s.upnp = invalid 
	s.bootseq ="" 'a number that is the number of times rebooted since some start point... factory reset?'

	' Create timer to renew register events, we will renew every hour at 15 mins past the hour
	s.timer=CreateObject("roTimer")  
	s.timer.SetPort(msgPort) 
	s.timer.SetDate(-1, -1, -1) 
	s.timer.SetTime(-1, 25, 0, 0) 
	s.timer.Start()

	s.st=CreateObject("roSystemTime")
	print "Sonos Plugin created at: ";s.st.GetLocalDateTime()

	' Reset some critical variables
	if (s.userVariables["aliveTimeoutSeconds"] <> invalid) then
		s.userVariables["aliveTimeoutSeconds"].Reset(False)
	end if
	if (s.userVariables["statusMessage"] <> invalid) then
		s.userVariables["statusMessage"].Reset(False)
	end if
	if (s.userVariables["statusMessage2"] <> invalid) then
		s.userVariables["statusMessage2"].Reset(False)
	end if

	' Create the http server for this app, use port 111 since 80 will be used by DWS
	s.server = CreateObject("roHttpServer", { port: 111 })
	if (s.server = invalid) then
		print "Unable to create server on port 111"
		'Need to reboot here - can't stop in the Init function
		RebootSystem()
	end if
	s.server.SetPort(msgPort)
	
	jsonFilePath$ = GetPoolFilePath(s.bsp.assetPoolFiles, "sonos_topology.json")
	jsonString$ = ReadAsciiFile(jsonFilePath$)
	s.sonosTopology = ParseJson(jsonString$)
	if s.sonosTopology = invalid then
		print "Sonos_Topology file is not a valid json file"
	end if
	
	' Create device setup/check timer
	s.timerDeviceCheck=CreateObject("roTimer")  
	s.timerDeviceCheck.SetPort(msgPort)
	s.accelerateAliveCheck = False
	
	' Create timer to check topology (only if SUB is present and we have a designated master)
	if getSubBondMaster(s) <> invalid then
		s.timerTopologyCheck = CreateObject("roTimer")
		s.timerTopologyCheck.SetPort(msgPort)
	end if

	' Create the array to hold the Sonos devices
	s.sonosDevices = CreateObject("roArray",1, True)

	' Create an array to hold RequestData objects for UPnP actions (Invokes or Subscribes)
	s.upnpActionObjects = createObject("roArray",0, true)

	' Create an array to hold roUrlTransferObject that are being used by the HTTP commands
	s.xferObjects = createObject("roArray",0, true)

	' Create an array to hold roUrlTransferObject from normal POSTs 
	s.postObjects = createObject("roArray",0, true)

	' Create an array to hold commands that have come in when the device is busy processing other commands
	s.commandQ = createObject("roArray",0, true)

	' Create the array to hold the deleted devices
	's.deletedDevices = CreateObject("roArray",1, True)

	' Variable for what is considered the master device
	s.masterDeviceUDN = ""
	s.masterDeviceLastTransportURI=""

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
	updateUserVar(s.userVariables,"siteHHID",s.hhid,false)

    setDebugPrintBehavior(s)

    print "***************************  Sonos plugin version ";s.version;" *************************** "
	updateUserVar(s.userVariables,"pluginVersion",s.version,false)

    print "***************************  Sonos config version ";s.configVersion;" *************************** "
	updateUserVar(s.userVariables,"configVersion",s.configVersion,false)
	
	' set up infoString variable with version numbers, if default value = "versions"
	if s.userVariables["infoString"] <> invalid and s.userVariables["infoString"].defaultValue$ = "versions" then
		info$ = s.version + " / " + s.configVersion
		updateUserVar(s.userVariables,"infoString",info$,false)
	end if

	' if topology file specifies a version, add upgrade files to the http server
	if s.sonosTopology.softwareVersion <> invalid then
		AddAllSonosUpgradeImages(s, s.sonosTopology.softwareVersion)
	end if

    ' make certain that we set the runningState to booting no matter what state we got left in'
    updateUserVar(s.userVariables,"runningState","booting",true)
	' start setup
	StartSetupCheck(s)

	return s
End Function

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
	else if type(event) = "roUPnPSearchEvent" then
		obj = event.GetObject()
		evType = event.GetType()
		if evType = 0 then
			if type(obj) = "roAssociativeArray" then
				CheckSSDPNotification(obj, m)
			else
				print "!!!!! Received roUPnPSearchEvent, type 0 - unexpected object: ";type(obj)
			end if
		else if evType = 1 then
			if type(obj) = "roAssociativeArray" then
				CheckUPnPDeviceStatus(obj, m)
			else
				print "!!!!! Received roUPnPSearchEvent, type 1 - unexpected object: ";type(obj)
			end if
		else if evType = 2 then
			if type(obj) = "roUPnPDevice" then
				' new device
				CheckNewUPnPDevice(obj, m)
			else
				print "!!!!! Received roUPnPSearchEvent, type 2 - unexpected object: ";type(obj)
			end if
		else if evType = 3 then
			if type(obj) = "roUPnPDevice" then
				' device was removed 
				CheckUPnPDeviceRemoved(obj, m)
			else
				print "!!!!! Received roUPnPSearchEvent, type 3 - unexpected object: ";type(obj)
			end if
		end if
		retval = true
	else if type(event) = "roUPnPActionResult" then
		HandleSonosUPnPActionResult(event, m)
	else if type(event) = "roUPnPServiceEvent" then
		retval = HandleSonosUPnPServiceEvent(event, m)
	else if type(event) = "roDatagramEvent" then
		' UDP "backdoor" for messages - not to be used in production
		msg$ = event
		if (left(msg$,5) = "sonos") then
			print "*********************************************  UDP EVENT - move to plug in message  ***************************************"
			print msg$
			print "***************************************************************************************************************************"
			retval = ParseSonosPluginMsg(msg$, m)
		end if
	else if (type(event) = "roUrlEvent") then
		' Handle responses from REST API calls
		'print "*****  Got roUrlEvent in Sonos"	
		retval = HandleSonosXferEvent(event, m)
	else if type(event) = "roTimerEvent" then
		if (event.GetSourceIdentity() = m.timer.GetIdentity()) then
			print "renewing for registering events"
			SonosRenewRegisterForEvents(m)
			retval = true
		else if (event.GetSourceIdentity() = m.timerDeviceCheck.GetIdentity()) then
			if m.SetupActive then
				DoSetupTimerCheck(m)
			else
				DoAliveCheck(m)
			end if
	        retval=true
		else if (m.timerTopologyCheck <> invalid) and (event.GetSourceIdentity() = m.timerTopologyCheck.GetIdentity()) then
			StartTopologyCheckTimer(m)
			' Handle setup for any devices that just came online
			DoNewDeviceSetupCheck(m)
			' Check bonding status
			CheckSonosTopology(m)
	        retval=true
		end if
	end if

	return retval

End Function

Function getSubBondMaster(s as Object) as String
	masterSpec = invalid
	if s.sonosTopology <> invalid then
		subDevice = s.sonosTopology.models["sub"]
		if subDevice <> invalid  and subDevice.bond = true then
			masterSpec = s.sonosTopology["master"]
		end if
	end if
	return masterSpec
End Function

'region Print/Log
Sub PrintAllSonosDevices(s as Object) 
    print "***************************  Sonos plugin version ";s.version;"***************************"
    print "-- siteHHID:        ";s.hhid
    print "-- master:          ";s.masterDeviceUDN
    print "__________________________________________________________________________________________"
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
	end for

End Sub

Sub PrintAllSonosDevicesState(s as Object) 
    print "-- master device:   ";s.masterDeviceUDN
	for each device in s.sonosDevices
		print "++ device model:    "+device.modelNumber
		print "++ transportState:  "+device.transportstate
		print "++ AVtransportURI:  "+device.AVTransportURI
		print "++ currentPlayMode: "+device.CurrentPlayMode
		print "+++++++++++++++++++++++++++++++++++++++++"
	end for
End Sub
'endregion

'region Discovery/Setup
Sub CreateUPnPController(s as Object) 
	if s.upnp = invalid then
		print "Creating roUPnPController"
		s.upnp = CreateObject("roUPnPController")
		's.upnp.SetDebug(true)
		if s.upnp = invalid then
			print "Failed to create upnp_controller"
			stop
		endif
		
		s.upnp.SetPort(s.msgPort)
	end if
End Sub

Sub FindAllSonosDevices(s as Object) 
	print "*** FindAllSonosDevices"

	CreateUPnPController(s)
	if not s.upnp.Search("upnp:rootdevice", 5) then
		print "Failed to initiate UPnP search for Sonos devices"
	end if
End Sub

Sub DoAliveCheck(s as Object)
	print "AliveCheck at ";s.st.GetLocalDateTime()
	StartAliveCheckTimer(s)
	for each device in s.sonosDevices
		if device.alive then
			' mark it as false - an alive should come by and mark it as true again'
			device.alive=false
		else
			count% = device.aliveCount% - 1
			' Remove the device if not found for several tries
			if count% = 0 then
				DeletePlayerByUDN(s,device.UDN,true)
				print "+++ alive timer expired - device [";device.modelNumber;" - ";device.UDN;"] not seen and is deleted"
			else
				device.aliveCount% = count%
			end if
		end if
	end for
	' Now re-scan
	FindAllSonosDevices(s)
End Sub

Sub CheckSSDPNotification(headers as Object, s as Object)
	'Ignore M-SEARCH events
	if headers.ssdpType <> invalid and lcase(headers.ssdpType.Left(8)) = "m-search" then
		return
	end if
	
	bootseq = ""
	sonosNotification = headers.DoesExist("X-RINCON-BOOTSEQ")
	if sonosNotification then
		bootseq = headers["X-RINCON-BOOTSEQ"]
	end if
	
	hhid = ""
	if headers.DoesExist("X-RINCON-HOUSEHOLD") then
		hhid = headers["X-RINCON-HOUSEHOLD"]
	end if
	
	UDN = ""
	if headers.DoesExist("USN") then
		UDN = GetUDNfromUSNHeader(headers.USN)
	end if
	
	aliveFound = headers.DoesExist("NTS") and headers.NTS = "ssdp:alive"
	rootDevice = headers.DoesExist("NT") and headers.NT = "upnp:rootdevice"
	if aliveFound and rootDevice then

		' No console output for non-Sonos devices
		if sonosNotification then
			headerBaseURL = ""
			if headers.DoesExist("location") then
				headerBaseURL = GetBaseURLFromLocation(headers.location)
			end if
			print "************ alive found ************ [";headerBaseURL;"]"
		end if

		sonosDevice = GetDeviceByUDN(s.sonosDevices, UDN)
		if (sonosDevice <> invalid) then
			print "Received ssdp:alive, device already in list "; sonosDevice.friendlyName ;" hhid: ";hhid;" old bootseq: "sonosDevice.bootseq;" new bootseq: ";bootseq;" version: ";sonosDevice.softwareVersion

			' if this device is in our list but is in factory reset we need to reboot'
			print "SonosDevice.hhid: ";sonosDevice.hhid
			if sonosDevice.hhid <> "" then
				if hhid = "" then
					print "device previously had hhid=";sonosDevice.hhid;" but now has no hhid - rebooting!"					
					RebootSystem()
				end if
			end if

			sonosDevice.alive=true
			xfer=rdmPingAsync(s.msgPort,sonosDevice,hhid) 
			s.postObjects.push(xfer)

			' if it's bootseq is different we need to punt and treat it as new
			if bootseq <> sonosDevice.bootseq then
				print "+++ bootseq incremented - removing device so that it will be re-initialized"
				' Force device removal - it will be re-initialized in the next scan
				s.upnp.RemoveDevice("uuid:" + UDN)
			else
				' Set the user variables
				updateUserVar(s.userVariables,SonosDevice.modelNumber,"present",false)
				updateUserVar(s.userVariables,SonosDevice.modelNumber+"Version",SonosDevice.softwareVersion,false)
			end if
		end if ' sonosDevice '
	end if ' aliveFound and rootDevice '
End Sub

Function isModelDesired(s as object, model as string, udn as string) as boolean
	if s.sonosTopology <> invalid  then
		modelTopology = s.sonosTopology.models[model]
		if modelTopology <> invalid and modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				' the device is desired if we already have it or if we have a slot for it
				if modelTopology.devices[i].UDN.Len() = 0 or modelTopology.devices[i].UDN = udn then
					return true
				end if
			end for
		end if
	end if
	return false
End Function

Function addModelToTopologyIfDesired(s as object, model as string, udn as string) as boolean
	if s.sonosTopology <> invalid  then
		modelTopology = s.sonosTopology.models[model]
		if modelTopology <> invalid and modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				' the device is desired if we already have it or if we have a slot for it
				if modelTopology.devices[i].UDN = udn then
					return true
				end if
			end for
			' if we don't have it already see if there is an empty slot
			for i = 0 to modelTopology.maxCount - 1
				if modelTopology.devices[i].UDN.Len() = 0 then
					print "!!!!! Adding device to topology: ";model;", UDN: ";udn
					modelTopology.devices[i].UDN = udn
					return true
				end if
			end for
		end if
	end if
	return false
End Function

Function isSonosDeviceActive(s as object, devSpec as string) as boolean
	if s.sonosTopology <> invalid  then
		model = GetModelParametersFromDevSpec(devSpec)
		modelTopology = s.sonosTopology.models[model.devType]
		if modelTopology <> invalid and modelTopology.maxCount > model.index then
			mtDevice = modelTopology.devices[model.index]
			if mtDevice.status = "ready" then
				return true
			end if
		end if
	end if
	return false
End Function

Function modelCount(s as object, model as string) as integer
	mCount = 0
	if s.sonosTopology <> invalid  then
		modelTopology = s.sonosTopology.models[model]
		if modelTopology <> invalid and modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				if modelTopology.devices[i].UDN.Len() > 0 then
					mCount = mCount + 1
				end if
			end for
		end if
	end if
	return mCount
End Function

Function DeletePlayerByUDN(s as object, udn as String, delUpnpDevice as Boolean) as boolean
	print "+++ DeletePlayerByUDN ";udn
	found = false
	i = 0

	numdevices = s.sonosDevices.count()
	while (not found) and (i < numdevices)  
		if (udn=s.sonosDevices[i].UDN) then
		  found = true
		  deviceNumToDelete = i
		end if
		i = i + 1
	end while
	if (found) then
	    modelBeingDeleted=s.sonosDevices[deviceNumToDelete].modelNumber
		print "!!! Deleting Player "+modelBeingDeleted+" with UDN: " + udn
		s.sonosDevices.delete(deviceNumToDelete)
		if delUpnpDevice then
			' Delete also from UPnP device list managed by UPnPController
			if not s.upnp.RemoveDevice("uuid:" + udn) then
				print "UPnPController.RemoveDevice failed to remove this device!"
			end if
		end if

		' Delete UDN from topology record
		modelTopology = s.sonosTopology.models[modelBeingDeleted]
		if modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				if modelTopology.devices[i].UDN = udn then
					modelTopology.devices[i].UDN = ""
					modelTopology.devices[i].status = ""
				end if
			end for
		end if
		
		' Indicate the player is no longer present
		if (s.userVariables[modelBeingDeleted] <> invalid) then
			s.userVariables[modelBeingDeleted].currentValue$ = "notpresent"
		end if
		print "current master is: ";s.masterDeviceUDN
		if udn=s.masterDeviceUDN then
			' pick a new master
 		    setSonosMasterDevice(s,"")
 		end if
	else
		print "- Matching UDN not in list: ";udn
	end if		
	return found
end function

Sub CheckNewUPnPDevice(upnpDevice as Object, s as Object)

	info = upnpDevice.GetDeviceInfo()
	deviceType = info.deviceType
	if (instr(1, deviceType, "urn:schemas-upnp-org:device:ZonePlayer:1")) then

		headers = upnpDevice.GetHeaders()
		baseURL = GetBaseURLFromLocation(headers.location)
		udn = GetUDNfromUSNHeader(headers.USN)
		model = GetPlayerModelByUDN(s.sonosDevices, udn)			
		model = lcase(model)
		print "Found new Sonos Device at baseURL ";baseURL

		if (model = "") then
			info = upnpDevice.GetDeviceInfo()
			model = lcase(info.modelNumber)
			
			desired = addModelToTopologyIfDesired(s,model,udn)
			sonosDevice = newSonosDevice(s,upnpDevice,desired)
			s.sonosDevices.push(sonosDevice)
			if desired=true then
				print "Sonos at ";baseURL;" is desired"

				' Set the user variables
				updateUserVar(s.userVariables,SonosDevice.modelNumber,"present",false)
				updateUserVar(s.userVariables,SonosDevice.modelNumber+"Version",SonosDevice.softwareVersion,false)
				updateUserVar(s.userVariables,SonosDevice.modelNumber+"HHID",SonosDevice.hhid,true)
				
				' Check f/w update and household setup
				' If in Setup phase, check for Setup complete
				DoNewDeviceSetupCheck(s)
				' If this device is now active (fully set up,) register for events
				if sonosDevice.IsActive(s) then
					SonosRegisterForEvents(s,sonosDevice)
				end if
			end if ' desired=true'
		else
			sonosDevice=GetDeviceByUDN(s.sonosDevices, udn)
			desired=isModelDesired(s,model,udn)
			updateSonosDevice(sonosDevice,upnpDevice,desired)
			if desired then
				des$="is desired"
			else
				des$="is NOT desired"
			end if
			print "Player ";model;" already exists in device list, ";des$

			' make sure the player is marked present'
			updateUserVar(s.userVariables,SonosDevice.modelNumber,"present",true)
		end if
	end if
End Sub

Sub CheckUPnPDeviceStatus(ssdpData as Object, s as Object)
	usn = ssdpData.USN
	if usn <> invalid then
		udn = GetUDNfromUSNHeader(usn)
		sonosDevice=GetDeviceByUDN(s.sonosDevices, udn)
		if sonosDevice <> invalid then
			print "Found existing Sonos Device at baseURL ";sonosDevice.baseURL;", UDN: ";udn
			' Mark device as alive
			sonosDevice.alive=true
			sonosDevice.aliveCount%=3
			hhid = sonosDevice.hhid
			UpdateSonosDeviceSSDPData(sonosDevice, ssdpData)
			if hhid <> sonosDevice.hhid then
				updateUserVar(s.userVariables,sonosDevice.modelNumber+"HHID",sonosDevice.hhid,true)
			end if
			if sonosDevice.desired then
				des$=" is desired"
			else
				des$=" is NOT desired"
			end if
			print "Player ";sonosDevice.modelNumber;des$
		end if
	end if
End Sub

Sub CheckUPnPDeviceRemoved(upnpDevice, s)
	print "+++ UPnP Device removed from control point"
	headers = upnpDevice.GetHeaders()
	udn = GetUDNfromUSNHeader(headers.USN)
	' No need to delete from UPnPController list - that has already happened
	DeletePlayerByUDN(s,udn,false)
End Sub

Function newSonosDevice(sonos as Object, upnpDevice as Object, isDesired as Boolean) as Object
	sonosDevice = { baseURL: "", deviceXML: invalid, modelNumber: "", modelDescription: "", UDN: "", deviceType: "", hhid: "none", uuid: "", softwareVersion: "", modelIndex: 0}
	
	headers = upnpDevice.GetHeaders()
	sonosDevice.uuid = mid(headers.USN,6)
	sonosDevice.UDN = GetUDNfromUSNHeader(headers.USN)
	
	updateSonosDevice(sonosDevice, upnpDevice, isDesired)
	
	if isDesired then
		sonosDevice.systemPropertiesService = upnpDevice.GetService("urn:schemas-upnp-org:service:SystemProperties:1")
		sonosDevice.systemPropertiesService.SetPort(sonos.msgPort)
		sonosDevice.devicePropertiesService = upnpDevice.GetService("urn:schemas-upnp-org:service:DeviceProperties:1")
		sonosDevice.devicePropertiesService.SetPort(sonos.msgPort)
		
		sonosDevice.alarmClockService = upnpDevice.GetService("urn:schemas-upnp-org:service:AlarmClock:1")
		sonosDevice.alarmClockService.SetPort(sonos.msgPort)
		
		sonosDevice.zoneGroupTopologyService = upnpDevice.GetService("urn:schemas-upnp-org:service:ZoneGroupTopology:1")
		sonosDevice.zoneGroupTopologyService.SetPort(sonos.msgPort)
		
		sonosDevice.rendererDevice = upnpDevice.GetEmbeddedDevice("urn:schemas-upnp-org:device:MediaRenderer:1")
		if sonosDevice.rendererDevice <> invalid then
			sonosDevice.renderingService = sonosDevice.rendererDevice.GetService("urn:schemas-upnp-org:service:RenderingControl:1")
			sonosDevice.renderingService.SetPort(sonos.msgPort)
			sonosDevice.avTransportService = sonosDevice.rendererDevice.GetService("urn:schemas-upnp-org:service:AVTransport:1")
			sonosDevice.avTransportService.SetPort(sonos.msgPort)
		end if
	end if
	
	sonosDevice.volume=-1
	sonosDevice.rdm=-1
	sonosDevice.mute=-1
	sonosDevice.transportState = "STOPPED"
	sonosDevice.CurrentPlayMode = "NORMAL"
	sonosDevice.AVTransportURI = "none"
	sonosDevice.foreignPlaybackURI = false
	sonosDevice.MuteCheckNeeded = false
	sonosDevice.SleepTimerGeneration = 0
	sonosDevice.AlarmListVersion = -1
	sonosDevice.AlarmCheckNeeded = "yes"
	
	sonosDevice.hhidSetupPending = false
	
	sonosDevice.GetDeviceSpec = sonosDevice_getDeviceSpec
	sonosDevice.MatchesDeviceSpec = sonosDevice_matchesDeviceSpec
	sonosDevice.IsActive = sonosDevice_isActive
	
	print "device HHID:       ["+SonosDevice.hhid+"]"
	print "device UDN:        ["+SonosDevice.UDN+"]"
	print "software Version:  ["+sonosDevice.softwareVersion+"]"
	print "boot sequence:     ["+sonosDevice.bootseq+"]"

	return sonosDevice
End Function

Function sonosDevice_getDeviceSpec() as string
	return m.modelNumber + ":" + StripLeadingSpaces(stri(m.modelIndex))
End Function

Function sonosDevice_matchesDeviceSpec(devSpec as string) as boolean
	specParams = GetModelParametersFromDevSpec(devSpec)
	if specParams.devType = m.modelNumber and specParams.index = m.modelIndex then
		return true
	end if
	return false
End Function

Function sonosDevice_isActive(s as Object) as boolean
	if s.sonosTopology <> invalid  then
		modelTopology = s.sonosTopology.models[m.modelNumber]
		if modelTopology <> invalid and modelTopology.maxCount > m.modelIndex then
			mtDevice = modelTopology.devices[m.modelIndex]
			if mtDevice.status = "ready" then
				return true
			end if
		end if
	end if
	return false
End Function

Sub updateSonosDevice(sonosDevice as Object, upnpDevice as Object, isDesired as Boolean)
	if sonosDevice <> invalid and upnpDevice <> invalid then
		sonosDevice.alive=true
		sonosDevice.aliveCount%=3
		sonosDevice.desired=isDesired
		
		headers = upnpDevice.GetHeaders()
		UpdateSonosDeviceSSDPData(sonosDevice, headers)
	
		info = upnpDevice.GetDeviceInfo()
		sonosDevice.modelNumber = lcase(info.modelNumber)
		sonosDevice.modelDescription = lcase(info.modelDescription)
		sonosDevice.deviceType = info.deviceType
		sonosDevice.softwareVersion=lcase(info.softwareVersion)
		
		' Friendly name is used for internal identification
		sonosDevice.friendlyName = "<"+sonosDevice.modelNumber+">"
	end if
End Sub

Sub UpdateSonosDeviceSSDPData(sonosDevice as Object, ssdpData as Object)
		sonosDevice.baseURL = GetBaseURLFromLocation(ssdpData.location)
		sonosDevice.hhid = ""
		if ssdpData.DoesExist("X-RINCON-HOUSEHOLD") then
			sonosDevice.hhid = ssdpData["X-RINCON-HOUSEHOLD"]
		end if
		sonosDevice.bootseq = ssdpData["X-RINCON-BOOTSEQ"]
End Sub

Function GetUDNfromUSNHeader(value as string) as String
	uuidString=""
	if value <> invalid and value.Left(5) = "uuid:" then 
		uuidEnd=instr(6,value,"::")
		uuidString=mid(value,6,uuidEnd-6)
	end if
	return uuidString
End Function

Function GetBaseURLFromLocation(location as string) as string
	baseURL = ""
	if location <> invalid then
		baseURL = left(location, instr(8, location, "/")-1)
	end if
	return baseURL
End Function

Function GetPlayerModelByUDN(sonosDevices as Object, udn as string) as string
	returnModel = ""
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].UDN = udn) then
			returnModel = sonosDevices[i].modelNumber
		end if
	end for
	return returnModel
End function

Function GetModelParametersFromDevSpec(devSpec as string) as object
	model = CreateObject("roAssociativeArray")
	colon = instr(1,devSpec,":")
	if colon > 0 then
		model["devType"] = devSpec.Left(colon-1)
		model["index"] = val(devSpec.Right(devSpec.Len()-colon))
	else
		model["devType"] = devSpec
		model["index"] = 0
	end if
	return model
End Function

Function GetDeviceByDevSpec(sonosDevices as object, devSpec as string) as object
	sonosDevice = invalid
	specParams = GetModelParametersFromDevSpec(devSpec)
	for each device in sonosDevices
		if device.modelNumber=specParams.devType and device.modelIndex=specParams.index then
			sonosDevice = device
			exit for				
		endif
	end for
	return sonosDevice
End Function

Function GetDeviceByUDN(sonosDevices as Object, udn as string) as object
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].UDN = udn) then
			device = sonosDevices[i]
		end if
	end for
	return device
End Function

Sub StartSetupCheck(s as Object)
	for each deviceModel in s.sonosTopology.models
		modelTopology = s.sonosTopology.models[deviceModel]
		if modelTopology.maxCount > 0 then
			modelTopology.devices = CreateObject("roArray", modelTopology.maxCount, false)
			for i = 0 to modelTopology.maxCount - 1
				modelTopology.devices[i] = { UDN: "", status: "", skipCount: 0 }
			end for
		end if
	end for
	StartSetupCheckTimer(s)
	SetStartupStatus(s)
	' Initial scan
	FindAllSonosDevices(s)
End Sub

Sub StartSetupCheckTimer(s as Object)
	s.setupActive = true
	' Start setup check timer
	timeout=s.st.GetLocalDateTime()
	timeout.AddSeconds(15)
	s.timerDeviceCheck.SetDateTime(timeout)
	s.timerDeviceCheck.Start()
End Sub

Sub StartAliveCheckTimer(s as object)
	s.setupActive = false
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
	s.timerDeviceCheck.SetDateTime(timeout)
	s.timerDeviceCheck.Start()
End Sub

Sub StartTopologyCheckTimer(s as object)
	if s.timerTopologyCheck <> invalid then
		timeout=s.st.GetLocalDateTime()
		timeout.AddSeconds(125)
		s.timerTopologyCheck.SetDateTime(timeout)
		s.timerTopologyCheck.Start()
	end if
End Sub

Sub DoNewDeviceSetupCheck(s as object)
	print "!! New Device Setup check"
	for each deviceModel in s.sonosTopology.models
		modelTopology = s.sonosTopology.models[deviceModel]
		if modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				mtDevice = modelTopology.devices[i]
				if mtDevice.UDN.Len() > 0 then
					device = GetDeviceByUDN(s.sonosDevices, modelTopology.devices[i].UDN)
					' This should not be invalid - check anyway
					if device <> invalid then
						mtDevice.skipCount = 0
						if device.softwareVersion <> s.sonosTopology.softwareVersion then
							if mtDevice.status <> "updating" then
								print "!!!!! Starting software update for ";deviceModel;", UDN: ";device.UDN
								mtDevice.status = "updating"
								netConfig = CreateObject("roNetworkConfiguration", 0)
								currentNet = netConfig.GetCurrentConfig()
								SonosSoftwareUpdate(s, device, currentNet.ip4_address, s.sonosTopology.softwareVersion)
							end if
						else if device.hhid <> s.hhid then
							if not device.hhidSetupPending then
								print "!!!!! Starting HHSetup for ";deviceModel;", UDN: ";device.UDN
								mtDevice.status = "hhsetup"
								xfer = rdmHouseholdSetupAsync(s.msgPort, device, s.hhid, modelTopology.roomName, "none", 1) 
								s.postObjects.push(xfer)
								device.hhidSetupPending = true
							end if
						else
						    print "!!!!! Device ";deviceModel;" is ready, UDN: ";device.UDN
							mtDevice.status = "ready"
							xfer = rdmPingAsync(s.msgPort, device, s.hhid) 
							s.postObjects.push(xfer)
						end if
					else
						mtDevice.UDN = ""
						mtDevice.status = ""
					end if
				end if
			end for
		end if
	end for
	if s.setupActive then
		CheckSetupComplete(s)
	end if
End Sub

Function CheckSetupComplete(s as object) as boolean
	allReady = true
	for each deviceModel in s.sonosTopology.models
		modelTopology = s.sonosTopology.models[deviceModel]
		if modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				mtDevice = modelTopology.devices[i]
				if mtDevice.status <> "ready" then
					if mtDevice.skipCount > 10 then
						if modelTopology.required then
							mtDevice.status = ""
							allReady = false
						else
							mtDevice.status = "skipped"
						end if
					else
						allReady = false
					end if
				end if
			end for
		end if
	end for
	if allReady then
		for each deviceModel in s.sonosTopology.models
			modelTopology = s.sonosTopology.models[deviceModel]
			if modelTopology.maxCount > 0 then
				for i = 0 to modelTopology.maxCount - 1
					mtDevice = modelTopology.devices[i]
					if mtDevice.status = "skipped" then
						print "Skipping desired device ";deviceModel;":";StripLeadingSpaces(stri(i))
					else
						sonosDevice = GetDeviceByUDN(s.sonosDevices, mtDevice.UDN)
						if sonosDevice <> invalid then
							sonosDevice.modelIndex = i
						end if
					end if
				end for
			end if
		end for
		
		if s.sonosTopology.master <> invalid then
			masterDevice = GetDeviceByDevSpec(s.sonosDevices, s.sonosTopology.master)
			if masterDevice <> invalid then
				setSonosMasterDevice(s, masterDevice.UDN)
			else
				print "Could not set master to ";s.sonosTopology.master;" as specified by topology file"
			endif
		end if
		updateUserVar(s.userVariables,"runningState","running",true)
		StartAliveCheckTimer(s)
		StartTopologyCheckTimer(s)
		print "!!!!!!!! Setup complete !!!!!!!"
		sendPluginEvent(s,"SonosSetupComplete")
	end if
	SetStartupStatus(s)
	return allReady
End Function

Sub DoSetupTimerCheck(s as object)
	print "!! Setup Timer check"
	' Check setup progress
	DoNewDeviceSetupCheck(s)
	' Increment skipCount for all devices not found yet
	for each deviceModel in s.sonosTopology.models
		modelTopology = s.sonosTopology.models[deviceModel]
		if modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				mtDevice = modelTopology.devices[i]
				if mtDevice.UDN.Len() = 0 then
					' model not found, bump skipCount
					mtDevice.skipCount = mtDevice.skipCount + 1
					print "!!! Skip count for device ";deviceModel;":";StripLeadingSpaces(stri(i));" is";stri(mtDevice.skipCount)
				end if
			end for
		end if
	end for
	' Restart setup timer if not complete
	if not CheckSetupComplete(s) then
		StartSetupCheckTimer(s)
		FindAllSonosDevices(s)
	end if
End Sub

Sub SetStartupStatus(s as object)
	searchList$ = ""
	foundList$ = ""
	skippedList$ = ""
	updateList$ = ""
	hhsteupList$ = ""
	comma$ = ", "
	ellipsis$ = "... "
	for each deviceModel in s.sonosTopology.models
		modelTopology = s.sonosTopology.models[deviceModel]
		if modelTopology.maxCount > 0 then
			for i = 0 to modelTopology.maxCount - 1
				mtDevice = modelTopology.devices[i]
				devSpec$ = GetDeviceSpecShort(deviceModel, i, s)
				if mtDevice.status = "" then
					searchList$ = CatListString(searchList$, devSpec$, comma$)
					if mtDevice.skipCount > 0 then
						searchList$ = searchList$ + " (" + StripLeadingSpaces(stri(mtDevice.skipCount)) + ")"
					end if
				else if mtDevice.status = "ready" then
					foundList$ = CatListString(foundList$, devSpec$, comma$)
				else if mtDevice.status = "skipped" then
					skippedList$ = CatListString(skippedList$, devSpec$, comma$)
				else if mtDevice.status = "updating" then
					updateList$ = CatListString(updateList$, devSpec$, comma$)
				else if mtDevice.status = "hhsetup" then
					hhsteupList$ = CatListString(hhsteupList$, devSpec$, comma$)
				end if
			end for
		end if
	end for
	
	status$ = ""
	if Len(foundList$) > 0 then
		tmp$ = "Found " + foundList$
		status$ = CatListString(status$, tmp$, ellipsis$)
	end if
	if Len(searchList$) > 0 then
		tmp$ = "Looking for " + searchList$
		status$ = CatListString(status$, tmp$, ellipsis$)
	end if
	if Len(skippedList$) > 0 then
		tmp$ = "Skipping " + skippedList$
		status$ = CatListString(status$, tmp$, ellipsis$)
	end if
	updateUserVar(s.userVariables, "statusMessage", status$, false)
	
	status$ = ""
	if Len(updateList$) > 0 then
		tmp$ = "Updating firmware for " + updateList$
		status$ = CatListString(status$, tmp$, ellipsis$)
	end if
	if Len(hhsteupList$) > 0 then
		tmp$ = "Setting HHID for " + hhsteupList$
		status$ = CatListString(status$, tmp$, ellipsis$)
	end if
	updateUserVar(s.userVariables, "statusMessage2", status$, true)
End Sub

Function CatListString(existing as string, new as string, conn as string) as string
	out = existing
	if Len(out) > 0 then
		out = out + conn
	end if
	out = out + new
	return out
End Function

Function GetDeviceSpecShort(model as string, index as integer, s as object) as string
	modelTopology = s.sonosTopology.models[model]
	if modelTopology.maxCount > 1 then
		return model + ":" + StripLeadingSpaces(stri(index))
	end if
	
	return model	
End Function

'endregion


Function ParseSonosPluginMsg(origMsg as string, sonos as object) as boolean
	'TIMING print "Received command - ParseSonosPluginMsg: " + origMsg;" at: ";sonos.st.GetLocalDateTime()
	retval = false
		
	' convert the message to all lower case for easier string matching later
	msg = lcase(origMsg)
	print "--- RECEIVED Plugin message: ";msg
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
			devSpec=fields[1]
			command=fields[2]
			detail = ""
		else if (numFields = 4) then
			' command with details
			devSpec=fields[1]
			command=fields[2]
			detail =fields[3]
		end if
		
		sonosDeviceName = ""
		sonosDeviceUDN = ""
		model = GetModelParametersFromDevSpec(devSpec)
		
		if (devSpec = "sall") then
			' Do not try to validate the device
			sonosDevice = invalid
		else
			' Get the sonosDevice for the device specified by the command
			sonosDevice = GetDeviceByDevSpec(sonos.sonosDevices, devSpec)			
			deviceActive = isSonosDeviceActive(sonos, devSpec)
			if (sonosDevice = invalid) or (not deviceActive) then
				print "There is no active device matching the device spec for the command"
				return retval
			endif
			
			sonosDeviceUDN = sonosDevice.UDN
			sonosDeviceName = sonosDevice.friendlyName		
		end if

		if isDeprecatedCommand(command) then
			print "Discarding DEPRECATED command :"; command
			if sonosDevice <> invalid then
				postNextCommandInQueue(sonos, sonosDeviceUDN)
			endif
			return retval
		end if

		' First, check internal management commands
		if command = "scan" then
			FindAllSonosDevices(sonos)
		else if command = "list" then
			PrintAllSonosDevices(sonos)
			LogAllSonosDevices(sonos)
		else if command = "addmp3" then
			AddMP3(sonos)
		else if command = "addupgradefiles" then
			AddAllSonosUpgradeImages(sonos, detail)
		else if command = "setmasterdevice" then
			setSonosMasterDevice(sonos, sonosDeviceUDN)
		else if command = "buttonstate" then
			setbuttonstate(sonos, detail)

		' if command is not a management command, check to see if device is busy
		' if the Sonos device is not already processing a command,
		'  and if this message would send another command, put it in the command queue
		else if (not SonosDeviceBusy(sonos, sonosDeviceUDN)) or (devSpec = "sall") then
			if sonosDeviceName.Len() > 0 then
				print "[[[ Executing:";command +" " + sonosDeviceName + " " + detail
			else
				print "[[[ Executing:";command +" " + devSpec + " " + detail
			end if
			' UPnP actions
			if command="mute" then
				print "Sending mute"
				SonosSetMute(sonos,sonosDevice,1) 
			else if command="unmute" then
				print "Sending unMute"
				SonosSetMute(sonos,sonosDevice,0) 
			else if command="volume" then
				CheckMute(sonos, sonosDevice)
				volume = val(detail)
				print "Setting volume on ";sonosDevice.modelNumber;" to ["volume;"]"
				if sonosDevice.volume<>volume then
					SonosSetVolume(sonos,sonosDevice, volume)
				else
					print "+++ volume already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command="getvol" then
				SonosGetVolume(sonos,sonosDevice)
			else if command="volup" then
				if detail="" then
					volincrease=1
				else
					volincrease=abs(val(detail))
				end if
				if (devSpec <> "sall") then
					CheckMute(sonos, sonosDevice)
					sonosDevice.volume = sonosDevice.volume + volincrease
					if (sonosDevice.volume > 100) then
						sonosDevice.volume = 100
					end if
					'TIMING print "Sending Volume Up "+str(volincrease)+ " to "+str(sonosDevice.volume);" at: ";sonos.st.GetLocalDateTime()
					SonosSetVolume(sonos, sonosDevice, sonosDevice.volume)
				else ' sall - increase volume on all devices
					sonosDevices=sonos.sonosDevices
					for each device in sonosDevices
						CheckMute(sonos, device)
						' queue volume command if device busy
						if device.IsActive(sonos) then
							if SonosDeviceBusy(sonos, device.UDN) then
								QueueSonosMessage(sonos, device.UDN, "sonos!" + device.modelNumber + "!volup!" + detail)
							else
								device.volume = device.volume + volincrease
								if (device.volume > 100) then
									device.volume = 100
								end if
								SonosSetVolume(sonos, device, device.volume)
							end if
						end if
					end for
				end if
			else if command="voldown" then
				if detail="" then
					voldecrease = 1
				else
					voldecrease=abs(val(detail))
				end if
				if (devSpec <> "sall") then
					CheckMute(sonos, sonosDevice)
					sonosDevice.volume = sonosDevice.volume - voldecrease
					if (sonosDevice.volume < 0) then
						sonosDevice.volume = 0
					end if
					'TIMING print "Sending Volume Down "+str(voldecrease)+ " to "+str(sonosDevice.volume);" at: ";sonos.st.GetLocalDateTime()
					SonosSetVolume(sonos, sonosDevice, sonosDevice.volume)
				else ' sall - increase volume on all devices
					sonosDevices=sonos.sonosDevices
					for each device in sonosDevices
						CheckMute(sonos, device)
						' queue volume command if device busy
						if device.IsActive(sonos) then
							if SonosDeviceBusy(sonos, device.UDN) then
								QueueSonosMessage(sonos, device.UDN, "sonos!" + device.modelNumber + "!voldown!" + detail)
							else
								device.volume = device.volume - voldecrease
								if (device.volume < 0) then
									device.volume = 0
								end if
								SonosSetVolume(sonos, device, device.volume)
							end if
						end if
					end for
				end if
			else if command="setplaymode" then
				SonosSetPlayMode(sonos, sonosDevice)
			else if command="resetbasiceq" then
				SonosResetBasicEQ(sonos, sonosDevice)
			else if command="getsleeptimer" then
				SonosGetSleepTimer(sonos, sonosDevice)
			else if command="setsleeptimer" then
				timeout=""
				SonosSetSleepTimer(sonos, sonosDevice, timeout)
			else if command="checkalarm" then
				if (devSpec <> "sall") then
					SonosCheckAlarm(sonos, sonosDevice)
				else
					sonosDevices=sonos.sonosDevices
					for each device in sonosDevices
						' queue checkAlarm command if device busy
						if device.IsActive(sonos) then
							if SonosDeviceBusy(sonos, device.UDN) then
								QueueSonosMessage(sonos, device.UDN, "sonos!" + device.modelNumber + "!checkalarm")
							else
								SonosCheckAlarm(sonos, device)
							end if
						end if
					end for
				end if
			else if command="playmp3" then
				' print "Playing MP3"
				'TIMING print "Playing MP3 on "+sonosDevice.modelNumber" at: ";sonos.st.GetLocalDateTime()
				netConfig = CreateObject("roNetworkConfiguration", 0)
				currentNet = netConfig.GetCurrentConfig()
				SonosSetSong(sonos, sonosDevice, currentNet.ip4_address, detail)
			else if command="spdif" then
				' print "Switching to SPDIF input"
				SonosSetSPDIF(sonos, sonosDevice)
			else if command="group" then
				if (devSpec <> "sall") then 
					' this groups a given device to the master we already know about'
					print "+++ grouping all players to master ";s.masterDeviceUDN
					if s.masterDeviceUDN.Len() > 0 then
						SonosSetGroup(sonos, sonosDevice, s.masterDeviceUDN)
					end if						
				else ' sall - we just group them'
					SonosGroupAll(sonos)
				end if
			else if command = "play" then
				SonosPlaySong(sonos, sonosDevice)
			else if command = "subbond" then
				' bond Sub to given device
				subDevice = GetDeviceByDevSpec(sonos.sonosDevices, "sub")
				if subDevice <> invalid and subDevice.IsActive(sonos) then
					SonosSubBond(sonos, sonosDevice, subDevice.UDN)
				end if
			else if command = "subunbond" then
				subDevice = GetDeviceByDevSpec(sonos.sonosDevices, "sub")
				if subDevice <> invalid then
					SonosSubUnBond(sonos, sonosDevice, subDevice.UDN)
				end if
			else if command = "setautoplayroom" then
				SonosSetAutoplayRoomUUID(sonos, sonosDevice)
			else if command = "checktopology" then
				CheckSonosTopology(sonos)
			else if command = "subon" then
				if sonosDevice.subEnabled = invalid or sonosDevice.subEnabled <> 1 then
					SonosEqCtrl(sonos, sonosDevice, "SubEnable", "1")
				else
				    print "+++ SUB already on - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "suboff" then
				if sonosDevice.subEnabled = invalid or sonosDevice.subEnabled <> 0 then
					SonosEqCtrl(sonos, sonosDevice, "SubEnable", "0")
				else
				    print "+++ SUB already off - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "subgain" then
				if sonosDevice.subGain = invalid or sonosDevice.subGain <> val(detail) then
					SonosEqCtrl(sonos, sonosDevice, "SubGain", detail)
				else
				    print "+++ SubGain already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "subcrossover" then
				if sonosDevice.subCrossover = invalid or sonosDevice.subCrossover <> val(detail) then
					SonosEqCtrl(sonos, sonosDevice, "SubCrossover", detail)
				else
				    print "+++ SubCrossover already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "subpolarity" then
				if sonosDevice.subPolarity = invalid or sonosDevice.subPolarity <> val(detail) then
					SonosEqCtrl(sonos, sonosDevice, "SubPolarity", detail)
				else
				    print "+++ SubPolarity already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "surroundon" then
				' print "Surround ON"
				SonosEqCtrl(sonos, sonosDevice, "SurroundEnable", "1")
			else if command = "surroundoff" then
				' print "Surround OFF"
				SonosEqCtrl(sonos, sonosDevice, "SurroundEnable", "0")
			else if command = "dialoglevel" then
				if sonosDevice.dialogLevel = invalid or sonosDevice.dialogLevel <> val(detail) then
					SonosEqCtrl(sonos, sonosDevice, "DialogLevel", detail)
				else
				    print "+++ DialogLevel already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "nightmode" then
				if sonosDevice.nightMode = invalid or sonosDevice.nightMode <> val(detail) then
					SonosEqCtrl(sonos, sonosDevice, "NightMode", detail)
				else
				    print "+++ NightMode already set correctly - ignoring command"
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				end if
			else if command = "mutebuttonbehavior" then
				SonosMutePauseControl(sonos, sonosDevice)
			else if command = "getmute" then
				' print "Getting Mute"
				SonosGetMute(sonos, sonosDevice)
			else if command = "rdmon" then
				SonosSetRDM(sonos, sonosDevice,1)
			else if command = "rdmoff" then
				SonosSetRDM(sonos, sonosDevice,0)
			else if command = "getrdm" then
				SonosGetRDM(sonos, sonosDevice)
			else if command = "software_upgrade" then
				netConfig = CreateObject("roNetworkConfiguration", 0)
				currentNet = netConfig.GetCurrentConfig()
				SonosSoftwareUpdate(sonos, sonosDevice, currentNet.ip4_address, detail)
			' Next commands are REST commands - these may require queuing
			else if command = "wifi" then
				xfer = SonosSetWifi(sonos.msgPort, sonosDevice, detail)
				sonos.xferObjects.push(xfer)
			else if command = "reboot" then
				xfer=SonosPlayerReboot(sonos.msgPort,sonosDevice)
				sonos.xferObjects.push(xfer)
			else if command = "rdmping" then
				xfer=rdmPingAsync(sonos.msgPort,sonosDevice,sonos.hhid) 
				sonos.postObjects.push(xfer)
			else if command = "sethhid" then
				varName=sonosDevice.modelNumber+"RoomName"
				if sonos.userVariables[varName] <> invalid then
					roomName=sonos.userVariables[varName].currentValue$
				else
					print "ERROR:  no room name defined for player ";sonosDevice.modelNumber
					roomName=sonosDevice.modelNumber
				end if
				xfer=rdmHouseholdSetupAsync(sonos.msgPort,sonosDevice,sonos.hhid,roomName,"none",1) 
				sonos.postObjects.push(xfer)
				print "hhsetup: ";type(xfer)
				' Device will reboot - no need to delete it until we get the bye-bye
				' If we put this back in, uncomment DeletePlayerByUDN
				'print "deleting sonos device: ";sonosDevice.modelNumber
				'DeletePlayerByUDN(sonos,sonosDeviceUDN,true)
			else
				print "Discarding UNSUPPORTED command :"; command
				if sonosDevice <> invalid then
					postNextCommandInQueue(sonos, sonosDeviceUDN)
				endif
			end if
		else
			'TIMING print "Queueing command due to device being busy: ";msg;" at: ";sonos.st.GetLocalDateTime()
			QueueSonosMessage(sonos, sonosDeviceUDN, msg)
			print "+++ Queuing:";command +" " + devSpec + " " + detail + " " +sonosDeviceUDN		

			for each c in sonos.commandQ
			    print "   +++ ";c.UDN;" - ";c.msg
			next
		end if
	end if

	return retval
End Function

Sub QueueSonosMessage(sonos as object, udn as string, msg as string)
	commandToQ = {}
	commandToQ.UDN = udn
	commandToQ.msg = msg
	sonos.commandQ.push(commandToQ)	
End Sub

Function isDeprecatedCommand(command as string) as boolean
	if command = "desired" or command = "addplayertogroup" or command = "rdmdefault" or command = "checkhhid" then
		return true
	end if
	return false
End Function

Function setSonosMasterDevice(sonos as object, udn as string) as string
	print "*********************************************** setSonosMasterDevice ";udn
	if udn=""
	    ' pick a random device'
	    for each device in sonos.sonosDevices
	        if device.IsActive(sonos) and device.modelNumber <> "sub" then
		        sonos.masterDeviceUDN = device.UDN
		        print "+++ setting master device to: ";device.modelNumber;", UDN: ";device.UDN
				updateUserVar(sonos.userVariables,"masterDevice",device.GetDeviceSpec(),true)
		        return sonos.masterDeviceUDN
	        end if 
	    end for
	else
		device = GetDeviceByUDN(sonos.sonosDevices, udn)
		if device <> invalid then
			sonos.masterDeviceUDN = udn
			print "+++ setting master device to: ";device.modelNumber;", UDN: ";sonos.masterDeviceUDN
			updateUserVar(sonos.userVariables,"masterDevice",device.GetDeviceSpec(),true)
			return sonos.masterDeviceUDN
		end if
	end if
	return invalid
End Function

Sub CheckSonosTopology(sonos as object)

	runningState="unknown"
	if sonos.userVariables["runningState"] <> invalid then
		runningState=sonos.userVariables["runningState"].currentValue$
	end if
	
	' Do nothing about bonding until the boot sequence is done
	if runningState="running" then
	
		bondMasterSpec$ = getSubBondMaster(sonos)
	
		subBondStatus$ = "none"
		if sonos.userVariables["subBondStatus"] <> invalid then
			subBondStatus$ = sonos.userVariables["subBondStatus"].currentValue$
		end if

		print "**** Checking Sonos Topology, master: ";bondMasterSpec$;", subBondStatus: ";subBondStatus$;", time: ";sonos.st.GetLocalDateTime()

		if bondMasterSpec$ <> invalid and subBondStatus$ <> "none" then
			bondMaster = GetDeviceByDevSpec(sonos.sonosDevices, bondMasterSpec$)
			if bondMaster <> invalid then
				subDevice = GetDeviceByDevSpec(sonos.sonosDevices, "sub")
				if subDevice <> invalid and subBondStatus$ = "Unbonded" then
					sonos.accelerateAliveCheck = False
					' Bond sub to bondMaster
					print "**** Bonding ";bondMasterSpec$;" to SUB"
					if SonosDeviceBusy(sonos, bondMaster.UDN) then
						QueueSonosMessage(sonos, bondMaster.UDN, "sonos|"+bondMasterSpec$+"|subbond")
						print "+++ Queuing: subbond ";bondMasterSpec$
					else
						SonosSubBond(sonos, bondMaster, subDevice.UDN)
					endif
				else if (subBondStatus$ = "Bonded/missing") or (subDevice = invalid and subBondStatus$.Left(6) = "Bonded") then
					sonos.accelerateAliveCheck = False
					if sonos.masterBondedToSubUDN <> invalid and sonos.masterBondedToSubUDN <> "none" then
						' Unbond sub from master
						print "**** SUB is missing - unbonding ";bondMasterSpec$;" from SUB"
						' Cannot queue this one because we may not know the right sub UDN
						'  later, if the SUB is missing
						SonosSubUnBond(sonos, bondMaster, sonos.masterBondedToSubUDN)
					else
						print "**** Need to unbond SUB, but we don't have sub UDN that was bonded"
					end if
				end if
			end if
		end if
	end if

End Sub

Sub CheckMute(sonos as object, sonosDevice as object)
	doCheck = getUserVariableValue(sonos, sonosDevice.modelNumber +"MuteCheck")
	if doCheck <> invalid and doCheck = "yes" and sonosDevice.muteCheckNeeded then
		msg = "sonos!" + sonosDevice.modelNumber + "!unmute"
		QueueSonosMessage(sonos, sonosDevice.UDN, msg)
		print "+++ Queuing:unmute ";sonosDevice.friendlyName
		sonosDevice.muteCheckNeeded = false		
	end if
End Sub


'region Sonos UPnP commands
Sub SonosGetVolume(sonos as object, sonosDevice as object)
	if sonosDevice.renderingService <> invalid then
		params = { InstanceID: "0", Channel: "Master" }
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="GetVolume"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.renderingService.Invoke("GetVolume", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub ProcessSonosVolumeResponse(sonos as Object, deviceUDN as string, responseData as Object)
	'TIMING print "processSonosVolumeResponse from " + deviceUDN + " at: ";sonos.st.GetLocalDateTime();
	volStr = responseData["CurrentVolume"]
	if volStr <> invalid then
		print "Current Volume: " + volStr
		sonosDevice=GetDeviceByUDN(sonos.sonosDevices,deviceUDN)
		if sonosDevice <> invalid then
			sonosDevice.volume=val(volStr)
		end if
	end if
End Sub

Sub SonosSetVolume(sonos as object, sonosDevice as object, volume as integer)
	if sonosDevice.renderingService <> invalid then
		params = { InstanceID: "0", Channel: "Master" }
		params.DesiredVolume = mid(stri(volume),2)
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetVolume"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.renderingService.Invoke("SetVolume", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosSetMute(sonos as object, sonosDevice as object, muteVal as integer)
	if sonosDevice.renderingService <> invalid then
		params = { InstanceID: "0", Channel: "Master" }
		if muteVal = 0 then
			params.DesiredMute = "0"
		else
			params.DesiredMute = "1"
		end if
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetMute"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.renderingService.Invoke("SetMute", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosGetMute(sonos as object, sonosDevice as object)
	if sonosDevice.renderingService <> invalid then
		params = { InstanceID: "0", Channel: "Master" }
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="GetMute"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.renderingService.Invoke("GetMute", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosMutePauseControl(sonos as object, sonosDevice as object)
	params = { VariableName: "R_ButtonMode", StringValue: "Mute" }
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="MutePauseControl"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.systemPropertiesService.Invoke("SetString", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub SonosSetRDM(sonos as object, sonosDevice as object, rdmVal as integer)
	params = { }
	if rdmVal = 0 then
		params.RDMValue = "0"
	else
		params.RDMValue = "1"
	end if
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetRDM"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.systemPropertiesService.Invoke("EnableRDM", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub SonosGetRDM(sonos as object, sonosDevice as object)
	params = { }
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="GetRDM"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.systemPropertiesService.Invoke("GetRDM", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub ProcessSonosRDMResponse(sonos as Object, deviceUDN as string, responseData as Object)
	'TIMING print "processSonosVolumeResponse from " + deviceUDN + " at: ";sonos.st.GetLocalDateTime();
	rdmStr = responseData["CurrentRDM"]
	if rdmStr <> invalid then
		sonosDevice=GetDeviceByUDN(sonos.sonosDevices,deviceUDN)
		if sonosDevice <> invalid then
			sonosDevice.rdm=val(rdmStr)
		end if
	end if
End Sub

Sub SonosSetAutoplayRoomUUID(sonos as object, sonosDevice as object)
	params = { }
	params.RoomUUID = sonosDevice.UDN
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SetAutoplayRoomUUID"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.devicePropertiesService.Invoke("SetAutoplayRoomUUID", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub SonosEqCtrl(sonos as object, sonosDevice as object, EqKey as string, EqVal as string)
	if sonosDevice.renderingService <> invalid then
		params = { InstanceID: "0" }
		params.EQType = EqKey
		params.DesiredValue = EqVal
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]=EqKey
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.renderingService.Invoke("SetEQ", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosResetBasicEq(sonos as object, sonosDevice as object)
	if sonosDevice.renderingService <> invalid then
		params = { InstanceID: "0" }
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="ResetBasicEQ"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.renderingService.Invoke("ResetBasicEQ", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosSubBond(sonos as object, sonosDevice as object, subUDN as string)
	chanMap = sonosDevice.UDN + ":LF,RF;" + subUDN + ":SW"
	params = { }
	params.HTSatChanMapSet = chanMap
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SubBond"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.devicePropertiesService.Invoke("AddHTSatellite", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub SonosSubUnbond(sonos as object, sonosDevice as object, subUDN as string)
	params = { }
	params.SatRoomUUID = subUDN
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="SubUnbond"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.devicePropertiesService.Invoke("RemoveHTSatellite", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub SonosSetSleepTimer(sonos as object, sonosDevice as object, timeout as string) 
	' don't do the call if setting timer to 0 and if sleep timer is already disabled
	if (sonosDevice.avTransportService <> invalid) and ((timeout.Len() > 0) or (sonosDevice.SleepTimerGeneration <> 0)) then
		params = { InstanceID: "0" }
		params.NewSleepTimerDuration = timeout
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetSleepTimer"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("ConfigureSleepTimer", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosGetSleepTimer(sonos as object, sonosDevice as object)
	if sonosDevice.avTransportService <> invalid then
		params = { InstanceID: "0" }
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="GetSleepTimer"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("GetRemainingSleepTimerDuration", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosCheckAlarm(sonos as object, sonosDevice as object)
	if sonosDevice.AlarmCheckNeeded = "yes" then
		params = { }
	
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="ListAlarms"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.alarmClockService.Invoke("ListAlarms", params)
		sonos.upnpActionObjects.push(sonosReqData)

		if sonos.masterDeviceUDN=sonosDevice.UDN then
			sonosDevices=sonos.sonosDevices
			for each device in sonosDevices
				device.AlarmCheckNeeded = "no"
			end for
		else
			sonosDevice.AlarmCheckNeeded = "no"
		end if
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
		print "Alarm Check not needed, device: " + sonosDevice.modelNumber
	end if
End Sub

Sub ProcessSonosAlarmCheck(sonos as Object, deviceUDN as string, responseData as Object)
	alStr = escapeDecode(responseData["CurrentAlarmList"])
	print "CurrentAlarmList: " + alStr
	sonosDevice=GetDeviceByUDN(sonos.sonosDevices, deviceUDN)
	if alStr <> invalid and sonosDevice <> invalid then
		xml=CreateObject("roXMLElement")
		xml.Parse(alStr)
		
		alarms = xml.GetNamedElements("Alarm")
		for each x in xml.GetChildElements()
			id = x@ID
			if id <> invalid then
				SonosDestroyAlarm(sonos, sonosDevice, id)
			end if
		end for
	end if
End Sub

Sub SonosDestroyAlarm(sonos as object, sonosDevice as object, alarmId as string)
	params = { }
	params.ID = alarmId
	
	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="DestroyAlarm"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.alarmClockService.Invoke("DestroyAlarm", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub

Sub SonosSetPlayMode(sonos as object, sonosDevice as object)
	' No call needed if mode is already "NORMAL"
	if sonosDevice.avTransportService <> invalid  and  sonosDevice.CurrentPlayMode <> "NORMAL" then
		params = { InstanceID: "0", NewPlayMode: "NORMAL" }
	
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetPlayMode"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("SetPlayMode", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosSetSong(sonos as object, sonosDevice as object, bspIP as string, mp3file as string)
	if sonosDevice.avTransportService <> invalid then
		songURI = "http://" + bspIP + ":111/" + mp3file
		params = { InstanceID: "0" }
		params.CurrentURI = songURI
		params.CurrentURIMetaData = ""
		
		sonos.masterDeviceLastTransportURI=songURI
		print "Setting master AVTransportURI to [";songURI;"]"
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetSong"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("SetAVTransportURI", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosSetSPDIF(sonos as object, sonosDevice as object)
	if sonosDevice.avTransportService <> invalid then
		spdifURI = "x-sonos-htastream:" + sonosDevice.UDN + ":spdif"
		params = { InstanceID: "0" }
		params.CurrentURI = spdifURI
		params.CurrentURIMetaData = ""
		
		sonos.masterDeviceLastTransportURI=spdifURI
		print "Setting master AVTransportURI to [";spdifURI;"]"
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetSPDIF"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("SetAVTransportURI", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosGroupAll(s as object) as object
	print "SonosGroupAll"
	printAllDeviceTransportURI(s)

	' if for some reason we don't have one set, we pick one at random
	if s.masterDeviceUDN="" then
	    setSonosMasterDevice(s,"")
	end if

	master=GetDeviceByUDN(s.sonosDevices, s.masterDeviceUDN)

	for each device in s.sonosDevices
	    if device.UDN <> master.UDN then
	        if device.IsActive(s) then
	            l = len(device.AVTransportURI)
	            colon = instr(1,device.AVTransportURI,":")
	            uri=right(device.AVTransportURI,l-colon)
	            print "+++ comparing device URI [";uri;"] to master URI [";master.UDN;"]"
	            if uri <> master.UDN then
	                print "+++ grouping device ";device.modelNumber;" with master ";master.modelNumber
					SonosSetGroup(s, device, master.UDN)
				else
				    print "+++ device ";device.modelNumber;" is already grouped with master ";master.modelNumber
				end if
			end if
	    end if
	end for
End Sub

Sub SonosSetGroup(sonos as object, sonosDevice as object, masterUDN as string)
	if sonosDevice.avTransportService <> invalid then
		UDNString = "x-rincon:" + masterUDN
		params = { InstanceID: "0" }
		params.CurrentURI = UDNString
		params.CurrentURIMetaData = ""
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="SetGroup"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("SetAVTransportURI", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosPlaySong(sonos as object, sonosDevice as object)
	if sonosDevice.avTransportService <> invalid then
		params = { InstanceID: "0", Speed:"1" }
		
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="PlaySong"
		sonosReqData["name"]=sonosDevice.friendlyName
		sonosReqData["dev"]=sonosDevice.UDN
		sonosReqData["id"]=sonosDevice.avTransportService.Invoke("Play", params)
		sonos.upnpActionObjects.push(sonosReqData)
	else
		postNextCommandInQueue(sonos, sonosDevice.UDN)
	end if
End Sub

Sub SonosSoftwareUpdate(sonos as object, sonosDevice as object, serverURL as string, version as string)
	print "SonosSoftwareUpdate: "+sonosDevice.friendlyName+" * "+serverURL+" * "+version

	' check if it's too old for us to use
	sv=val(sonosDevice.softwareVersion)
	print "player software is at version ";sv
	if sv<22
	    ' if it is factory reset we have to punt'
	    if sonosDevice.hhid=""
	        playerName=getPlayerNameByModel(SonosDevice.modelNumber)
		    msgString="Sonos device "+playerName+" requires an update or a Household ID - please fix and reboot"
		    print "+++ HALTING presentation - ";msgString
	    else
	        print "Sonos device "+sonosDevice.modelNumber+" is at version ";sonosDevice.softwareVersion;" but has an hhid, continuing..."
	    end if
	else
	    print "-- player software is recent enough for use in this presentation"
	end if
	
	updateURL = "http://" + serverURL + ":111/^" + version
	params = { }
	params.UpdateURL = updateURL

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="BeginSoftwareUpdate"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	sonosReqData["id"]=sonosDevice.zoneGroupTopologyService.Invoke("BeginSoftwareUpdate", params)
	sonos.upnpActionObjects.push(sonosReqData)
End Sub
'endregion


'region Sonos REST commands
Function rdmPingAsync(mp as object, sonosDevice as object, hhid as string) as Object
	print "rdmPingAsync: ";hhid;" for ";sonosDevice.friendlyName

	sURL="/rdmping"
	v={}
	v.hhid=hhid
	b = postFormDataAsync(mp,sonosDevice,sURL,v,"rdmPing")
	return b
End Function

Function rdmHouseholdSetupAsync(mp as object, sonosDevice as object, hhid as string, name as string, icon as string, reboot as integer) as Object
	print "setting hhid: ";hhid;" for ";sonosDevice.friendlyName

	sURL="/rdmhhsetup"
	v={}
	v.hhid=hhid
	v.name=name
	v.icon=icon
	v.wto="60"
	v.reboot=str(reboot)
	v.reboot=v.reboot.trim()
	b = postFormDataAsync(mp,sonosDevice,sURL,v,"rdmHouseholdSetup")
	return b
End Function

Function postFormDataAsync(mp as object, sonosDevice as object, sURL as string, vars as Object, reqType as object) as Object
	targetURL=sonosDevice.baseURL+sURL
    fTransfer = CreateObject("roUrlTransfer")
    fTransfer.SetUrl(targetURL)
    fTransfer.SetPort(mp)

    sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]=reqType
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	fTransfer.SetUserData(sonosReqData)

	postString=""
	for each v in vars
		'print "*** "+v
	    if postString<>""
			postString=postString+"&"
	    endif
	    postString=postString+fTransfer.escape(v)+"="+fTransfer.escape(vars[v])
	next

	print "[[[ POSTing "+postString+" to "+sURL

	ok = fTransfer.AsyncPostFromString(postString)
	if not ok then
		stop
	end if
	return fTransfer
End Function  

Function SonosSetWifi(mp as object, sonosDevice as object, setValue as string) as object
	cmdTransfer = CreateObject("roUrlTransfer")
	cmdTransfer.SetMinimumTransferRate( 500, 1 )
	cmdTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="WifiCtrl"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	cmdTransfer.SetUserData(sonosReqData)

	sURL=sonosDevice.baseURL+"/wifictrl?wifi="+setValue
	cmdTransfer.SetUrl(sURL)

	print "Executing SonosSetWifi: ";sURL
	ok = cmdTransfer.AsyncGetToString()
	if not ok then
		stop
	end if
	return cmdTransfer
end Function

Function SonosPlayerReboot(mp as object, sonosDevice as object) as object
	cmdTransfer = CreateObject("roUrlTransfer")
	cmdTransfer.SetMinimumTransferRate( 500, 1 )
	cmdTransfer.SetPort( mp )

	sonosReqData=CreateObject("roAssociativeArray")
	sonosReqData["type"]="reboot"
	sonosReqData["name"]=sonosDevice.friendlyName
	sonosReqData["dev"]=sonosDevice.UDN
	cmdTransfer.SetUserData(sonosReqData)

	name = sonosDevice.friendlyName
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name
	print "REBOOT ";name

	url=sonosDevice.baseURL+"/reboot"
	cmdTransfer.SetUrl(url)

	ok = cmdTransfer.AsyncGetToString()
	if not ok then
		stop
	end if
	return cmdTransfer
End Function
'endregion

'region Transfer/Invoke queuing
Function HandleSonosUPnPActionResult(msg as object, sonos as object) as boolean
	' Handle roUPnPActionResult
	actionID = msg.GetID()
	success = msg.GetResult()
	responseData = msg.GetValues()

	found = false
	numActions = sonos.upnpActionObjects.count()
	i = 0
	while (not found) and (i < numActions)
		sonosReqData=sonos.upnpActionObjects[i]
		id=sonosReqData["id"]
		if (actionID = id) then
			deviceName=sonosReqData["name"]
			deviceUDN=sonosReqData["dev"]
			reqType=sonosReqData["type"]
			print "]]] UPnP return code: "; success; ", request type: ";reqType;", from ";deviceName
			if success and responseData <> invalid then
				if reqType="GetVolume" then
					ProcessSonosVolumeResponse(sonos,deviceUDN,responseData)
				else if reqType="GetRDM" then
					ProcessSonosRDMResponse(sonos,deviceUDN,responseData)
				' else if reqType="GetMute" then
					' processSonosMuteResponse(sonos,deviceUDN,responseData)
				else if reqType="ListAlarms" then
					ProcessSonosAlarmCheck(sonos,deviceUDN,responseData)
				end if
			end if

			' delete this transfer object from the transfer object list
			sonos.upnpActionObjects.Delete(i)
					
			' See if we have a command in the command queue for this player, if so execute it
			postNextCommandInQueue(sonos, deviceUDN)
			found = true
		end if
		i = i + 1
	end while
End Function

Function HandleSonosXferEvent(msg as object, sonos as object) as boolean
	' Handle roURLTransferEvent
	eventID = msg.GetSourceIdentity()
	eventCode = msg.GetResponseCode()

	found = false
	numXfers = sonos.xferObjects.count()
	i = 0
	while (not found) and (i < numXfers)
		id = sonos.xferObjects[i].GetIdentity()
		sonosReqData=sonos.xferObjects[i].GetUserData()
		' See if this is the transfer being completed
		if (id = eventID) and (msg.getInt() = 1) then
			if (sonosReqData <> invalid) then 
				deviceName=sonosReqData["name"]
				deviceUDN=sonosReqData["dev"]
				reqData=sonosReqData["type"]
			else
				deviceName = ""
				deviceUDN = ""
				reqData = ""
			end if

''			print "HTTP return code: "; eventCode; " request type: ";reqData;" from ";deviceName;" at: ";sonos.st.GetLocalDateTime()
			print "]]] HTTP return code: "; eventCode; ", request type: ";reqData;", from ";deviceName

			' delete this transfer object from the transfer object list
			sonos.xferObjects.Delete(i)
				
			' See if we have a command in the command queue for this player, if so execute it
			postNextCommandInQueue(sonos, deviceUDN)
			found = true
		end if
		i = i + 1
	end while

	' now read from the POST queue'
	numPosts = sonos.postObjects.count()
	i = 0
	while (not found) and (i < numPosts)
		id = sonos.postObjects[i].GetIdentity()
		sonosReqData=sonos.postObjects[i].GetUserData()
		' See if this is the transfer being completed
		if (id = eventID) and (msg.getInt() = 1) then
			if (sonosReqData <> invalid) then 
				deviceName=sonosReqData["name"]
				deviceUDN=sonosReqData["dev"]
				reqData=sonosReqData["type"]
			else
				deviceName = ""
				deviceUDN = ""
				reqData = ""
			end if

			print "]]] HTTP return code: "; eventCode; ", request type: ";reqData;", from ";deviceName
			if (eventCode = 200) then 
				if reqData="rdmPing" then
					print "+++ got reply for rdmPing"
				end if
			else if reqData="rdmHouseholdSetup" then
				' if hhidSetup fails, reset pending flag so command will be re-sent
				device = GetDeviceByUDN(sonos.sonosDevices, deviceUDN)
				if device <> invalid then
					device.hhidSetupPending = false
				end if
			end if		

			' delete this transfer object from the transfer object list
			sonos.postObjects.Delete(i)

			' Check for a queued up message, and execute it if the device isn't busy
			postNextCommandInQueue(sonos, deviceUDN)
			found = true
		end if
		i = i + 1
    end while

	return found
End Function

Sub postNextCommandInQueue(sonos as object, deviceUDN as string)
	if Len(deviceUDN) > 0 then	
		' See how many commands we have the queue
		numCmds = sonos.commandQ.count()
		cmdFound = false
		x = 0
		if (numCmds > 0) then 
'TIMING'		print "+++ There are ";numCmds;" in the queue at ";sonos.st.GetLocalDateTime()
			print "+++ There are";numCmds;" commands in the queue"
		end if
		
		' If by any chance, there is another active command, don't post the next in queue
		' This can happen in rare instances
		if not SonosDeviceBusy(sonos, deviceUDN) then
			' loop thru all of the commands to see if we can find one that matches this player UDN
			while (not cmdFound) and (x < numCmds)
				' if a command is found that matches this UDN, post that command
				if (sonos.commandQ[x].UDN = deviceUDN) then
					print "+++ Sending queued msg: ";sonos.commandQ[x].msg
					' send plugin message to ourself to execute the next queued command 
					sendPluginMessage(sonos, sonos.commandQ[x].msg)
					
					' delete this command from the command queue
					sonos.commandQ.Delete(x)
					cmdFound = true
				end if
				x = x + 1
			end while
		else if (numCmds > 0) then
			print "+++ Device is still busy, not posting next queued command"
		end if
	end if
End Sub

Function SonosDeviceBusy(sonos as object, deviceUDN as String) as Boolean
	found = false
	if (deviceUDN <> "") then 
		' check both action and transfer queue
		numActions = sonos.upnpActionObjects.count()
		i = 0
		while (not found) and (i < numActions)
			sonosReqData=sonos.upnpActionObjects[i]
			if sonosReqData <> invalid
				connectedPlayerUDN=sonosReqData["dev"]
				if connectedPlayerUDN = deviceUDN
					found = true
				end if
			end if
			i = i + 1
		end while
		
		numXfers = sonos.xferObjects.count()
		i = 0
		while (not found) and (i < numXfers)
			sonosReqData=sonos.xferObjects[i].GetUserData()
			if sonosReqData <> invalid
				connectedPlayerUDN=sonosReqData["dev"]
				if connectedPlayerUDN = deviceUDN
					found = true
				end if
			end if
			i = i + 1
		end while
	end if
	
	' if we found the device in the list it means the device is busy processing a request	
	return found
End Function
'endregion


'region Sonos Event processing
Sub SonosRegisterForEvents(sonos as Object, device as Object)
	if device.desired = true then
		if device.avTransportService <> invalid then
			avtransport_event_handler = { name: "AVTransport", HandleEvent: OnAVTransportEvent, SonosDevice: device, sonos:sonos }
			device.avTransportService.SetUserData(avtransport_event_handler)

			print "[[[ Subscribing to AVTransport service for device ";device.modelNumber
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RegisterForAVTransportEvent"
			sonosReqData["name"]=device.friendlyName
			sonosReqData["dev"]=device.UDN
			sonosReqData["id"]=device.avTransportService.Subscribe()
			sonos.upnpActionObjects.push(sonosReqData)
		end if
		
		if device.renderingService <> invalid then
			renderingcontrol_event_handler = { name: "RenderingControl", HandleEvent: OnRenderingControlEvent, SonosDevice: device, sonos:sonos }
			device.renderingService.SetUserData(renderingcontrol_event_handler)

			print "[[[ Subscribing to RenderingControl service for device ";device.modelNumber
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RegisterForRenderingControlEvent"
			sonosReqData["name"]=device.friendlyName
			sonosReqData["dev"]=device.UDN
			sonosReqData["id"]=device.renderingService.Subscribe()
			sonos.upnpActionObjects.push(sonosReqData)
		end if
	
		alarmclock_event_handler = { name: "AlarmClock", HandleEvent: OnAlarmClockEvent, SonosDevice: device, sonos:sonos }
		device.alarmClockService.SetUserData(alarmclock_event_handler)

		print "[[[ Subscribing to AlarmClock service for device ";device.modelNumber
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="RegisterForAlarmClockEvent"
		sonosReqData["name"]=device.friendlyName
		sonosReqData["dev"]=device.UDN
		sonosReqData["id"]=device.alarmClockService.Subscribe()
		sonos.upnpActionObjects.push(sonosReqData)
		
		zoneGroupTopology_event_handler = { name: "ZoneGroupTopology", HandleEvent: OnZoneGroupTopologyEvent, SonosDevice: device, sonos:sonos }
		device.zoneGroupTopologyService.SetUserData(zoneGroupTopology_event_handler)

		print "[[[ Subscribing to ZoneGroupTopology service for device ";device.modelNumber
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="RegisterForZoneGroupTopologyEvent"
		sonosReqData["name"]=device.friendlyName
		sonosReqData["dev"]=device.UDN
		sonosReqData["id"]=device.zoneGroupTopologyService.Subscribe()
		sonos.upnpActionObjects.push(sonosReqData)
	end if
End Sub

Sub SonosRenewRegisterForEvents(sonos as Object)
	' Loop thru all of the devices and renew the event subscriptions
	for each device in sonos.sonosDevices
	    if device.desired=true then
			if device.avTransportService <> invalid then
				print "[[[ Renewing subscription to AVTransport service for device ";device.modelNumber
				sonosReqData=CreateObject("roAssociativeArray")
				sonosReqData["type"]="RenewRegisterForAVTransportEvent"
				sonosReqData["name"]=device.friendlyName
				sonosReqData["dev"]=device.UDN
				sonosReqData["id"]=device.avTransportService.RenewSubscription()
				sonos.upnpActionObjects.push(sonosReqData)
			end if
			
			if device.renderingService <> invalid then
				print "[[[ Renewing subscription to RenderingControl service for device ";device.modelNumber
				sonosReqData=CreateObject("roAssociativeArray")
				sonosReqData["type"]="RenewRegisterForRenderingControlEvent"
				sonosReqData["name"]=device.friendlyName
				sonosReqData["dev"]=device.UDN
				sonosReqData["id"]=device.renderingService.RenewSubscription()
				sonos.upnpActionObjects.push(sonosReqData)
			end if
			
			print "[[[ Renewing subscription to AlarmClock service for device ";device.modelNumber
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RenewRegisterForAlarmClockEvent"
			sonosReqData["name"]=device.friendlyName
			sonosReqData["dev"]=device.UDN
			sonosReqData["id"]=device.alarmClockService.RenewSubscription()
			sonos.upnpActionObjects.push(sonosReqData)
			
			print "[[[ Renewing subscription to ZoneGroupTopology service for device ";device.modelNumber
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RenewRegisterForZoneGroupTopologyEvent"
			sonosReqData["name"]=device.friendlyName
			sonosReqData["dev"]=device.UDN
			sonosReqData["id"]=device.zoneGroupTopologyService.RenewSubscription()
			sonos.upnpActionObjects.push(sonosReqData)
		end if
	end for
End Sub

Function HandleSonosUPnPServiceEvent(msg as object, sonos as object) as Boolean
	userData = msg.GetUserData()
	if type(userData.HandleEvent) = "roFunction" and userData.sonos <> invalid and userData.SonosDevice <> invalid then
		userData.HandleEvent(userData.sonos, userData.SonosDevice, msg)
		return true
	end if
	return false
End Function

Sub OnAVTransportEvent(s as object, sonosDevice as object, e as object)
	if e.GetVariable() = "LastChange" then
		eventString = e.GetValue()
		
		r = CreateObject("roRegex", "r:SleepTimerGeneration", "i")
		fixedEventString=r.ReplaceAll(eventString,"rSleepTimerGeneration")

		event = CreateObject("roXMLElement")
		event.parse(fixedEventString)

		transportState = event.instanceid.transportstate@val
		if (transportState <> invalid) then 
			print "~~~ Transport event from ";sonosDevice.modelNumber;" TransportState: [";transportstate;"] "
			updateDeviceVariable(s, sonosDevice, "TransportState", transportState)
		end if

		AVTransportURI = event.instanceid.AVTransportURI@val
		if (AVTransportURI <> invalid) then 
			print "~~~ Transport event from ";sonosDevice.modelNumber;" AVTransportURI: [";AVTransportURI;"] "
			updateDeviceVariable(s, sonosDevice, "AVTransportURI", AVTransportURI)
			sonosDevice.foreignPlaybackURI = CheckForeignPlayback(s,sonosDevice,AVTransportURI)
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
			print "~~~ Transport event from ";sonosDevice.modelNumber;" CurrentPlayMode: [";currentPlayMode;"] "
			updateDeviceVariable(s, sonosDevice, "CurrentPlayMode", CurrentPlayMode)
		end if

		SleepTimerGeneration = event.instanceid.rSleepTimerGeneration@val
		if (SleepTimerGeneration <> invalid) then 
			print "~~~ Transport event from ";sonosDevice.modelNumber;" SleepTimerGeneration: [";SleepTimerGeneration;"] "
			updateDeviceVariable(s, sonosDevice, "SleepTimerGeneration", SleepTimerGeneration)
		end if

		' Send a plugin message to indicate at least one of the transport state variables has changed
		sendPluginEvent(s, sonosDevice.modelNumber+"TransportState")
		if (sonosDevice.UDN = s.masterDeviceUDN) then
			sendPluginEvent(s, "masterDevice"+"TransportState")
		end if

		'PrintAllSonosDevicesState(userData.sonos)
		diagId = "Sonos AVTransport event"
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " transportState: " + sonosDevice.transportstate + ", playMode: " + sonosDevice.CurrentPlayMode + ", sleepTimer: " + str(sonosDevice.SleepTimerGeneration))
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " transport URI: " + sonosDevice.AVTransportURI)
	end if
End Sub

Function CheckForeignPlayback(s as Object, sonosDevice as object, AVTransportURI as String) as object
	print "CheckForeignPlayback - device: ";sonosDevice.modelNumber;" - ";AVTransportURI

    if not sonosDevice.IsActive(s) then
        print "+++ got unexpected messages from ";sonosDevice.modelNumber;" which is NOT active"
        return false
    end if

	if s.masterDeviceUDN="" then
	    print "+++ master device is not yet set"
	    return false
	end if
	master=GetDeviceByUDN(s.sonosDevices, s.masterDeviceUDN)
	if (master=invalid) then
	    print "+++ unable to find device for master";s.masterDeviceUDN
	    return false
	end if

	' if it's the master, check if it's the URI we set it to
    if sonosDevice.UDN=s.masterDeviceUDN then
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
End Function

Sub OnRenderingControlEvent(s as object, sonosDevice as object, e as object)
	if e.GetVariable() = "LastChange" then
		eventString = e.GetValue()
		
		r=CreateObject("roXMLElement")
		r.Parse(eventString)

		changed = false
		vals=r.InstanceID
		for each x in vals.GetChildElements()
			name=x.GetName()
		'	print "|"+name"|"	
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
			if (sonosDevice.UDN = s.masterDeviceUDN) then
				sendPluginEvent(s, "masterDevice"+"RenderState")
			end if
		end if

		'PrintAllSonosDevicesState(userData.sonos)
		diagId = "Sonos Rendering event"
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " volume: " + str(sonosDevice.volume) + ", mute: " + str(sonosDevice.mute))
	end if
End Sub

Sub OnAlarmClockEvent(s as object, sonosDevice as object, e as object)
	if e.GetVariable() = "AlarmListVersion" then
		ver = e.GetValue()
		rx = CreateObject("roRegex", ":", "i")
		sec = rx.split(ver)
		if sec.count() > 1 then
			ver = sec[1]
		end if
		updateDeviceVariable(s, sonosDevice, "AlarmListVersion", ver)

		diagId = "Sonos Alarm Clock event"
		s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " alarmCheckNeeded: " + sonosDevice.AlarmCheckNeeded)
	end if
End Sub

Sub OnZoneGroupTopologyEvent(s as object, sonosDevice as object, e as object)
	if e.GetVariable() = "ZoneGroupState" then
		' We only need to check messages from the sub and the bond master
		'  if we are only checking sub bonding
		bondMasterSpec$ = getSubBondMaster(s)
		
		if bondMasterSpec$ <> invalid and (sonosDevice.modelNumber = "sub" or sonosDevice.MatchesDeviceSpec(bondMasterSpec$)) then
			status$ = CheckSubBonding(s, e.GetValue())
		
			curStatus$ = getUserVariableValue(s, "subBondStatus")
			if curStatus$ <> invalid and curStatus$ <>status$ then
				sendPluginEvent(s, "TopologyChanged")
			end if		
			updateUserVar(s.userVariables, "subBondStatus", status$, true)
			
			diagId = "Zone Group Topology event"
			s.bsp.logging.WriteDiagnosticLogEntry(diagId, sonosDevice.modelNumber + " Sub Bonding Status: " + status$)
		end if
	end if
End Sub

Function CheckSubBonding(s as object, zoneGroupStateXml$ as string) as string
	bondMaster = invalid
	bondMasterSpec$ = getSubBondMaster(s)
	if bondMasterSpec$ <> invalid then
		bondMaster = GetDeviceByDevSpec(s.sonosDevices, bondMasterSpec$)
	end if
	
	if bondMaster = invalid then
		print "**** CheckSubBonding, bond master not found, NoBonding"
		return "NoBonding"
	end if

	subDevice = GetDeviceByDevSpec(s.sonosDevices, "sub")
	subUDN = "none"
	if subDevice <> invalid then
		subUDN = subDevice.UDN
	end if
	
	master=GetDeviceByUDN(s.sonosDevices, s.masterDeviceUDN)
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
	'print "updateDeviceVariable: ";variable;", device: ";sonosDevice.modelNumber
	
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
	else if variable = "subEnabled" then
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
End Sub

Sub updateDeviceUserVariable(sonos as object, sonosDevice as object, variable as string, value as string)
	' Update the uservariable for this device
	if (sonos.userVariables[sonosDevice.modelNumber+variable] <> invalid) then
		sonos.userVariables[sonosDevice.modelNumber+variable].SetCurrentValue(value, true)
	end if	

	' Update the master device user variable if the model number matches the master device
	if (sonos.masterDeviceUDN = sonosDevice.UDN) then
		if (sonos.userVariables["masterDevice"+variable] <> invalid) then
			print "Setting masterDevice";variable" to: ";value
			sonos.userVariables["masterDevice"+variable].SetCurrentValue(value, true)
		end if
	end if
End Sub	

Sub printAllDeviceTransportURI(sonos as object)
	' debug code for comparing states in different scenarios'
	print "printAllDeviceTransportURI - master: ";sonos.masterDeviceUDN
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
End Sub
'endregion


Function AddMP3(s as object)
	'  add music files 
	print "Adding mp3 files"
	
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

Function AddAllSonosUpgradeImages(s as object, version as string)
	print "Adding Sonos Upgrade images, version: " + version
	
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

' use this to send plugin events to a BrightAuthor Project
Sub sendPluginEvent(sonos as object, message as string)
 	pluginMessageCmd = CreateObject("roAssociativeArray")
	pluginMessageCmd["EventType"] = "EVENT_PLUGIN_MESSAGE"
	pluginMessageCmd["PluginName"] = "sonos"
	pluginMessageCmd["PluginMessage"] = message
	sonos.msgPort.PostMessage(pluginMessageCmd)
End Sub

' this is only to emulate sending an advanced command
sub sendPluginMessage(sonos as object, message as string)
	pluginMessageCmd = CreateObject("roAssociativeArray")
	pluginMessageCmd["EventType"] = "SEND_PLUGIN_MESSAGE"
	pluginMessageCmd["PluginName"] = "sonos"
	pluginMessageCmd["PluginMessage"] = message
	sonos.msgPort.PostMessage(pluginMessageCmd)
end sub

Function getUserVariableValue(sonos as object, varName as string) as object
    varValue = invalid

    if sonos.UserVariables[varName] <> invalid then
        varValue = sonos.userVariables[varName].currentValue$
        if varValue = "none" then
            varValue = invalid
        end if
    end if

    return varValue
End Function

Sub updateUserVar(uv as object, targetVar as string, newValue as string, postMsg as boolean)
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
End Sub

Sub setbuttonstate(sonos as object, state as string)
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
End Sub	
		
Function getPlayerNameByModel(model as object) as String
	
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
End Function		

Function escapeDecode(str as String) as String
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
End Function
