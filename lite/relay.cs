// ClassroomBroadcaster Lite relay server
// - Plain TCP server (no HttpListener / URL reservation needed) with a tiny HTTP + WebSocket implementation
// - Serves the static web pages (student player / teacher page)
// - Teacher page publishes fragmented MP4 over WebSocket:  /ws/pub/<room>
// - Students receive the same fragments over WebSocket:     /ws/view/<room>
// - Status JSON:                                            /api/status
// Written in C# 5 so it compiles with the C# compiler built into
// .NET Framework 4.x (PowerShell 5.1 Add-Type) on Windows 10 / 11.
// Binary message format: byte 0 = kind (1 = init segment, 2 = keyframe fragment, 3 = delta fragment)
// Text messages to viewers: {"type":"online"} / {"type":"offline"}

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ClassroomLite
{
    public class WsMessage
    {
        public byte[] Data;
        public bool Text;
    }

    public class WsConn
    {
        readonly TcpClient client;
        readonly NetworkStream stream;
        readonly SemaphoreSlim writeLock = new SemaphoreSlim(1, 1);
        public volatile bool Closed;

        public WsConn(TcpClient c, NetworkStream s) { client = c; stream = s; }

        async Task<byte[]> ReadExact(int n)
        {
            byte[] b = new byte[n];
            int o = 0;
            while (o < n)
            {
                int r = await stream.ReadAsync(b, o, n - o);
                if (r <= 0) throw new IOException("closed");
                o += r;
            }
            return b;
        }

        // Returns null when the peer closes the connection.
        public async Task<WsMessage> ReceiveAsync(int maxSize)
        {
            MemoryStream msg = null;
            int msgOp = 0;
            while (true)
            {
                byte[] h = await ReadExact(2);
                bool fin = (h[0] & 0x80) != 0;
                int op = h[0] & 0x0F;
                bool masked = (h[1] & 0x80) != 0;
                long len = h[1] & 0x7F;
                if (len == 126)
                {
                    byte[] e = await ReadExact(2);
                    len = (e[0] << 8) | e[1];
                }
                else if (len == 127)
                {
                    byte[] e = await ReadExact(8);
                    len = 0;
                    for (int i = 0; i < 8; i++) len = (len << 8) | e[i];
                }
                if (len < 0 || len > maxSize) throw new IOException("frame too large");
                byte[] mask = masked ? await ReadExact(4) : null;
                byte[] payload = len > 0 ? await ReadExact((int)len) : new byte[0];
                if (masked) for (int i = 0; i < payload.Length; i++) payload[i] ^= mask[i & 3];

                if (op == 8) return null;                                   // close
                if (op == 9) { await SendFrame(10, payload); continue; }    // ping -> pong
                if (op == 10) continue;                                     // pong
                if (op == 1 || op == 2) { msgOp = op; msg = new MemoryStream(); }
                if (msg == null) continue;
                msg.Write(payload, 0, payload.Length);
                if (msg.Length > maxSize) throw new IOException("message too large");
                if (fin)
                {
                    WsMessage m = new WsMessage();
                    m.Text = msgOp == 1;
                    m.Data = msg.ToArray();
                    return m;
                }
            }
        }

        public Task SendAsync(byte[] data, bool text) { return SendFrame(text ? 1 : 2, data); }
        public Task PingAsync() { return SendFrame(9, new byte[0]); }

        async Task SendFrame(int op, byte[] data)
        {
            int n = data.Length;
            int hl = n < 126 ? 2 : (n < 65536 ? 4 : 10);
            byte[] f = new byte[hl + n];
            f[0] = (byte)(0x80 | op);
            if (n < 126) f[1] = (byte)n;
            else if (n < 65536) { f[1] = 126; f[2] = (byte)(n >> 8); f[3] = (byte)n; }
            else { f[1] = 127; long L = n; for (int i = 0; i < 8; i++) f[9 - i] = (byte)(L >> (8 * i)); }
            Buffer.BlockCopy(data, 0, f, hl, n);
            await writeLock.WaitAsync();
            try { await stream.WriteAsync(f, 0, f.Length); }
            finally { writeLock.Release(); }
        }

        public void Abort()
        {
            Closed = true;
            try { client.Close(); } catch { }
        }
    }

    public class Msg
    {
        public byte[] Data;
        public bool Text;
        public byte Kind;
    }

    public class Viewer
    {
        public WsConn Ws;
        public Room Room;
        public string Ip;
        public readonly object Lock = new object();
        public Queue<Msg> Q = new Queue<Msg>();
        public long QBytes;
        public bool Sending;
        public bool NeedKey;
        public bool Dead;
    }

    public class Room
    {
        public string Name;
        public bool AnyPublisher;           // allow publishing from any IP (otherwise loopback + allowed IPs)
        public byte[] Init;
        public List<byte[]> Gop = new List<byte[]>();
        public long GopBytes;
        public WsConn Publisher;
        public string PublisherIp = "";
        public List<Viewer> Viewers = new List<Viewer>();
        public long BytesIn;
        public long BytesOut;
        public readonly object Lock = new object();
    }

    public static class Server
    {
        const long MaxViewerQueue = 6L * 1024 * 1024;   // beyond this a slow viewer is resynced at the next keyframe
        const long MaxGopBytes = 24L * 1024 * 1024;
        const int MaxMessage = 16 * 1024 * 1024;

        static TcpListener listener;
        static string root;
        static string studentUrl = "";
        static Dictionary<string, Room> rooms = new Dictionary<string, Room>();
        static HashSet<string> allowedIps = new HashSet<string>();
        static volatile bool running;
        static Timer pingTimer;

        static readonly Dictionary<string, string> Mime = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".html", "text/html; charset=utf-8" }, { ".htm", "text/html; charset=utf-8" },
            { ".js", "text/javascript; charset=utf-8" }, { ".css", "text/css; charset=utf-8" },
            { ".json", "application/json; charset=utf-8" }, { ".png", "image/png" },
            { ".svg", "image/svg+xml" }, { ".ico", "image/x-icon" }
        };

        // roomSpec: "teacher1,teacher2*" (* = any IP may publish); allowedPublisherIps: "a.b.c.d,e.f.g.h"
        public static void Start(int port, string wwwRoot, string roomSpec, string allowedPublisherIps, string studentUrlInfo)
        {
            root = Path.GetFullPath(wwwRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            studentUrl = studentUrlInfo ?? "";
            rooms.Clear();
            foreach (string raw in roomSpec.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string n = raw.Trim();
                Room r = new Room();
                r.AnyPublisher = n.EndsWith("*");
                r.Name = n.TrimEnd('*');
                rooms[r.Name] = r;
            }
            allowedIps.Clear();
            if (!string.IsNullOrEmpty(allowedPublisherIps))
                foreach (string ip in allowedPublisherIps.Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                    allowedIps.Add(ip.Trim());

            try
            {
                listener = new TcpListener(IPAddress.IPv6Any, port);
                listener.Server.DualMode = true;               // accept IPv4 and IPv6 (localhost may be ::1)
                listener.Start(512);
            }
            catch (Exception)
            {
                listener = new TcpListener(IPAddress.Any, port);
                listener.Start(512);
            }
            running = true;
            Task.Run(new Func<Task>(AcceptLoop));
            pingTimer = new Timer(delegate { PingAll(); }, null, 15000, 15000);
        }

        public static void Stop()
        {
            running = false;
            try { if (pingTimer != null) pingTimer.Dispose(); } catch { }
            try { listener.Stop(); } catch { }
            foreach (Room r in rooms.Values)
            {
                lock (r.Lock)
                {
                    if (r.Publisher != null) r.Publisher.Abort();
                    foreach (Viewer v in r.Viewers.ToArray()) v.Ws.Abort();
                }
            }
        }

        static async Task AcceptLoop()
        {
            while (running)
            {
                TcpClient c;
                try { c = await listener.AcceptTcpClientAsync(); }
                catch { if (!running) return; continue; }
                TcpClient cc = c;
                Task t = Task.Run(new Func<Task>(delegate { return Handle(cc); }));
                GC.KeepAlive(t);
            }
        }

        // ------------------------------------------------------------------ HTTP
        static async Task Handle(TcpClient client)
        {
            bool keepOpen = false;
            try
            {
                client.NoDelay = true;
                NetworkStream s = client.GetStream();
                string head = await ReadHead(s);
                if (head == null) return;
                string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                string[] req = lines[0].Split(' ');
                if (req.Length < 2) return;
                string method = req[0];
                string target = req[1];
                Dictionary<string, string> h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 1; i < lines.Length; i++)
                {
                    int k = lines[i].IndexOf(':');
                    if (k > 0) h[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim();
                }
                string path = target;
                int qi = path.IndexOf('?');
                if (qi >= 0) path = path.Substring(0, qi);

                IPAddress addr = ((IPEndPoint)client.Client.RemoteEndPoint).Address;
                if (addr.IsIPv4MappedToIPv6) addr = addr.MapToIPv4();
                string ip = addr.ToString();

                string upgrade;
                if (path.StartsWith("/ws/") && h.TryGetValue("Upgrade", out upgrade) &&
                    upgrade.Equals("websocket", StringComparison.OrdinalIgnoreCase))
                {
                    bool pub = path.StartsWith("/ws/pub/");
                    bool view = path.StartsWith("/ws/view/");
                    string name = pub ? path.Substring(8) : (view ? path.Substring(9) : "");
                    name = name.Trim('/');
                    Room room;
                    if ((!pub && !view) || !rooms.TryGetValue(name, out room))
                    {
                        await Reply(s, 404, "Not Found", "text/plain", Encoding.UTF8.GetBytes("not found"), false);
                        return;
                    }
                    if (pub && !(IPAddress.IsLoopback(addr) || room.AnyPublisher || allowedIps.Contains(ip)))
                    {
                        await Reply(s, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("publishing not allowed from " + ip), false);
                        return;
                    }
                    string key;
                    if (!h.TryGetValue("Sec-WebSocket-Key", out key)) return;
                    string accept;
                    using (SHA1 sha = SHA1.Create())
                        accept = Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                    byte[] resp = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
                    await s.WriteAsync(resp, 0, resp.Length);
                    WsConn ws = new WsConn(client, s);
                    keepOpen = true;
                    if (pub) await RunPublisher(room, ws, ip);
                    else await RunViewer(room, ws, ip);
                    return;
                }

                bool isHead = method == "HEAD";
                if (method != "GET" && !isHead)
                {
                    await Reply(s, 405, "Method Not Allowed", "text/plain", Encoding.UTF8.GetBytes("method not allowed"), false);
                    return;
                }
                if (path == "/api/status")
                {
                    await Reply(s, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(StatusJson()), isHead);
                    return;
                }
                string rel;
                try { rel = Uri.UnescapeDataString(path).TrimStart('/'); } catch { rel = ""; }
                if (rel.Length == 0 || rel.EndsWith("/")) rel += "index.html";
                string full = Path.GetFullPath(Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar)));
                if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
                {
                    await Reply(s, 404, "Not Found", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("404 Not Found"), isHead);
                    return;
                }
                string type;
                if (!Mime.TryGetValue(Path.GetExtension(full), out type)) type = "application/octet-stream";
                await Reply(s, 200, "OK", type, File.ReadAllBytes(full), isHead);
            }
            catch { }
            finally
            {
                if (!keepOpen) { try { client.Close(); } catch { } }
            }
        }

        static async Task<string> ReadHead(NetworkStream s)
        {
            byte[] buf = new byte[4096];
            MemoryStream ms = new MemoryStream();
            while (ms.Length < 32768)
            {
                int r = await s.ReadAsync(buf, 0, buf.Length);
                if (r <= 0) return null;
                ms.Write(buf, 0, r);
                byte[] all = ms.GetBuffer();
                int len = (int)ms.Length;
                for (int i = Math.Max(0, len - r - 3); i + 3 < len; i++)
                    if (all[i] == 13 && all[i + 1] == 10 && all[i + 2] == 13 && all[i + 3] == 10)
                        return Encoding.ASCII.GetString(all, 0, i);
            }
            return null;
        }

        static async Task Reply(NetworkStream s, int code, string reason, string type, byte[] body, bool headOnly)
        {
            string hdr = "HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: " + type +
                         "\r\nContent-Length: " + body.Length +
                         "\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
            byte[] hb = Encoding.ASCII.GetBytes(hdr);
            await s.WriteAsync(hb, 0, hb.Length);
            if (!headOnly && body.Length > 0) await s.WriteAsync(body, 0, body.Length);
            await s.FlushAsync();
        }

        // ------------------------------------------------------------------ publisher
        static async Task RunPublisher(Room room, WsConn ws, string ip)
        {
            WsConn old;
            lock (room.Lock)
            {
                old = room.Publisher;
                room.Publisher = ws;
                room.PublisherIp = ip;
                room.Init = null;
                room.Gop.Clear();
                room.GopBytes = 0;
            }
            if (old != null) old.Abort();
            BroadcastText(room, "{\"type\":\"online\"}");
            try
            {
                while (running && !ws.Closed)
                {
                    WsMessage m = await ws.ReceiveAsync(MaxMessage);
                    if (m == null) break;
                    if (room.Publisher != ws) break;          // replaced by a newer publisher
                    if (m.Text || m.Data.Length < 2) continue;
                    OnMedia(room, m.Data);
                }
            }
            catch { }
            bool wasCurrent = false;
            lock (room.Lock)
            {
                if (room.Publisher == ws)
                {
                    wasCurrent = true;
                    room.Publisher = null;
                    room.PublisherIp = "";
                    room.Init = null;
                    room.Gop.Clear();
                    room.GopBytes = 0;
                }
            }
            if (wasCurrent) BroadcastText(room, "{\"type\":\"offline\"}");
            ws.Abort();
        }

        static void OnMedia(Room room, byte[] msg)
        {
            byte kind = msg[0];
            if (kind < 1 || kind > 3) return;
            Interlocked.Add(ref room.BytesIn, msg.Length);
            lock (room.Lock)
            {
                if (kind == 1)
                {
                    room.Init = msg;
                    room.Gop.Clear();
                    room.GopBytes = 0;
                }
                else if (kind == 2)
                {
                    room.Gop.Clear();
                    room.Gop.Add(msg);
                    room.GopBytes = msg.Length;
                }
                else if (room.Gop.Count > 0 && room.GopBytes + msg.Length < MaxGopBytes)
                {
                    room.Gop.Add(msg);
                    room.GopBytes += msg.Length;
                }
                // enqueue while holding the room lock so every viewer gets the same order
                foreach (Viewer v in room.Viewers) Enqueue(v, msg, kind, false);
            }
        }

        // ------------------------------------------------------------------ viewer
        static async Task RunViewer(Room room, WsConn ws, string ip)
        {
            Viewer v = new Viewer();
            v.Ws = ws;
            v.Room = room;
            v.Ip = ip;
            lock (room.Lock)
            {
                room.Viewers.Add(v);
                Enqueue(v, Encoding.UTF8.GetBytes(room.Publisher == null ? "{\"type\":\"offline\"}" : "{\"type\":\"online\"}"), 0, true);
                if (room.Init != null)
                {
                    Enqueue(v, room.Init, 1, false);
                    foreach (byte[] m in room.Gop) Enqueue(v, m, m[0], false);
                }
            }
            try
            {
                while (running && !v.Dead)
                {
                    WsMessage m = await ws.ReceiveAsync(64 * 1024);
                    if (m == null) break;
                }
            }
            catch { }
            Drop(v);
        }

        static void BroadcastText(Room room, string text)
        {
            byte[] b = Encoding.UTF8.GetBytes(text);
            lock (room.Lock)
            {
                foreach (Viewer v in room.Viewers) Enqueue(v, b, 0, true);
            }
        }

        // Called while holding room.Lock
        static void Enqueue(Viewer v, byte[] data, byte kind, bool text)
        {
            bool start = false;
            lock (v.Lock)
            {
                if (v.Dead) return;
                bool add = true;
                if (!text)
                {
                    if (kind == 1 || kind == 2) v.NeedKey = false;
                    if (kind == 3 && v.NeedKey) add = false;
                    else if (v.QBytes > MaxViewerQueue && kind != 1)
                    {
                        // Slow client: drop the backlog and resync from the next keyframe
                        v.Q.Clear();
                        v.QBytes = 0;
                        if (v.Room.Init != null)
                        {
                            Msg im = new Msg();
                            im.Data = v.Room.Init;
                            im.Kind = 1;
                            v.Q.Enqueue(im);
                            v.QBytes += im.Data.Length;
                        }
                        if (kind == 3) { v.NeedKey = true; add = false; }
                    }
                }
                if (add)
                {
                    Msg m = new Msg();
                    m.Data = data;
                    m.Text = text;
                    m.Kind = kind;
                    v.Q.Enqueue(m);
                    v.QBytes += data.Length;
                }
                if (!v.Sending && v.Q.Count > 0) { v.Sending = true; start = true; }
            }
            if (start)
            {
                Task t = Task.Run(new Func<Task>(delegate { return Pump(v); }));
                GC.KeepAlive(t);
            }
        }

        static async Task Pump(Viewer v)
        {
            try
            {
                while (true)
                {
                    Msg m;
                    lock (v.Lock)
                    {
                        if (v.Dead || v.Q.Count == 0) { v.Sending = false; return; }
                        m = v.Q.Dequeue();
                        v.QBytes -= m.Data.Length;
                    }
                    await v.Ws.SendAsync(m.Data, m.Text);
                    if (!m.Text) Interlocked.Add(ref v.Room.BytesOut, m.Data.Length);
                }
            }
            catch
            {
                lock (v.Lock) { v.Sending = false; }
                Drop(v);
            }
        }

        static void Drop(Viewer v)
        {
            lock (v.Room.Lock) { v.Room.Viewers.Remove(v); }
            lock (v.Lock)
            {
                v.Dead = true;
                v.Q.Clear();
                v.QBytes = 0;
            }
            v.Ws.Abort();
        }

        static void PingAll()
        {
            foreach (Room r in rooms.Values)
            {
                Viewer[] vs;
                lock (r.Lock) { vs = r.Viewers.ToArray(); }
                foreach (Viewer v in vs)
                {
                    Viewer vv = v;
                    v.Ws.PingAsync().ContinueWith(delegate (Task t) { if (t.IsFaulted) Drop(vv); });
                }
            }
        }

        // ------------------------------------------------------------------ status
        public static string StatusJson()
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"studentUrl\":\"").Append(Esc(studentUrl)).Append("\",\"rooms\":[");
            bool first = true;
            foreach (Room r in rooms.Values)
            {
                int viewers; bool online; string pip;
                lock (r.Lock) { viewers = r.Viewers.Count; online = r.Publisher != null; pip = r.PublisherIp; }
                if (!first) sb.Append(',');
                first = false;
                sb.Append("{\"name\":\"").Append(Esc(r.Name)).Append("\",\"online\":").Append(online ? "true" : "false")
                  .Append(",\"publisher\":\"").Append(Esc(pip)).Append("\",\"viewers\":").Append(viewers)
                  .Append(",\"bytesIn\":").Append(Interlocked.Read(ref r.BytesIn))
                  .Append(",\"bytesOut\":").Append(Interlocked.Read(ref r.BytesOut)).Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        static string Esc(string s)
        {
            return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}
