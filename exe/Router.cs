// SharedPC Manager - opens ports on the home router automatically (UPnP)
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;

namespace SharedPC
{
    // ---------- opens ports on the home router automatically (UPnP), so people can connect from anywhere ----------
    static class Router
    {
        static string controlUrl, serviceType;
        public static string Status = "בודק את הראוטר…";
        public static string ExternalIp = "";
        public static bool Ok;

        static string Http(string url, string soapAction, string body)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = 5000; req.ReadWriteTimeout = 5000;
            if (soapAction != null)
            {
                req.Method = "POST"; req.ContentType = "text/xml; charset=\"utf-8\"";
                req.Headers.Add("SOAPACTION", "\"" + serviceType + "#" + soapAction + "\"");
                var b = Encoding.UTF8.GetBytes(body); req.ContentLength = b.Length;
                using (var s = req.GetRequestStream()) s.Write(b, 0, b.Length);
            }
            try { using (var r = req.GetResponse()) using (var sr = new StreamReader(r.GetResponseStream())) return sr.ReadToEnd(); }
            catch (WebException ex)
            {
                if (ex.Response == null) throw;
                using (var sr = new StreamReader(ex.Response.GetResponseStream())) throw new Exception("router: " + sr.ReadToEnd());
            }
        }
        static string Soap(string action, string args)
        {
            var body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>" +
                       "<u:" + action + " xmlns:u=\"" + serviceType + "\">" + args + "</u:" + action + "></s:Body></s:Envelope>";
            return Http(controlUrl, action, body);
        }
        static string Tag(string xml, string tag)
        {
            var m = System.Text.RegularExpressions.Regex.Match(xml, "<(?:\\w+:)?" + tag + ">([^<]*)</(?:\\w+:)?" + tag + ">");
            return m.Success ? m.Groups[1].Value.Trim() : "";
        }

        static bool Discover(string lanIp)
        {
            if (controlUrl != null) return true;
            foreach (var st in new[] { "urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2", "upnp:rootdevice" })
            {
                var locations = new List<string>(); var sources = new Dictionary<string, string>();
                using (var udp = new System.Net.Sockets.UdpClient(new IPEndPoint(IPAddress.Parse(lanIp), 0)))
                {
                    udp.Client.ReceiveTimeout = 2500;
                    var msg = Encoding.ASCII.GetBytes("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + st + "\r\n\r\n");
                    var to = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
                    udp.Send(msg, msg.Length, to); udp.Send(msg, msg.Length, to);
                    var end = DateTime.Now.AddSeconds(3);
                    while (DateTime.Now < end)
                    {
                        try
                        {
                            var from = new IPEndPoint(IPAddress.Any, 0);
                            var resp = Encoding.ASCII.GetString(udp.Receive(ref from));
                            var m = System.Text.RegularExpressions.Regex.Match(resp, "(?im)^location:\\s*(\\S+)");
                            if (m.Success && !locations.Contains(m.Groups[1].Value)) { locations.Add(m.Groups[1].Value); sources[m.Groups[1].Value] = from.Address.ToString(); }
                        }
                        catch (System.Net.Sockets.SocketException) { break; }
                    }
                }
                foreach (var loc in locations)
                {
                    try
                    {
                        var xml = Http(loc, null, null);
                        foreach (var svc in new[] { "urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1" })
                        {
                            var i = xml.IndexOf(svc, StringComparison.OrdinalIgnoreCase); if (i < 0) continue;
                            var rest = xml.Substring(i);
                            var cu = Tag(rest, "controlURL"); if (cu == "") continue;
                            var u = new Uri(loc);
                            controlUrl = cu.StartsWith("http") ? cu : u.GetLeftPart(UriPartial.Authority) + (cu.StartsWith("/") ? "" : "/") + cu;
                            // talk to the router over IPv4 (some routers refuse IPv4 port mappings requested over IPv6)
                            string src;
                            if (sources.TryGetValue(loc, out src) && src.Contains(".") && !src.Contains(":"))
                            { var cuU = new Uri(controlUrl); controlUrl = new UriBuilder(cuU) { Host = src }.Uri.ToString(); }
                            serviceType = svc;
                            App.Log("UPnP router found: " + controlUrl + " (" + svc + ")");
                            return true;
                        }
                    }
                    catch (Exception ex) { App.Log("UPnP " + loc + ": " + ex.Message); }
                }
            }
            return false;
        }

        static bool IsPrivate(string ip)
        {
            IPAddress a; if (!IPAddress.TryParse(ip, out a)) return true;
            var b = a.GetAddressBytes();
            return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127) || b[0] == 127 || b[0] == 0;
        }

