import os, sys, socket, signal, threading, httplib, urllib, time, select
import SimpleHTTPServer, SocketServer

def serve_files(p):
   port = int(p)
   Handler = SimpleHTTPServer.SimpleHTTPRequestHandler
   httpd = SocketServer.TCPServer(("", port), Handler)
   httpd.serve_forever()

def trigger_update():
   print "none"


def usage():
    print "usage: %s <Sonos-Player-IP> <version>" %(sys.argv[0])
    sys.exit(1)

def upd_post(sonosIP,version,port):

   # trick to get our own IP - and the right one in case we are multi-homed
   s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
   s.connect((sonosIP,80))
   ownIP = s.getsockname()[0]
   s.close()

   xml="<s:Envelope s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>"
   xml+="<u:BeginSoftwareUpdate xmlns:u=\"urn:schemas-upnp-org:service:ZoneGroupTopology:1\">"
   xml+="<UpdateURL>http://"
   xml+=ownIP
   xml+=":"+str(port)+"/^"+version
   xml+="</UpdateURL><Flags>1</Flags></u:BeginSoftwareUpdate></s:Body></s:Envelope>"

   params = ""
   headers = {"Content-type": "text/xml","Accept": "*/*","SOAPACTION": "urn:schemas-upnp-org:service:ZoneGroupTopology:1#BeginSoftwareUpdate", "Content-Length": "%d" % len(xml)}
   targetURL = sonosIP+":1400"
   conn = httplib.HTTPConnection(targetURL)
   conn.request("POST", "/ZoneGroupTopology/Control", params, headers)
   conn.send(xml)
   response = conn.getresponse()
#   print response.status, response.reason
   if response.reason=="OK":
      print "Sonos player accepts upgrade command"

   data = response.read()
   conn.close()


def alive(sonosIP, version, port):

   bufferSize = 1024 # whatever you need

   s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
   s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1) 

   s.bind(('0.0.0.0', port))
   s.setblocking(0)

   while True:
       result = select.select([s],[],[])
       msg = result[0][0].recv(bufferSize) 
#       print msg

       if "NTS: ssdp:alive" in msg:
#           print "ALIVE"
           if sonosIP in msg:
 #            print "IP MATCH"
             if version in msg:
                print "Sonos Player at "+sonosIP+" is now at version "+version
                os._exit(1)


def main():
   if len(sys.argv) < 3:
        usage()

   signal.signal(signal.SIGINT, lambda x,y: sys.exit(0))

   sonosIP = sys.argv[1]
   version = sys.argv[2]
   port    = sys.argv[3]

   a = threading.Thread(target=alive, args=(sonosIP,version,1900,))
   a.daemon=True
   a.start()
  

   s = threading.Thread(target=serve_files, args=(port,))
   s.daemon=True
   s.start()

   c = threading.Thread(target=upd_post, args=(sonosIP,version,port,))
   c.daemon=True
   c.start()

   while True:
      time.sleep(1)


if __name__ == "__main__":
    main()


