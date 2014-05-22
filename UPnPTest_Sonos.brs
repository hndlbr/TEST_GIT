Sub Main()
	print "****************************************************************************"
    print "UPNP Test Script - Start"
 	print "****************************************************************************"

    mp = CreateObject("roMessagePort")
    sonos = newSonos(mp)

	while true
		e = mp.WaitMessage(0)
		sonos_ProcessEvent(e, sonos)
	end while
End Sub

Function newSonos(msgPort As Object)
	' Create the object to return and set it up
	s = {}
	s.msgPort = msgPort
	s.st = CreateObject("roSystemTime")
	print "initSonos at ";s.st.GetLocalDateTime()
	
	s.upnp = invalid 
	s.sonosDevices = CreateObject("roArray",1, True)

	' Create an array to hold RequestData objects for UPnP actions (Invokes or Subscribes)
	s.upnpActionObjects = createObject("roArray",0, true)

	' Create timer to see if players have gone away
	s.timerAliveCheck=CreateObject("roTimer")  
	s.timerAliveCheck.SetPort(msgPort)
	StartAliveCheckTimer(s)
	
	' Do initial search
	FindAllSonosDevices(s)

	return s
End Function

Sub StartAliveCheckTimer(s as object)
	timeout=s.st.GetLocalDateTime()
	delay = 60
	timeout.AddSeconds(delay)
	s.timerAliveCheck.SetDateTime(timeout)
	s.timerAliveCheck.Start()
End Sub

Function sonos_ProcessEvent(event As Object, s as Object) as boolean
	retval = false
	'print "Process event: ";type(event)
	if type(event) = "roUPnPSearchEvent" then
		obj = event.GetObject()
		evType = event.GetType()
		if evType = 0 then
			if type(obj) = "roAssociativeArray" then
				CheckSSDPNotification(obj, s)
			else
				print "!!!!! Received roUPnPSearchEvent, type 0 - unexpected object: ";type(obj)
			end if
		else if evType = 1 then
			if type(obj) = "roAssociativeArray" then
				CheckUPnPDeviceStatus(obj, s)
			else
				print "!!!!! Received roUPnPSearchEvent, type 1 - unexpected object: ";type(obj)
			end if
		else if evType = 2 then
			if type(obj) = "roUPnPDevice" then
				' new device
				CheckNewUPnPDevice(obj, s)
			else
				print "!!!!! Received roUPnPSearchEvent, type 2 - unexpected object: ";type(obj)
			end if
		else if evType = 3 then
			if type(obj) = "roUPnPDevice" then
				' device was removed 
				CheckUPnPDeviceRemoved(obj, s)
			else
				print "!!!!! Received roUPnPSearchEvent, type 3 - unexpected object: ";type(obj)
			end if
		end if
		retval = true
	else if type(event) = "roUPnPActionResult" then
		HandleSonosUPnPActionResult(event, s)
	else if type(event) = "roUPnPServiceEvent" then
		print "### Received service event from service: ";event.GetUUID()
		retval = HandleSonosUPnPServiceEvent(event, s)
	else if type(event) = "roTimerEvent" then
		if (event.GetSourceIdentity() = s.timerAliveCheck.GetIdentity()) then
			DoAliveCheck(s)
	        retval=true
		end if
	end if

	return retval

End Function

Sub CheckSSDPNotification(obj, s)
	if obj.ssdpType <> invalid and lcase(obj.ssdpType.Left(8)) <> "m-search" then
		udn = "<unknown>"
		if obj.DoesExist("USN") then
			udn = GetUDNfromUSNHeader(obj.USN)
		end if
		aliveFound = obj.DoesExist("NTS") and obj.NTS = "ssdp:alive"
		byebyeFound = obj.DoesExist("NTS") and obj.NTS = "ssdp:byebye"
		rootDevice = obj.DoesExist("NT") and obj.NT = "upnp:rootdevice"
		sonosNotification = obj.DoesExist("X-RINCON-BOOTSEQ")
		if sonosNotification and rootDevice then
			if 	aliveFound then
				print "***********  Received ssdp:alive, UDN: ";udn
			else if byebyeFound then
				print "&&&&&&&&&&&  Received ssdp:byebye, UDN: ";udn
			end if
		end if
	end if
End Sub

