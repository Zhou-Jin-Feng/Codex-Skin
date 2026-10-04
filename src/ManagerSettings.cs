using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace CodexDreamSkinManager
{
    // Manager-only preferences. Theme and skin state stay owned by the
    // PowerShell runtime; this file never influences what gets injected.
    internal sealed class ManagerSettings
    {
        private const int MaxRecentThemes = 5;

        public bool TrayHintShown;
        // Fold Codex windows opened outside the skin into the skinned instance.
        public bool MergeExternalLaunches = true;
        public List<string> RecentThemeIds = new List<string>();

        internal static string DefaultPath
        {
            get { return Path.Combine(ManagerPaths.StateRoot, "manager-settings.json"); }
        }

        public static ManagerSettings Load(string path)
        {
            ManagerSettings settings = new ManagerSettings();
            try
            {
                if (!File.Exists(path)) return settings;
                Dictionary<string, object> data = new JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
                if (data == null) return settings;
                object value;
                if (data.TryGetValue("trayHintShown", out value) && value is bool) settings.TrayHintShown = (bool)value;
                if (data.TryGetValue("mergeExternalLaunches", out value) && value is bool)
                    settings.MergeExternalLaunches = (bool)value;
                if (data.TryGetValue("recentThemeIds", out value) && value is IEnumerable && !(value is string))
                {
                    foreach (object item in (IEnumerable)value)
                    {
                        string id = Convert.ToString(item, CultureInfo.InvariantCulture);
                        if (!string.IsNullOrWhiteSpace(id) && settings.RecentThemeIds.Count < MaxRecentThemes &&
                            !settings.RecentThemeIds.Contains(id))
                            settings.RecentThemeIds.Add(id);
                    }
                }
            }
            catch
            {
                // A damaged preference file only resets preferences.
                return new ManagerSettings();
            }
            return settings;
        }

        public void Save(string path)
        {
            try
            {
                string directory = Path.GetDirectoryName(path);
                if (string.IsNullOrEmpty(directory)) return;
                Directory.CreateDirectory(directory);
                Dictionary<string, object> data = new Dictionary<string, object>();
                data["trayHintShown"] = TrayHintShown;
                data["mergeExternalLaunches"] = MergeExternalLaunches;
                data["recentThemeIds"] = RecentThemeIds.ToArray();
                string temporary = path + ".tmp";
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(data), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            catch
            {
                // Preferences are best effort; failing to persist them must not
                // interrupt a theme operation.
            }
        }

        public void RememberTheme(string themeId)
        {
            if (string.IsNullOrWhiteSpace(themeId)) return;
            RecentThemeIds.RemoveAll(id => string.Equals(id, themeId, StringComparison.OrdinalIgnoreCase));
            RecentThemeIds.Insert(0, themeId);
            if (RecentThemeIds.Count > MaxRecentThemes)
                RecentThemeIds.RemoveRange(MaxRecentThemes, RecentThemeIds.Count - MaxRecentThemes);
        }
    }

    // Per-user "start with Windows" entry. The registry value is the source of
    // truth; an entry pointing at another copy of the manager counts as off.
    internal static class ManagerAutostart
    {
        internal const string TrayArgument = "--tray";
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "CodexDreamSkinManager";

        internal static string LegacyTrayShortcutPath
        {
            get
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup),
                    "Codex Dream Skin.lnk");
            }
        }

        internal static string BuildCommand(string executablePath)
        {
            return "\"" + Path.GetFullPath(executablePath) + "\" " + TrayArgument;
        }

        public static bool IsEnabled(string executablePath)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    string value = key == null ? null : key.GetValue(ValueName) as string;
                    return !string.IsNullOrWhiteSpace(value) && string.Equals(value.Trim(),
                        BuildCommand(executablePath), StringComparison.OrdinalIgnoreCase);
                }
            }
            catch
            {
                return false;
            }
        }

        public static void SetEnabled(string executablePath, bool enabled)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
            {
                if (key == null) throw new InvalidOperationException("无法打开当前用户的开机启动设置。");
                if (enabled) key.SetValue(ValueName, BuildCommand(executablePath), RegistryValueKind.String);
                else key.DeleteValue(ValueName, false);
            }
        }
    }
}