        static void AddMapping(int port, string lanIp, int lease)
        {
            Soap("AddPortMapping",
                "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>" +
                "<NewInternalPort>" + port + "</NewInternalPort><NewInternalClient>" + lanIp + "</NewInternalClient><NewEnabled>1</NewEnabled>" +
                "<NewPortMappingDescription>SharedPC " + port + "</NewPortMappingDescription><NewLeaseDuration>" + lease + "</NewLeaseDuration>");
        }
        static bool Map(int port, string lanIp)
        {
            try { AddMapping(port, lanIp, 0); return true; }
            catch (Exception ex)
            {
                var msg = ex.Message;
                if (msg.Contains("725")) { AddMapping(port, lanIp, 604800); return true; }   // router accepts only timed leases (refreshed every 10 min anyway)
                if (!msg.Contains("718")) throw;
                // 718 = a mapping for this port already exists: fine if it already points to this PC, otherwise replace it
                try
                {
                    var cur = Soap("GetSpecificPortMappingEntry", "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>");
                    if (Tag(cur, "NewInternalClient") == lanIp && Tag(cur, "NewInternalPort") == port.ToString()) { App.Log("UPnP " + port + " already forwarded to this PC"); return true; }
                    App.Log("UPnP " + port + " points to " + Tag(cur, "NewInternalClient") + ":" + Tag(cur, "NewInternalPort") + " - replacing");
                }
                catch (Exception qe) { App.Log("UPnP query " + port + ": " + qe.Message); }
                try { Soap("DeletePortMapping", "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>"); } catch { }
                AddMapping(port, lanIp, 0);
                return true;
            }
        }

        // make sure every ready computer's port is forwarded to this PC
        public static void Sync(string lanIp, string publicIp, IEnumerable<int> ports)
        {
            try
            {
                if (!Discover(lanIp)) { Ok = false; Status = "⚠️ הראוטר לא מאפשר פתיחת פורטים אוטומטית (UPnP כבוי). צריך להעביר פורטים ידנית בראוטר."; return; }
                try { ExternalIp = Tag(Soap("GetExternalIPAddress", ""), "NewExternalIPAddress"); } catch { ExternalIp = ""; }
                if (ExternalIp != "" && IsPrivate(ExternalIp))
                { Ok = false; Status = "❌ ספק האינטרנט שלך לא נותן IP ציבורי אמיתי (CGNAT: " + ExternalIp + "). אי אפשר להתחבר מבחוץ דרך הראוטר."; return; }
                int done = 0; var errors = new List<string>();
                foreach (var port in ports.Distinct())
                {
                    try
                    {
                        if (Map(port, lanIp)) done++;
                    }
                    catch (Exception ex) { var code = Tag(ex.Message, "errorCode") + " " + Tag(ex.Message, "errorDescription"); errors.Add(port + " (" + (code.Trim() != "" ? code.Trim() : ex.Message) + ")"); App.Log("UPnP map " + port + " failed: " + ex.Message); }
                }
                Ok = errors.Count == 0;
                Status = Ok ? "✅ הפורטים פתוחים בראוטר (" + done + "). אפשר להתחבר מכל מקום עם " + (ExternalIp != "" ? ExternalIp : publicIp) + ":פורט"
                            : "⚠️ חלק מהפורטים לא נפתחו בראוטר: " + string.Join(", ", errors.Take(3));
            }
            catch (Exception ex) { Ok = false; Status = "⚠️ בדיקת הראוטר נכשלה: " + ex.Message; App.Log("UPnP: " + ex); }
        }

        public static void Remove(string lanIp, int port)
        {
            try { if (Discover(lanIp)) Soap("DeletePortMapping", "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>"); }
            catch (Exception ex) { App.Log("UPnP delete " + port + ": " + ex.Message); }
        }
    }

}