Sub CreateUPnPController(s as Object) 
	if s.upnp = invalid then
		print "Creating roUPnPController"
		s.upnp = CreateObject("roUPnPController")
		s.upnp.SetDebug(true)
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

Function IsModelDesired(model as string) as boolean
	' For testing, only s1 is desired
	if model = "s1" then
		return true
	end if
	return false
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
			
			desired = IsModelDesired(model)
			sonosDevice = newSonosDevice(s,upnpDevice,desired)
			if desired=true
				sonosDevice.desired = true

				print "Sonos at ";baseURL;" is desired"

				' do the RDM ping'
				'xfer = rdmPingAsync(s.msgPort,sonosDevice.baseURL,s.hhid) 
				
				SonosRegisterForEvents(s,sonosDevice)
			end if ' desired=true'
			s.sonosDevices.push(sonosDevice)
		else
			sonosDevice=GetDeviceByUDN(s.sonosDevices, udn)
			desired=IsModelDesired(model)
			updateSonosDevice(sonosDevice,upnpDevice,desired)
			if desired then
				des$="is desired"
			else
				des$="is NOT desired"
			end if
			print "Player ";model;" already exists in device list, ";des$
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
			UpdateSonosDeviceSSDPData(sonosDevice, ssdpData)
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
	' No need to delete the UPnP controller's device, it is already deleted
	' We do need to delete from local list...
	DeletePlayerByUDN(s,udn,false)
End Sub

Function newSonosDevice(sonos as Object, upnpDevice as Object, isDesired as Boolean) as Object
	sonosDevice = { baseURL: "", deviceXML: invalid, modelNumber: "", modelDescription: "", UDN: "", deviceType: "", hhid: "none", uuid: "", softwareVersion: ""}
	
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
	sonosDevice.SleepTimerGeneration = 0
	sonosDevice.AlarmListVersion = -1
	sonosDevice.AlarmCheckNeeded = "yes"
	
	print "device HHID:       ["+SonosDevice.hhid+"]"
	print "device UDN:        ["+SonosDevice.UDN+"]"
	print "software Version:  ["+sonosDevice.softwareVersion+"]"
	print "boot sequence:     ["+sonosDevice.bootseq+"]"

	return sonosDevice
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
	end if
End Sub

Sub UpdateSonosDeviceSSDPData(sonosDevice as Object, ssdpData as Object)
		sonosDevice.baseURL = GetBaseURLFromLocation(ssdpData.location)
		sonosDevice.hhid = ""
		if ssdpData.DoesExist("X-RINCON-HOUSEHOLD") then
			hhid = ssdpData["X-RINCON-HOUSEHOLD"]
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

Function GetDeviceByPlayerModel(sonosDevices as Object, modelNumber as string) as object
	
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].modelNumber = modelNumber) then
			device = sonosDevices[i]
		end if
	end for
	return device

End function

Function GetDeviceByUDN(sonosDevices as Object, UDN as string) as object
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].UDN = UDN) then
			device = sonosDevices[i]
		end if
	end for
	return device
End Function

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
			connectedPlayerIP=sonosReqData["dest"]
			reqType=sonosReqData["type"]
			print "UPnP return code: "; success; " request type: ";reqType;" from ";connectedPlayerIP
			' delete this transfer object from the transfer object list
			sonos.upnpActionObjects.Delete(i)
			found = true
		end if
		i = i + 1
	end while
End Function

Sub SonosRegisterForEvents(sonos as Object, device as Object)
	if device.desired = true then
		if device.avTransportService <> invalid then
			avtransport_event_handler = { name: "AVTransport", HandleEvent: OnAVTransportEvent, SonosDevice: device, sonos:sonos }
			device.avTransportService.SetUserData(avtransport_event_handler)

			print "Subscribing to AVTransport service for device ";device.modelNumber
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RegisterForAVTransportEvent"
			sonosReqData["dest"]=device.baseURL
			sonosReqData["id"]=device.avTransportService.Subscribe()
			sonos.upnpActionObjects.push(sonosReqData)
		end if
		
