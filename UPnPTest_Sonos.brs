Sub Main()
    print "UPNP Test Script"

    mp = CreateObject("roMessagePort")
    sonos = newSonos(mp)

	while true
		e = mp.WaitMessage(0)
		sonos_ProcessEvent(e, sonos)
	end while
End Sub

Function newSonos(msgPort As Object)
	print "initSonos"

	' Create the object to return and set it up
	s = {}
	s.msgPort = msgPort
	s.st = CreateObject("roSystemTime")
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

	if type(event) = "roUPnPSearchEvent" then
		obj = event.GetObject()
		evType = event.GetType()
		if evType = 1 and type(obj) = "roAssociativeArray" and obj.USN <> invalid and obj.USN.Left(11) = "uuid:RINCON" then
			print "UPnPSearchEvent received for Sonos device, object type: ";type(obj)
			print "-- ";obj.USN
		endif
		if evType = 1 and type(obj) = "roUPnPDevice" then
			' response to search
			CheckUPnPDevice(obj, s)
		else if evType = 0 and type(obj) = "roAssociativeArray" then
			' SSDP Notify
			'CheckSSDPNotification(obj, s)
		end if
		retval = true
	else if type(event) = "roUPnPActionResult" then
		HandleSonosUPnPActionResult(event, s)
	else if type(event) = "roUPnPServiceEvent" then
		print "### Received service event from service: ";event.GetUUID()
		retval = HandleSonosUPnPServiceEvent(event, s)
	else if type(event) = "roTimerEvent" then
		if (event.GetSourceIdentity() = s.timerAliveCheck.GetIdentity()) then
			print "AliveCheck at ";s.st.GetLocalDateTime()
			StartAliveCheckTimer(s)
			for each device in s.sonosDevices
			    if device.alive=true then
			        ' mark it as false - an alive should come by and mark it as true again'
			        device.alive=false
			    else if device.alive=false then
			        DeletePlayerByUDN(s,device.UDN)
			        print "+++ alive timer expired - device [";device.modelNumber;" - ";device.UDN;"] not seen and is deleted"
			    end if
			end for
			' Now re-scan
			FindAllSonosDevices(s)
	        retval=true
		end if
	end if

	return retval

End Function

Sub CreateUPnPController(s as Object) 
	if s.upnp = invalid then
		print "Creating roUPnPController"
		s.upnp = CreateObject("roUPnPController")
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

Function IsModelDesired(model as string) as boolean
	' For testing, only s1 is desired
	if model = "s1" then
		return true
	end if
	return false
End Function

Function DeletePlayerByUDN(s as object, uuid as String) as boolean
	print "+++ DeletePlayerByUDN ";uuid
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
	else
		print "matching uuid not in list: ";uuid
	end if		
	return found
end function

Sub CheckUPnPDevice(upnpDevice as Object, s as Object)

	info = upnpDevice.GetDeviceInfo()
	deviceType = info.deviceType
	if (instr(1, deviceType, "urn:schemas-upnp-org:device:ZonePlayer:1")) then

		headers = upnpDevice.GetHeaders()
		baseURL = GetBaseURLFromLocation(headers.location)
		model = GetPlayerModelByBaseIP(s.sonosDevices, baseURL)			
		model = lcase(model)
		print "Found Sonos Device at baseURL ";baseURL

		if (model = "") then
			model = lcase(info.modelNumber)
			
			desired = IsModelDesired(model)
			SonosDevice = newSonosDevice(s,upnpDevice,desired)
			if desired=true
				SonosDevice.desired = true

				print "Sonos at ";baseURL;" is desired"

				' do the RDM ping'
				'xfer = rdmPingAsync(s.msgPort,sonosDevice.baseURL,s.hhid) 
				
				SonosRegisterForEvents(s,SonosDevice)
			end if ' desired=true'
			s.sonosDevices.push(SonosDevice)
		else
			print "Player ";model;" already exists in device list"
			sonosDevice=GetDeviceByPlayerModel(s.sonosDevices, model)
			if sonosDevice <> invalid then
				sonosDevice.alive=true
				desired=IsModelDesired(model)
				if desired=true then
					SonosDevice.desired=true
					print "Player ";model;" is DESIRED"
				else
					print "Player ";model;" is not desired"
				end if
			end if
		end if
	end if
	
End Sub

Function newSonosDevice(sonos as Object, upnpDevice as Object, isDesired as Boolean) as Object
	sonosDevice = { baseURL: "", deviceXML: invalid, modelNumber: "", modelDescription: "", UDN: "", deviceType: "", hhid: "none", uuid: "", softwareVersion: ""}
	
	headers = upnpDevice.GetHeaders()
	sonosDevice.baseURL = GetBaseURLFromLocation(headers.location)
	sonosDevice.hhid = ""
	if headers.DoesExist("X-RINCON-HOUSEHOLD") then
		hhid = headers["X-RINCON-HOUSEHOLD"]
	end if
	sonosDevice.uuid = mid(headers.USN,6)
	sonosDevice.bootseq = headers["X-RINCON-BOOTSEQ"]
	
	info = upnpDevice.GetDeviceInfo()
	sonosDevice.modelNumber = lcase(info.modelNumber)
	sonosDevice.modelDescription = lcase(info.modelDescription)
	sonosDevice.UDN = mid(info.UDN,6)
	sonosDevice.deviceType = info.deviceType
	sonosDevice.softwareVersion=lcase(info.softwareVersion)
	
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
	
	sonosDevice.desired=isDesired
	sonosDevice.alive=true

	print "device HHID:       ["+SonosDevice.hhid+"]"
	print "device UDN:        ["+SonosDevice.UDN+"]"
	print "software Version:  ["+sonosDevice.softwareVersion+"]"
	print "boot sequence:     ["+sonosDevice.bootseq+"]"

	return sonosDevice
End Function

Function GetBaseURLFromLocation(location as string) as string
	baseURL = ""
	if location <> invalid then
		baseURL = left(location, instr(8, location, "/")-1)
	end if
	return baseURL
End Function

Function GetPlayerModelByBaseIP(sonosDevices as Object, IP as string) as string
	returnModel = ""
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].baseURL = IP) then
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

Function GetDeviceByPlayerBaseURL(sonosDevices as Object, baseURL as string) as object
	device = invalid
	for i = 0 to sonosDevices.count() - 1
		if (sonosDevices[i].baseURL = baseURL) then
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
return
		
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


