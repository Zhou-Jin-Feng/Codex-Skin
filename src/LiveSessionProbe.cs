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
    // A fast, read-only health check of the recorded skin session, done in
    // process instead of through a PowerShell status read. It only ever answers
    // "certainly healthy" or "unknown": callers fall back to the full status read
    // whenever any check fails, and the apply script still verifies the injector
    // identity itself before touching the renderer.
    internal static class LiveSessionProbe
    {
        private static readonly Regex BrowserIdPattern = new Regex("^[A-Za-z0-9._-]{1,200}$", RegexOptions.CultureInvariant);
        private const int CdpTimeoutMilliseconds = 800;
        private static readonly string[] BaseRuntimeFiles = {
            @"scripts\injector.mjs", @"assets\renderer-inject.js", @"assets\dream-skin.css"
        };
        private static readonly string[] ExtendedRuntimeFiles = {
            @"assets\selectors.json", @"assets\safe-css-validator.mjs", @"assets\theme-package-validator.mjs",
            @"scripts\image-metadata.mjs", @"scripts\video-decode-probe.mjs", @"scripts\validate-video-file.mjs"
        };

        public static bool IsHealthy(string skillRoot)
        {
            return IsHealthy(Path.Combine(ManagerPaths.StateRoot, "state.json"), skillRoot);
        }

        internal static bool IsHealthy(string statePath, string skillRoot)
        {
            try
            {
                if (!File.Exists(statePath)) return false;
                Dictionary<string, object> state = new JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(File.ReadAllText(statePath, Encoding.UTF8));
                if (state == null) return false;
                object connectionOnly;
                if (state.TryGetValue("connectionOnly", out connectionOnly) && connectionOnly is bool && (bool)connectionOnly)
                    return false;
                int port = ReadInt(state, "port");
                int injectorPid = ReadInt(state, "injectorPid");
                string browserId = ReadString(state, "browserId");
                string recordedStart = ReadString(state, "injectorStartedAt");
                if (port < 1024 || port > 65535 || injectorPid <= 0 || !BrowserIdPattern.IsMatch(browserId) ||
                    string.IsNullOrWhiteSpace(recordedStart))
                    return false;
                return RuntimeMatches(skillRoot, ReadString(state, "injectorPath"), ReadString(state, "runtimeFingerprint")) &&
                    InjectorMatches(injectorPid, recordedStart) && BrowserMatches(port, browserId);
            }
            catch
            {
                return false;
            }
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
