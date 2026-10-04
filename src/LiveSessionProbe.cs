using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace CodexDreamSkinManager
{
    internal enum LiveSessionState
    {
        // Nothing can be concluded; callers take the full PowerShell path.
        Unknown,
        // Recorded injector and browser session verified end to end.
        Healthy,
        // Nothing listens on the recorded debugging port.
        BrowserUnreachable
    }

    internal sealed class LiveSessionReport
    {
        public LiveSessionState State = LiveSessionState.Unknown;
        // Null when the Codex processes could not be inspected.
        public bool? CodexRunning;

        // Codex is open without the skin's debugging endpoint, so connecting
        // requires a restart; a live apply or a separate check cannot succeed.
        public bool RestartCertain
        {
            get { return State == LiveSessionState.BrowserUnreachable && CodexRunning == true; }
        }
    }

    // A fast, read-only probe of the recorded skin session, done in process
    // instead of through a PowerShell status read. Its conclusions are only
    // shortcuts: anything inconclusive is Unknown so callers take the full path,
    // and the scripts still verify identities themselves before acting.
    internal static class LiveSessionProbe
    {
        private static readonly Regex BrowserIdPattern = new Regex("^[A-Za-z0-9._-]{1,200}$", RegexOptions.CultureInvariant);
        private const int CdpTimeoutMilliseconds = 800;
        private const int DefaultPort = 9335;
        private static readonly string[] BaseRuntimeFiles = {
            @"scripts\injector.mjs", @"assets\renderer-inject.js", @"assets\dream-skin.css"
        };
        private static readonly string[] ExtendedRuntimeFiles = {
            @"assets\selectors.json", @"assets\safe-css-validator.mjs", @"assets\theme-package-validator.mjs",
            @"scripts\image-metadata.mjs", @"scripts\video-decode-probe.mjs", @"scripts\validate-video-file.mjs"
        };

        public static bool IsHealthy(string skillRoot)
        {
            return Probe(skillRoot).State == LiveSessionState.Healthy;
        }

        public static LiveSessionReport Probe(string skillRoot)
        {
            return Probe(Path.Combine(ManagerPaths.StateRoot, "state.json"), skillRoot);
        }

        internal static LiveSessionReport Probe(string statePath, string skillRoot)
        {
            LiveSessionReport report = new LiveSessionReport();
            try
            {
                // Shortcuts apply only to a real installed runtime; a layout
                // without one (such as a test fixture) always takes the full path.
                if (ComputeRuntimeFingerprint(skillRoot).Length == 0) return report;
                Dictionary<string, object> state = null;
                if (File.Exists(statePath))
                    state = new JavaScriptSerializer()
                        .Deserialize<Dictionary<string, object>>(File.ReadAllText(statePath, Encoding.UTF8));
                int port = state == null ? 0 : ReadInt(state, "port");
                if (port < 1024 || port > 65535) port = DefaultPort;
                report.CodexRunning = DetectCodexRunning();
                if (state != null && IsVerifiedSession(state, port, skillRoot))
                {
                    report.State = LiveSessionState.Healthy;
                    return report;
                }
                // Any listener, even an unverified one, is left for the startup
                // script to judge: it may be a restarted skinned Codex.
                if (!IsPortListening(port)) report.State = LiveSessionState.BrowserUnreachable;
            }
            catch
            {
                report.State = LiveSessionState.Unknown;
            }
            return report;
        }

        private static bool IsVerifiedSession(Dictionary<string, object> state, int port, string skillRoot)
        {
            object connectionOnly;
            if (state.TryGetValue("connectionOnly", out connectionOnly) && connectionOnly is bool && (bool)connectionOnly)
                return false;
            int injectorPid = ReadInt(state, "injectorPid");
            string browserId = ReadString(state, "browserId");
            string recordedStart = ReadString(state, "injectorStartedAt");
            if (port != ReadInt(state, "port") || injectorPid <= 0 || !BrowserIdPattern.IsMatch(browserId) ||
                string.IsNullOrWhiteSpace(recordedStart))
                return false;
            return RuntimeMatches(skillRoot, ReadString(state, "injectorPath"), ReadString(state, "runtimeFingerprint")) &&
                InjectorMatches(injectorPid, recordedStart) && BrowserMatches(port, browserId);
        }

        // Reads the TCP listener table instead of connecting: Windows retries a
        // refused loopback connection for about two seconds, so a connect probe
        // with a short timeout cannot tell "nothing listens" from "slow".
        private static bool IsPortListening(int port)
        {
            foreach (IPEndPoint listener in System.Net.NetworkInformation.IPGlobalProperties
                .GetIPGlobalProperties().GetActiveTcpListeners())
            {
                if (listener.Port == port) return true;
            }
            return false;
        }

        // True when an OpenAI Codex Store package process is running, false when
        // none is, and null when a candidate process could not be inspected.
        private static bool? DetectCodexRunning()
        {
            Process[] candidates = Process.GetProcessesByName("ChatGPT");
            bool uninspectable = false;
            try
            {
                foreach (Process process in candidates)
                {
                    string path = ProcessImagePath(process.Id);
                    if (path == null) { uninspectable = true; continue; }
                    if (path.IndexOf(@"\WindowsApps\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0) return true;
                }
            }
            finally
            {
                foreach (Process process in candidates) process.Dispose();
            }
            if (uninspectable) return null;
            return false;
        }

        private static string ProcessImagePath(int processId)
        {
            IntPtr handle = NativeMethods.OpenProcess(NativeMethods.ProcessQueryLimitedInformation, false, processId);
            if (handle == IntPtr.Zero) return null;
            try
            {
                StringBuilder buffer = new StringBuilder(1024);
                int size = buffer.Capacity;
                return NativeMethods.QueryFullProcessImageName(handle, 0, buffer, ref size) ? buffer.ToString(0, size) : null;
            }
            finally
            {
                NativeMethods.CloseHandle(handle);
            }
        }

        private static class NativeMethods
        {
            internal const int ProcessQueryLimitedInformation = 0x1000;

            [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
            internal static extern IntPtr OpenProcess(int access, bool inheritHandle, int processId);

            [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true,
                CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
            internal static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);

            [System.Runtime.InteropServices.DllImport("kernel32.dll")]
            internal static extern bool CloseHandle(IntPtr handle);
        }

        // Mirrors Test-DreamSkinRuntimeCurrent: the running injector must come
        // from a runtime identical to the one this manager would start.
        private static bool RuntimeMatches(string skillRoot, string recordedInjectorPath, string recordedFingerprint)
        {
            if (string.IsNullOrWhiteSpace(skillRoot) || string.IsNullOrWhiteSpace(recordedInjectorPath) ||
                string.IsNullOrWhiteSpace(recordedFingerprint))
                return false;
            string recordedInjector = Path.GetFullPath(recordedInjectorPath);
            string recordedRoot = Path.GetDirectoryName(Path.GetDirectoryName(recordedInjector));
            if (string.IsNullOrEmpty(recordedRoot) || !string.Equals(recordedInjector,
                Path.GetFullPath(Path.Combine(recordedRoot, "scripts", "injector.mjs")), StringComparison.OrdinalIgnoreCase))
                return false;
            string current = ComputeRuntimeFingerprint(skillRoot);
            if (current.Length == 0 || !string.Equals(current, recordedFingerprint, StringComparison.OrdinalIgnoreCase))
                return false;
            string recorded = string.Equals(Path.GetFullPath(skillRoot).TrimEnd('\\'), recordedRoot.TrimEnd('\\'),
                StringComparison.OrdinalIgnoreCase) ? current : ComputeRuntimeFingerprint(recordedRoot);
            return string.Equals(recorded, recordedFingerprint, StringComparison.OrdinalIgnoreCase);
        }

        // Same algorithm as Get-DreamSkinRuntimeFingerprint in runtime-version.ps1.
        internal static string ComputeRuntimeFingerprint(string skillRoot)
        {
            try
            {
                List<string> files = new List<string>(BaseRuntimeFiles);
                if (Array.TrueForAll(ExtendedRuntimeFiles, relative => File.Exists(Path.Combine(skillRoot, relative))))
                    files.AddRange(ExtendedRuntimeFiles);
                List<string> hashes = new List<string>();
                foreach (string relative in files)
                {
                    string path = Path.Combine(skillRoot, relative);
                    if (!File.Exists(path)) return "";
                    using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                        hashes.Add(Sha256Hex(stream));
                }
                if (hashes.Count < 3) return "";
                using (MemoryStream joined = new MemoryStream(Encoding.UTF8.GetBytes(string.Join("|", hashes.ToArray()))))
                    return Sha256Hex(joined);
            }
            catch
            {
                return "";
            }
        }

        private static string Sha256Hex(Stream stream)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] digest = sha.ComputeHash(stream);
                StringBuilder hex = new StringBuilder(digest.Length * 2);
                foreach (byte value in digest) hex.Append(value.ToString("x2", CultureInfo.InvariantCulture));
                return hex.ToString();
            }
        }

        private static bool InjectorMatches(int processId, string recordedStart)
        {
            DateTime recorded;
            if (!DateTime.TryParse(recordedStart, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out recorded))
                return false;
            try
            {
                using (Process process = Process.GetProcessById(processId))
                {
                    if (!string.Equals(process.ProcessName, "node", StringComparison.OrdinalIgnoreCase)) return false;
                    // Same start time rules out a reused PID; sub-millisecond
                    // differences come only from the ISO round trip.
                    return Math.Abs((process.StartTime.ToUniversalTime() - recorded).TotalMilliseconds) < 1;
                }
            }
            catch (ArgumentException)
            {
                return false;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                return false;
            }
        }

        private static bool BrowserMatches(int port, string browserId)
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(new Uri(string.Format(CultureInfo.InvariantCulture,
                "http://127.0.0.1:{0}/json/version", port)));
            request.Proxy = null;
            request.Timeout = CdpTimeoutMilliseconds;
            request.ReadWriteTimeout = CdpTimeoutMilliseconds;
            request.AllowAutoRedirect = false;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                if (response.StatusCode != HttpStatusCode.OK) return false;
                using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    char[] buffer = new char[16384];
                    int read = reader.ReadBlock(buffer, 0, buffer.Length);
                    Dictionary<string, object> version = new JavaScriptSerializer()
                        .Deserialize<Dictionary<string, object>>(new string(buffer, 0, read));
                    Uri debugger;
                    if (version == null || !Uri.TryCreate(ReadString(version, "webSocketDebuggerUrl"), UriKind.Absolute, out debugger))
                        return false;
                    return debugger.Scheme == "ws" && debugger.Host == "127.0.0.1" && debugger.Port == port &&
                        string.IsNullOrEmpty(debugger.Query) &&
                        string.Equals(debugger.AbsolutePath, "/devtools/browser/" + browserId, StringComparison.Ordinal);
                }
            }
        }

        private static int ReadInt(Dictionary<string, object> data, string key)
        {
            object value;
            int parsed;
            return data.TryGetValue(key, out value) && value != null &&
                int.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out parsed) ? parsed : 0;
        }

        private static string ReadString(Dictionary<string, object> data, string key)
        {
            object value;
            return data.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : "";
        }
    }
}
