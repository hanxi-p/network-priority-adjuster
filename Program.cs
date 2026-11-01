using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("网络优先级")]
[assembly: AssemblyDescription("拖动网卡排序，在本机网页保存 IPv4 / IPv6 优先级")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Program
{
    static readonly object NetworkLock = new object();
    static JavaScriptSerializer Json { get { return new JavaScriptSerializer(); } }
    static TcpListener Listener;
    static NotifyIcon Tray;
    static volatile bool Stopping;
    static bool ReadOnly;
    static string Token, Origin, Url, SessionFile;
    static string Html, Script;
    static byte[] IconBytes;
    static Mutex Instance;

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        ReadOnly = Array.IndexOf(args, "--readonly") >= 0;
        bool noBrowser = Array.IndexOf(args, "--no-browser") >= 0;
        string runtime = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NetworkPriority");
        int sessionArg = Array.IndexOf(args, "--session-file");
        SessionFile = sessionArg >= 0 && sessionArg + 1 < args.Length ? Path.GetFullPath(args[sessionArg + 1]) : Path.Combine(runtime, ReadOnly ? "preview.json" : "session.json");
        bool admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        if (!ReadOnly && !admin)
        {
            try { Process.Start(new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute = true, Verb = "runas", WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory }); }
            catch (System.ComponentModel.Win32Exception) { MessageBox.Show("修改网络优先级需要管理员权限。再次打开程序并允许权限后即可使用。", "网络优先级", MessageBoxButtons.OK, MessageBoxIcon.Information); }
            return;
        }
        bool created;
        Instance = new Mutex(true, "Local\\NetworkPriority-v1" + (ReadOnly ? "-preview" : ""), out created);
        if (!created)
        {
            try
            {
                var session = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(SessionFile, Encoding.UTF8));
                string existingUrl = (string)session["url"];
                Uri existingUri;
                if (!Uri.TryCreate(existingUrl, UriKind.Absolute, out existingUri) || existingUri.Scheme != "http" || existingUri.Host != "127.0.0.1" || existingUri.AbsolutePath != "/" || existingUri.UserInfo.Length != 0 || !System.Text.RegularExpressions.Regex.IsMatch(existingUri.Fragment, "^#[0-9a-f]{64}$")) throw new InvalidDataException();
                Process.Start(new ProcessStartInfo(existingUrl) { UseShellExecute = true });
            }
            catch { MessageBox.Show("程序已在运行，请从系统托盘打开控制页。", "网络优先级"); }
            Instance.Dispose();
            return;
        }
        try
        {
            Html = ReadResource("index.html");
            Script = ReadResource("network.ps1");
            using (Stream icon = Assembly.GetExecutingAssembly().GetManifestResourceStream("network.ico"))
            using (var memory = new MemoryStream()) { icon.CopyTo(memory); IconBytes = memory.ToArray(); }
            byte[] random = new byte[32];
            using (var rng = RandomNumberGenerator.Create()) { rng.GetBytes(random); }
            Token = BitConverter.ToString(random).Replace("-", "").ToLowerInvariant();
            Listener = new TcpListener(IPAddress.Loopback, 0);
            Listener.Start(24);
            int port = ((IPEndPoint)Listener.LocalEndpoint).Port;
            Origin = "http://127.0.0.1:" + port;
            Url = Origin + "/#" + Token;
            Directory.CreateDirectory(Path.GetDirectoryName(SessionFile));
            File.WriteAllText(SessionFile, Json.Serialize(new { url = Url, origin = Origin, pid = Process.GetCurrentProcess().Id, readOnly = ReadOnly }), new UTF8Encoding(false));
            ThreadPool.QueueUserWorkItem(delegate { AcceptLoop(); });
            var menu = new ContextMenuStrip();
            menu.Items.Add("打开控制页", null, delegate { OpenBrowser(); });
            menu.Items.Add("退出程序", null, delegate { QueueExit(); });
            using (var iconStream = new MemoryStream(IconBytes))
            using (var icon = new Icon(iconStream))
            {
                Tray = new NotifyIcon { Icon = (Icon)icon.Clone(), Visible = true, Text = "网络优先级" + (ReadOnly ? "（只读预览）" : ""), ContextMenuStrip = menu };
            }
            Tray.DoubleClick += delegate { OpenBrowser(); };
            Application.ApplicationExit += delegate { Shutdown(); };
            if (!noBrowser) OpenBrowser();
            Application.Run();
        }
        catch (Exception e) { MessageBox.Show("无法启动网络优先级：\n" + e.Message, "网络优先级", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { Shutdown(); if (Instance != null) { Instance.ReleaseMutex(); Instance.Dispose(); } }
    }

    static string ReadResource(string name)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        using (var reader = new StreamReader(stream, Encoding.UTF8)) { return reader.ReadToEnd(); }
    }
    static void OpenBrowser()
    {
        try { Process.Start(new ProcessStartInfo(Url) { UseShellExecute = true }); }
        catch { MessageBox.Show("请在浏览器中打开：\n" + Url, "网络优先级"); }
    }
    static void Shutdown()
    {
        if (Stopping) return;
        Stopping = true;
        if (Listener != null) Listener.Stop();
        if (Tray != null) { Tray.Visible = false; Tray.Dispose(); }
        try { if (File.Exists(SessionFile)) File.Delete(SessionFile); } catch { }
    }
    static void AcceptLoop()
    {
        while (!Stopping)
        {
            try { TcpClient client = Listener.AcceptTcpClient(); ThreadPool.QueueUserWorkItem(delegate { Handle(client); }); }
            catch (SocketException) { if (!Stopping) Thread.Sleep(100); }
            catch (ObjectDisposedException) { break; }
        }
    }

    static void Handle(TcpClient client)
    {
        using (client)
        {
            client.ReceiveTimeout = 6000;
            client.SendTimeout = 10000;
            try
            {
                using (NetworkStream stream = client.GetStream())
                {
                    var header = new MemoryStream();
                    int value, ending = 0;
                    while ((value = stream.ReadByte()) >= 0)
                    {
                        header.WriteByte((byte)value);
                        ending = ((ending << 8) | value);
                        if (ending == 0x0D0A0D0A) break;
                        if (header.Length > 16384) { Send(stream, 400, "text/plain", "Request header too large"); return; }
                    }
                    if (ending != 0x0D0A0D0A) return;
                    string[] lines = Encoding.ASCII.GetString(header.ToArray()).Split(new[] { "\r\n" }, StringSplitOptions.None);
                    string[] first = lines[0].Split(' ');
                    if (first.Length != 3) { Send(stream, 400, "text/plain", "Bad request"); return; }
                    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 1; i < lines.Length; i++)
                    {
                        int colon = lines[i].IndexOf(':');
                        if (colon > 0)
                        {
                            string key = lines[i].Substring(0, colon).Trim();
                            if (headers.ContainsKey(key)) { Send(stream, 400, "text/plain", "Duplicate header"); return; }
                            headers.Add(key, lines[i].Substring(colon + 1).Trim());
                        }
                    }
                    string host;
                    if (!headers.TryGetValue("Host", out host) || host != Origin.Substring(7)) { Send(stream, 403, "text/plain", "Invalid host"); return; }
                    if (headers.ContainsKey("Transfer-Encoding")) { Send(stream, 400, "text/plain", "Unsupported request encoding"); return; }
                    string path = first[1].Split('?')[0];
                    if (path == "/" && first[0] == "GET") { Send(stream, 200, "text/html; charset=utf-8", Html); return; }
                    if (path == "/favicon.ico" && first[0] == "GET") { SendBytes(stream, 200, "image/x-icon", IconBytes); return; }
                    string keyValue, requestOrigin;
                    if (!headers.TryGetValue("X-Network-Token", out keyValue) || !SecureEquals(keyValue, Token) || (headers.TryGetValue("Origin", out requestOrigin) && requestOrigin != Origin))
                    { SendJson(stream, 403, new { ok = false, error = "控制页授权已失效，请从 EXE 重新打开。" }); return; }
                    if (path == "/api/state" && first[0] == "GET")
                    {
                        string result = RunNetwork("{\"action\":\"state\"}");
                        var stateResult = Json.Deserialize<Dictionary<string, object>>(result);
                        stateResult["readOnly"] = ReadOnly;
                        SendJson(stream, 200, stateResult); return;
                    }
                    if ((path == "/api/save" || path == "/api/defaults" || path == "/api/plan" || path == "/api/exit") && first[0] == "POST")
                    {
                        if (ReadOnly && path != "/api/plan" && path != "/api/exit") { SendJson(stream, 403, new { ok = false, error = "当前是只读预览。双击 EXE 并允许管理员权限后即可保存。" }); return; }
                        string type;
                        if (!headers.TryGetValue("Content-Type", out type) || !type.StartsWith("application/json", StringComparison.OrdinalIgnoreCase)) { SendJson(stream, 400, new { ok = false, error = "需要 JSON 请求。" }); return; }
                        string lengthText;
                        int length;
                        if (!headers.TryGetValue("Content-Length", out lengthText) || !int.TryParse(lengthText, out length) || length < 2 || length > 32768) { SendJson(stream, 400, new { ok = false, error = "请求内容无效。" }); return; }
                        byte[] body = new byte[length];
                        for (int n = 0; n < length; ) { int count = stream.Read(body, n, length - n); if (count == 0) throw new IOException("Incomplete request"); n += count; }
                        Dictionary<string, object> request;
                        try { request = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(body)); if (request == null) throw new FormatException(); }
                        catch { SendJson(stream, 400, new { ok = false, error = "JSON 请求无效。" }); return; }
                        if (path == "/api/exit")
                        {
                            SendJson(stream, 200, new { ok = true, exiting = true, message = "程序已退出，保留已保存的网络优先级。" });
                            QueueExit(); return;
                        }
                        request["action"] = path.Substring(5);
                        string result = RunNetwork(Json.Serialize(request));
                        var resultObject = Json.Deserialize<Dictionary<string, object>>(result);
                        bool exitAfter = path == "/api/defaults" && resultObject.ContainsKey("ok") && resultObject["ok"] is bool && (bool)resultObject["ok"];
                        if (exitAfter) { resultObject["exiting"] = true; resultObject["message"] = "已恢复 Windows 自动优先级，程序已退出。"; }
                        SendJson(stream, 200, resultObject);
                        if (exitAfter) QueueExit();
                        return;
                    }
                    SendJson(stream, 404, new { ok = false, error = "没有这个接口。" });
                }
            }
            catch { /* A disconnected local browser must not terminate the tray app. */ }
        }
    }
    static bool SecureEquals(string a, string b)
    {
        if (a == null || a.Length != b.Length) return false;
        int difference = 0;
        for (int i = 0; i < a.Length; i++) difference |= a[i] ^ b[i];
        return difference == 0;
    }
    static void QueueExit()
    {
        ThreadPool.QueueUserWorkItem(delegate { Thread.Sleep(400); lock (NetworkLock) { Application.Exit(); } });
    }
    static string RunNetwork(string request)
    {
        lock (NetworkLock)
        {
            try
            {
                var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"));
                start.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(Script));
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                start.RedirectStandardInput = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                start.StandardOutputEncoding = new UTF8Encoding(false);
                start.StandardErrorEncoding = new UTF8Encoding(false);
                using (var process = Process.Start(start))
                {
                    byte[] input = new UTF8Encoding(false).GetBytes(request);
                    process.StandardInput.BaseStream.Write(input, 0, input.Length);
                    process.StandardInput.BaseStream.Flush();
                    process.StandardInput.Close();
                    var outputTask = process.StandardOutput.ReadToEndAsync();
                    var errorTask = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(120000))
                    {
                        try { process.Kill(); } catch { }
                        return Json.Serialize(new { ok = false, error = "系统响应超时。请刷新后检查各接口的实际设置。" });
                    }
                    string output = outputTask.Result.Trim();
                    string errors = errorTask.Result.Trim();
                    if (output.Length == 0) return Json.Serialize(new { ok = false, error = errors.Length > 0 ? errors : "Windows 没有返回接口数据。" });
                    Json.DeserializeObject(output);
                    return output;
                }
            }
            catch (Exception e) { return Json.Serialize(new { ok = false, error = "操作失败：" + e.Message }); }
        }
    }
    static void SendJson(NetworkStream stream, int status, object value) { Send(stream, status, "application/json; charset=utf-8", Json.Serialize(value)); }
    static void Send(NetworkStream stream, int status, string type, string body) { SendBytes(stream, status, type, Encoding.UTF8.GetBytes(body)); }
    static void SendBytes(NetworkStream stream, int status, string type, byte[] body)
    {
        string reason = status == 200 ? "OK" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : "Bad Request";
        string headers = "HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n";
        byte[] head = Encoding.ASCII.GetBytes(headers);
        stream.Write(head, 0, head.Length);
        stream.Write(body, 0, body.Length);
        stream.Flush();
    }
}
