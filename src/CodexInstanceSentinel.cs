using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace CodexDreamSkinManager
{
    internal sealed class CodexLaunch
    {
        public int ProcessId;
        public string ExecutablePath = "";
        public string CommandLine = "";
        public DateTime CreatedUtc;
    }

    // Folds Codex windows opened outside the skin -- a notification click, the
    // Start menu, a codex:// link -- into the running skinned instance. Such a
    // launch uses the default profile, so Electron's single-instance lock (keyed
    // by user-data-dir) never sees the skinned instance and a second, unskinned
    // window opens. The sentinel stops that fresh process and relaunches its
    // arguments with the skin profile, which hands them to the skinned instance.
    internal sealed class CodexInstanceSentinel : IDisposable
    {
        private const string CodexPackageMarker = @"\WindowsApps\OpenAI.Codex_";
        private const string CodexExecutableSuffix = @"\app\ChatGPT.exe";
        private const int RecentLaunchSeconds = 15;
        private const int RedirectBurstLimit = 3;
        private const int FocusWaitMilliseconds = 1500;
        private static readonly TimeSpan RedirectBurstWindow = TimeSpan.FromSeconds(30);
        private static readonly TimeSpan BurstCooldown = TimeSpan.FromMinutes(5);
        private static readonly Regex ToastActivation =
            new Regex("^type=click&tag=[A-Za-z0-9._-]{1,128}$", RegexOptions.CultureInvariant);

        private readonly Func<bool> isEnabled;
        private readonly object gate = new object();
        private readonly Queue<DateTime> recentRedirects = new Queue<DateTime>();
        private readonly HashSet<int> forwardedProcessIds = new HashSet<int>();
        private ManagementEventWatcher watcher;
        private DateTime pausedUntilUtc = DateTime.MinValue;
        private bool forwardingUnsupported;
        private bool disposed;

        private CodexInstanceSentinel(Func<bool> isEnabled)
        {
            this.isEnabled = isEnabled ?? (() => true);
        }

        // Returns null when process creation events are unavailable; the
        // manager then simply runs without the sentinel.
        public static CodexInstanceSentinel TryStart(Func<bool> isEnabled)
        {
            CodexInstanceSentinel sentinel = new CodexInstanceSentinel(isEnabled);
            try
            {
                // WMI polls once a second for this intrinsic event; it needs no
                // administrator rights, unlike Win32_ProcessStartTrace.
                WqlEventQuery query = new WqlEventQuery("__InstanceCreationEvent", TimeSpan.FromSeconds(1),
                    "TargetInstance ISA 'Win32_Process' AND TargetInstance.Name = 'ChatGPT.exe'");
                sentinel.watcher = new ManagementEventWatcher(query);
                sentinel.watcher.EventArrived += sentinel.OnEventArrived;
                sentinel.watcher.Start();
                SentinelLog.Write("started");
                return sentinel;
            }
            catch (Exception ex)
            {
                SentinelLog.Write("unavailable: " + ex.Message);
                sentinel.Dispose();
                return null;
            }
        }

        public void Dispose()
        {
            lock (gate) disposed = true;
            ManagementEventWatcher current = watcher;
            watcher = null;
            if (current == null) return;
            try { current.Stop(); } catch { }
            current.Dispose();
        }

        private void OnEventArrived(object sender, EventArrivedEventArgs e)
        {
            CodexLaunch launch;
            try
            {
                ManagementBaseObject target = (ManagementBaseObject)e.NewEvent["TargetInstance"];
                launch = new CodexLaunch
                {
                    ProcessId = Convert.ToInt32(target["ProcessId"], CultureInfo.InvariantCulture),
                    ExecutablePath = Convert.ToString(target["ExecutablePath"], CultureInfo.InvariantCulture) ?? "",
                    CommandLine = Convert.ToString(target["CommandLine"], CultureInfo.InvariantCulture) ?? "",
                    CreatedUtc = ManagementDateTimeConverter.ToDateTime(
                        Convert.ToString(target["CreationDate"], CultureInfo.InvariantCulture)).ToUniversalTime()
                };
            }
            catch (Exception ex)
            {
                SentinelLog.Write("unreadable process event: " + ex.Message);
                return;
            }
            // Leave the WMI callback thread at once; handling is serialized.
            ThreadPool.QueueUserWorkItem(delegate { Handle(launch); });
        }

        private void Handle(CodexLaunch launch)
        {
            lock (gate)
            {
                if (disposed) return;
                try
                {
                    HandleLocked(launch);
                }
                catch (Exception ex)
                {
                    // A background failure must never take the manager down.
                    SentinelLog.Write("PID " + launch.ProcessId + " failed: " + ex.Message);
                }
            }
        }

        private void HandleLocked(CodexLaunch launch)
        {
            string forwardArguments = ClassifyForwardArguments(launch.ExecutablePath, launch.CommandLine);
            bool ownForward = forwardedProcessIds.Remove(launch.ProcessId);
            if (forwardArguments == null) return;
            if (!isEnabled())
            {
                SentinelLog.Write("PID " + launch.ProcessId + " left alone: merging is turned off");
                return;
            }
            if ((DateTime.UtcNow - launch.CreatedUtc).TotalSeconds > RecentLaunchSeconds) return;

            string profile = SkinProfilePath();
            int skinnedProcessId = FindSkinnedInstance(profile);
            if (skinnedProcessId == 0)
            {
                SentinelLog.Write("PID " + launch.ProcessId + " left alone: no skinned Codex is running");
                return;
            }
            if (!ownForward && !TryReserveRedirect(DateTime.UtcNow)) return;

            // Read the package identity before the process goes away.
            string appUserModelId = ReadAppUserModelId(launch.ProcessId) ?? ReadAppUserModelId(skinnedProcessId);
            if (!StopLaunch(launch))
            {
                SentinelLog.Write("PID " + launch.ProcessId + " could not be stopped safely; left running");
                return;
            }
            if (ownForward)
            {
                // The relaunch itself came back without the skin profile (a
                // Codex build that rewrites activation arguments): only focus
                // from now on instead of looping.
                forwardingUnsupported = true;
                SentinelLog.Write("PID " + launch.ProcessId + " was our forward but lost the skin profile; " +
                    "switching to focus-only for this session");
            }
            else if (!forwardingUnsupported)
            {
                Forward(launch.ExecutablePath, appUserModelId, profile, forwardArguments);
            }
            bool focused = FocusSkinnedWindow(skinnedProcessId);
            SentinelLog.Write("PID " + launch.ProcessId + " (" + (forwardArguments.Length == 0 ? "no arguments" : forwardArguments) +
                ") merged into skinned PID " + skinnedProcessId + (focused ? "; window focused" : "; window not focused"));
        }

        // Returns the arguments worth handing to the skinned instance, or null
        // when this process must be left alone: not a Codex Store main process,
        // already bound to an explicit profile, or carrying unknown switches
        // (updater or helper processes).
        internal static string ClassifyForwardArguments(string executablePath, string commandLine)
        {
            if (string.IsNullOrEmpty(executablePath) ||
                executablePath.IndexOf(CodexPackageMarker, StringComparison.OrdinalIgnoreCase) < 0 ||
                !executablePath.EndsWith(CodexExecutableSuffix, StringComparison.OrdinalIgnoreCase))
                return null;
            string arguments = ArgumentsAfterExecutable(commandLine);
            if (arguments == null) return null;
            if (arguments.Length == 0) return "";
            if (ToastActivation.IsMatch(arguments)) return arguments;
            string link = arguments.Length > 1 && arguments[0] == '"' && arguments[arguments.Length - 1] == '"'
                ? arguments.Substring(1, arguments.Length - 2) : arguments;
            if (link.StartsWith("codex://", StringComparison.OrdinalIgnoreCase) &&
                link.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
                return arguments;
            return null;
        }

        internal static string ArgumentsAfterExecutable(string commandLine)
        {
            if (string.IsNullOrWhiteSpace(commandLine)) return null;
            string value = commandLine.Trim();
            if (value[0] == '"')
            {
                int closing = value.IndexOf('"', 1);
                return closing < 0 ? null : value.Substring(closing + 1).Trim();
            }
            int space = value.IndexOf(' ');
            return space < 0 ? "" : value.Substring(space + 1).Trim();
        }

        internal static string ReadUserDataDir(string commandLine)
        {
            if (string.IsNullOrEmpty(commandLine)) return null;
            Match quotedToken = Regex.Match(commandLine, "\"--user-data-dir=(?<value>[^\"]*)\"");
            if (quotedToken.Success) return quotedToken.Groups["value"].Value;
            Match plain = Regex.Match(commandLine, "(?:^|\\s)--user-data-dir=(?<value>\"[^\"]*\"|\\S+)");
            return plain.Success ? plain.Groups["value"].Value.Trim('"') : null;
        }

        internal static bool SamePath(string left, string right)
        {
            if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
            try
            {
                return string.Equals(Path.GetFullPath(left).TrimEnd('\\'), Path.GetFullPath(right).TrimEnd('\\'),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        // The profile of the current skin session, as recorded by the start script.
        private static string SkinProfilePath()
        {
            string stateRoot = ManagerPaths.StateRoot;
            try
            {
                string statePath = Path.Combine(stateRoot, "state.json");
                if (File.Exists(statePath))
                {
                    Dictionary<string, object> state = new JavaScriptSerializer()
                        .Deserialize<Dictionary<string, object>>(File.ReadAllText(statePath, Encoding.UTF8));
                    object value;
                    string recorded = state != null && state.TryGetValue("profilePath", out value)
                        ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
                    if (!string.IsNullOrWhiteSpace(recorded) && Path.IsPathRooted(recorded)) return recorded;
                }
            }
            catch
            {
            }
            return Path.Combine(stateRoot, "cdp-profile");
        }

        private static int FindSkinnedInstance(string profile)
        {
            using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine, ExecutablePath FROM Win32_Process WHERE Name = 'ChatGPT.exe'"))
            using (ManagementObjectCollection processes = searcher.Get())
            {
                foreach (ManagementBaseObject process in processes)
                {
                    using (process)
                    {
                        string commandLine = Convert.ToString(process["CommandLine"], CultureInfo.InvariantCulture) ?? "";
                        string path = Convert.ToString(process["ExecutablePath"], CultureInfo.InvariantCulture) ?? "";
                        if (commandLine.IndexOf("--type=", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                        if (path.IndexOf(CodexPackageMarker, StringComparison.OrdinalIgnoreCase) < 0) continue;
                        if (SamePath(ReadUserDataDir(commandLine), profile))
                            return Convert.ToInt32(process["ProcessId"], CultureInfo.InvariantCulture);
                    }
                }
            }
            return 0;
        }

        private bool TryReserveRedirect(DateTime nowUtc)
        {
            if (nowUtc < pausedUntilUtc) return false;
            while (recentRedirects.Count > 0 && nowUtc - recentRedirects.Peek() > RedirectBurstWindow)
                recentRedirects.Dequeue();
            if (recentRedirects.Count >= RedirectBurstLimit)
            {
                pausedUntilUtc = nowUtc + BurstCooldown;
                SentinelLog.Write("too many Codex launches in a row; merging paused for 5 minutes");
                return false;
            }
            recentRedirects.Enqueue(nowUtc);
            return true;
        }

        // Stops only the exact process from the event (same image and start
        // time, so a reused PID is never touched) and its fresh helpers.
        private static bool StopLaunch(CodexLaunch launch)
        {
            try
            {
                using (Process process = Process.GetProcessById(launch.ProcessId))
                {
                    if (Math.Abs((process.StartTime.ToUniversalTime() - launch.CreatedUtc).TotalSeconds) > 2) return false;
                    if (!SamePath(ProcessImagePath(process.Id), launch.ExecutablePath)) return false;
                    process.Kill();
                    process.WaitForExit(3000);
                }
            }
            catch (ArgumentException)
            {
                // Already gone: nothing left to stop.
            }
            using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(string.Format(CultureInfo.InvariantCulture,
                "SELECT ProcessId, ExecutablePath FROM Win32_Process WHERE Name = 'ChatGPT.exe' AND ParentProcessId = {0}",
                launch.ProcessId)))
            using (ManagementObjectCollection children = searcher.Get())
            {
                foreach (ManagementBaseObject child in children)
                {
                    using (child)
                    {
                        if (!SamePath(Convert.ToString(child["ExecutablePath"], CultureInfo.InvariantCulture), launch.ExecutablePath))
                            continue;
                        try
                        {
                            using (Process helper = Process.GetProcessById(Convert.ToInt32(child["ProcessId"], CultureInfo.InvariantCulture)))
                                helper.Kill();
                        }
                        catch { }
                    }
                }
            }
            return true;
        }

        // Relaunches the arguments with the skin profile. Electron's single-
        // instance lock then hands them to the skinned instance and the new
        // process exits; package activation keeps the Store identity, and a
        // direct start is the fallback when activation is unavailable.
        private void Forward(string executablePath, string appUserModelId, string profile, string forwardArguments)
        {
            string arguments = QuoteArgument("--user-data-dir=" + profile) +
                (forwardArguments.Length == 0 ? "" : " " + forwardArguments);
            if (!string.IsNullOrEmpty(appUserModelId))
            {
                try
                {
                    uint processId = PackageActivation.Activate(appUserModelId, arguments);
                    if (processId > 0) forwardedProcessIds.Add((int)processId);
                    return;
                }
                catch (Exception ex)
                {
                    SentinelLog.Write("package activation failed: " + ex.Message + "; trying a direct start");
                }
            }
            try
            {
                ProcessStartInfo info = new ProcessStartInfo(executablePath, arguments);
                info.UseShellExecute = false;
                using (Process process = Process.Start(info))
                    if (process != null) forwardedProcessIds.Add(process.Id);
            }
            catch (Exception ex)
            {
                SentinelLog.Write("direct start failed: " + ex.Message + "; focusing only");
            }
        }

        // CommandLineToArgvW-compatible quoting for a single argument.
        internal static string QuoteArgument(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
            StringBuilder quoted = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { backslashes++; continue; }
                if (character == '"') quoted.Append('\\', backslashes * 2 + 1);
                else quoted.Append('\\', backslashes);
                backslashes = 0;
                quoted.Append(character);
            }
            quoted.Append('\\', backslashes * 2);
            return quoted.Append('"').ToString();
        }

        private static bool FocusSkinnedWindow(int processId)
        {
            Stopwatch clock = Stopwatch.StartNew();
            while (true)
            {
                IntPtr window = IntPtr.Zero;
                try
                {
                    using (Process process = Process.GetProcessById(processId))
                        window = process.MainWindowHandle;
                }
                catch (ArgumentException)
                {
                    return false;
                }
                if (window != IntPtr.Zero) return NativeMethods.BringToFront(window);
                if (clock.ElapsedMilliseconds >= FocusWaitMilliseconds) return false;
                Thread.Sleep(150);
            }
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

        private static string ReadAppUserModelId(int processId)
        {
            IntPtr handle = NativeMethods.OpenProcess(NativeMethods.ProcessQueryLimitedInformation, false, processId);
            if (handle == IntPtr.Zero) return null;
            try
            {
                int length = 0;
                if (NativeMethods.GetApplicationUserModelId(handle, ref length, null) != NativeMethods.ErrorInsufficientBuffer ||
                    length <= 0)
                    return null;
                StringBuilder buffer = new StringBuilder(length);
                return NativeMethods.GetApplicationUserModelId(handle, ref length, buffer) == 0 ? buffer.ToString() : null;
            }
            finally
            {
                NativeMethods.CloseHandle(handle);
            }
        }

        private static class PackageActivation
        {
            [ComImport]
            [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
            [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            private interface IApplicationActivationManager
            {
                [PreserveSig]
                int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                    [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
            }

            [ComImport]
            [Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
            private class ApplicationActivationManager
            {
            }

            public static uint Activate(string appUserModelId, string arguments)
            {
                IApplicationActivationManager manager = (IApplicationActivationManager)new ApplicationActivationManager();
                try
                {
                    uint processId;
                    Marshal.ThrowExceptionForHR(manager.ActivateApplication(appUserModelId, arguments, 0, out processId));
                    return processId;
                }
                finally
                {
                    Marshal.FinalReleaseComObject(manager);
                }
            }
        }

        private static class NativeMethods
        {
            internal const int ProcessQueryLimitedInformation = 0x1000;
            internal const int ErrorInsufficientBuffer = 122;
            private const int ShowRestore = 9;

            [DllImport("kernel32.dll", SetLastError = true)]
            internal static extern IntPtr OpenProcess(int access, bool inheritHandle, int processId);

            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
            internal static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);

            [DllImport("kernel32.dll")]
            internal static extern bool CloseHandle(IntPtr handle);

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
            internal static extern int GetApplicationUserModelId(IntPtr process, ref int length, StringBuilder applicationUserModelId);

            [DllImport("user32.dll")]
            private static extern bool IsIconic(IntPtr window);

            [DllImport("user32.dll")]
            private static extern bool ShowWindow(IntPtr window, int command);

            [DllImport("user32.dll")]
            private static extern bool SetForegroundWindow(IntPtr window);

            [DllImport("user32.dll")]
            private static extern IntPtr GetForegroundWindow();

            [DllImport("user32.dll")]
            private static extern int GetWindowThreadProcessId(IntPtr window, IntPtr processId);

            [DllImport("kernel32.dll")]
            private static extern int GetCurrentThreadId();

            [DllImport("user32.dll")]
            private static extern bool AttachThreadInput(int attach, int attachTo, bool doAttach);

            // A background process may not take the foreground by itself;
            // sharing input with the current foreground thread lets it.
            internal static bool BringToFront(IntPtr window)
            {
                if (IsIconic(window)) ShowWindow(window, ShowRestore);
                if (SetForegroundWindow(window)) return true;
                int foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
                int currentThread = GetCurrentThreadId();
                bool attached = foregroundThread != 0 && foregroundThread != currentThread &&
                    AttachThreadInput(currentThread, foregroundThread, true);
                try
                {
                    return SetForegroundWindow(window);
                }
                finally
                {
                    if (attached) AttachThreadInput(currentThread, foregroundThread, false);
                }
            }
        }
    }

    // sentinel.log under the state root: one line per decision, so a merge (or
    // a launch deliberately left alone) can be explained afterwards.
    internal static class SentinelLog
    {
        private const long MaxBytes = 256 * 1024;
        private static readonly object Gate = new object();

        public static void Write(string message)
        {
            try
            {
                string directory = ManagerPaths.StateRoot;
                if (!Directory.Exists(directory)) return;
                string path = Path.Combine(directory, "sentinel.log");
                string line = DateTimeOffset.Now.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz", CultureInfo.InvariantCulture) +
                    " " + (message ?? "").Replace('\r', ' ').Replace('\n', ' ') + "\r\n";
                lock (Gate)
                {
                    FileInfo existing = new FileInfo(path);
                    if (existing.Exists && existing.Length > MaxBytes)
                    {
                        string rotated = path + ".1";
                        if (File.Exists(rotated)) File.Delete(rotated);
                        File.Move(path, rotated);
                    }
                    File.AppendAllText(path, line, new UTF8Encoding(false));
                }
            }
            catch
            {
            }
        }
    }
}