' Uncomment the return below to test making only a single call
'return
		
		if device.renderingService <> invalid then
			renderingcontrol_event_handler = { name: "RenderingControl", HandleEvent: OnRenderingControlEvent, SonosDevice: device, sonos:sonos }
			device.renderingService.SetUserData(renderingcontrol_event_handler)

			print "Subscribing to Rendering service for device ";device.modelNumber
			sonosReqData=CreateObject("roAssociativeArray")
			sonosReqData["type"]="RegisterForRenderingControlEvent"
			sonosReqData["dest"]=device.baseURL
			sonosReqData["id"]=device.renderingService.Subscribe()
			sonos.upnpActionObjects.push(sonosReqData)
		end if
	
		alarmclock_event_handler = { name: "AlarmClock", HandleEvent: OnAlarmClockEvent, SonosDevice: device, sonos:sonos }
		device.alarmClockService.SetUserData(alarmclock_event_handler)

		print "Subscribing to AlarmClock service for device ";device.modelNumber
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="RegisterForAlarmClockEvent"
		sonosReqData["dest"]=device.baseURL
		sonosReqData["id"]=device.alarmClockService.Subscribe()
		sonos.upnpActionObjects.push(sonosReqData)
		
		zoneGroupTopology_event_handler = { name: "ZoneGroupTopology", HandleEvent: OnZoneGroupTopologyEvent, SonosDevice: device, sonos:sonos }
		device.zoneGroupTopologyService.SetUserData(zoneGroupTopology_event_handler)

		print "Subscribing to ZoneGroupTopology service for device ";device.modelNumber
		sonosReqData=CreateObject("roAssociativeArray")
		sonosReqData["type"]="RegisterForZoneGroupTopologyEvent"
		sonosReqData["dest"]=device.baseURL
		sonosReqData["id"]=device.zoneGroupTopologyService.Subscribe()
		sonos.upnpActionObjects.push(sonosReqData)
	end if
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

		sonosDevice.transportState = event.instanceid.transportstate@val
		if (sonosDevice.transportState <> invalid) then 
			print "Transport event from ";sonosDevice.modelNumber;" TransportState: [";sonosDevice.transportState;"] "
		end if

		sonosDevice.AVTransportURI = event.instanceid.AVTransportURI@val
		if (sonosDevice.AVTransportURI <> invalid) then 
			print "Transport event from ";sonosDevice.modelNumber;" AVTransportURI: [";sonosDevice.AVTransportURI;"] "
		end if

		sonosDevice.CurrentPlayMode = event.instanceid.CurrentPlayMode@val
		if (sonosDevice.CurrentPlayMode <> invalid) then 
			print "Transport event from ";sonosDevice.modelNumber;" CurrentPlayMode: [";sonosDevice.CurrentPlayMode;"] "
		end if

		sonosDevice.SleepTimerGeneration = event.instanceid.rSleepTimerGeneration@val
		if (sonosDevice.SleepTimerGeneration <> invalid) then 
			print "Transport event from ";sonosDevice.modelNumber;" SleepTimerGeneration: [";sonosDevice.SleepTimerGeneration;"] "
		end if
	end if
End Sub

Sub OnRenderingControlEvent(s as object, sonosDevice as object, e as object)
	if e.GetVariable() = "LastChange" then
		print "RenderingControl event from ";sonosDevice.modelNumber
		eventString = e.GetValue()
		
		r=CreateObject("roXMLElement")
		r.Parse(eventString)

		changed = false
		vals=r.event.InstanceID
		for each x in vals.GetChildElements()
			name=x.GetName()
		'	print "|"+name"|"	
			if name="Volume" then
				c=x@channel
				v=x@val
				if c="Master" then
					sonosDevice.Volume = v
					print "+++ Master volume changed (channel: ";c;")"
					changed = true
				else
					print "+++ Other volume changed (channel: ";c;")"
				end if
			end if	
			if name="Mute" then
				c=x@channel
				v=x@val
				if c="Master" then
					sonosDevice.Mute = v
					print "+++ Master muted (channel: ";c;")"
					changed = true
				else
					print "+++ Other muted (channel: ";c;")"
				end if
			end if	
		end for
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
		print "AlarmClock event from ";sonosDevice.modelNumber;", list version: ";ver
	end if
End Sub

Sub OnZoneGroupTopologyEvent(s as object, sonosDevice as object, e as object)
	if e.GetVariable() = "ZoneGroupState" then
		print "ZoneGroupTopology event from ";sonosDevice.modelNumber
	end if
End Sub


