using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;

namespace CodexDreamSkinManager
{
    internal static class Program
    {
        private const string InstanceName = "Local\\CodexDreamSkinManager-1.1";
        private const string ActivationEventName = "Local\\CodexDreamSkinManager-1.1-show";

        [STAThread]
        private static void Main(string[] args)
        {
            bool startInTray = Array.Exists(args ?? new string[0], argument =>
                string.Equals(argument, ManagerAutostart.TrayArgument, StringComparison.OrdinalIgnoreCase));
            using (SingleInstanceGuard guard = SingleInstanceGuard.TryAcquire(InstanceName))
            {
                if (guard == null)
                {
                    // A login-time "--tray" start must not pop up a running manager.
                    if (startInTray) return;
                    if (!InstanceActivationListener.TrySignal(ActivationEventName))
                        ExistingWindowActivator.Activate("Codex Dream Skin Manager");
                    return;
                }
                OperationTimingLog.Enabled = true;
                Application application = new Application();
                // The window hides to the tray on close; only the tray's Exit
                // (or the end of the Windows session) shuts the manager down.
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
                DreamSkinService service = null;
                string startupError = "";
                try
                {
                    service = new DreamSkinService(AppDomain.CurrentDomain.BaseDirectory);
                }
                catch (Exception ex)
                {
                    startupError = ex.Message;
                }

                MainWindow window = new MainWindow(service);
                if (!string.IsNullOrWhiteSpace(startupError)) window.SetStartupError(startupError);
                window.MinimizeToTrayOnClose = true;
                window.Closed += delegate { application.Shutdown(); };
                application.SessionEnding += delegate { window.PrepareForSessionEnd(); };
                string executablePath = Assembly.GetEntryAssembly().Location;
                string settingsPath = ManagerSettings.DefaultPath;
                TrayHost trayHost = null;
                try
                {
                    trayHost = new TrayHost(window, ManagerSettings.Load(settingsPath), settingsPath, executablePath);
                }
                catch (Exception ex)
                {
                    // Without a tray the manager must stay usable as a plain
                    // window that exits on close.
                    window.MinimizeToTrayOnClose = false;
                    startInTray = false;
                    OperationTimingLog.Write("tray", "unavailable: " + ex.Message, 0);
                }
                using (TrayHost tray = trayHost)
                using (InstanceActivationListener listener = InstanceActivationListener.Start(ActivationEventName,
                    delegate { window.Dispatcher.BeginInvoke(new Action(window.ShowFromTray)); }))
                {
                    if (startInTray) window.StartHidden();
                    else window.Show();
                    application.Run();
                }
            }
        }
    }

    // Lets a second launch bring the running manager forward even while its
    // window is hidden in the tray, where a title lookup no longer finds it.
    internal sealed class InstanceActivationListener : IDisposable
    {
        private EventWaitHandle signal;
        private RegisteredWaitHandle registration;

        private InstanceActivationListener(EventWaitHandle signal, RegisteredWaitHandle registration)
        {
            this.signal = signal;
            this.registration = registration;
        }

        // Returns null when the event cannot be created; a second launch then
        // falls back to the title-based activation.
        public static InstanceActivationListener Start(string name, Action onSignal)
        {
            EventWaitHandle handle = null;
            try
            {
                handle = new EventWaitHandle(false, EventResetMode.AutoReset, name);
                RegisteredWaitHandle wait = ThreadPool.RegisterWaitForSingleObject(handle,
                    delegate { onSignal(); }, null, Timeout.Infinite, false);
                return new InstanceActivationListener(handle, wait);
            }
            catch (Exception)
            {
                if (handle != null) handle.Dispose();
                return null;
            }
        }

        public static bool TrySignal(string name)
        {
            EventWaitHandle handle;
            if (!EventWaitHandle.TryOpenExisting(name, out handle)) return false;
            using (handle) return handle.Set();
        }

        public void Dispose()
        {
            if (registration != null) registration.Unregister(null);
            registration = null;
            if (signal != null) signal.Dispose();
            signal = null;
        }
    }

    internal sealed class SingleInstanceGuard : IDisposable
    {
        private Mutex mutex;

        private SingleInstanceGuard(Mutex value) { mutex = value; }

        public static SingleInstanceGuard TryAcquire(string name)
        {
            bool createdNew;
            Mutex value = new Mutex(true, name, out createdNew);
            if (!createdNew)
            {
                value.Dispose();
                return null;
            }
            return new SingleInstanceGuard(value);
        }

        public void Dispose()
        {
            if (mutex == null) return;
            try { mutex.ReleaseMutex(); } catch { }
            mutex.Dispose();
            mutex = null;
        }
    }

    internal static class ExistingWindowActivator
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool ShowWindowAsync(IntPtr window, int command);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);

        public static void Activate(string title)
        {
            IntPtr window = FindWindow(null, title);
            if (window == IntPtr.Zero) return;
            ShowWindowAsync(window, 9);
            SetForegroundWindow(window);
        }
    }
}
