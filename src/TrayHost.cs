using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace CodexDreamSkinManager
{
    // Notification-area presence for the manager: closing the window hides it
    // here, and quick theme switching / pause run through the window's own
    // operations so tray and window share one code path and one busy state.
    internal sealed class TrayHost : IDisposable
    {
        private const string AppName = "Codex Dream Skin";
        private const string IconResourceName = "CodexDreamSkinManager.AppIcon.ico";
        private readonly MainWindow window;
        private readonly ManagerSettings settings;
        private readonly string settingsPath;
        private readonly string executablePath;
        private readonly Icon trayIcon;
        private readonly ContextMenuStrip menu;
        private readonly NotifyIcon notifyIcon;
        private bool disposed;

        public TrayHost(MainWindow window, ManagerSettings settings, string settingsPath, string executablePath)
        {
            if (window == null) throw new ArgumentNullException("window");
            this.window = window;
            this.settings = settings ?? new ManagerSettings();
            this.settingsPath = settingsPath;
            this.executablePath = executablePath;
            trayIcon = LoadIcon(executablePath);
            menu = new ContextMenuStrip();
            menu.Opening += (sender, e) =>
            {
                RebuildMenu();
                e.Cancel = false;
                window.RequestStatusRefresh();
            };
            // The icon must exist before the first menu build, which also
            // refreshes the icon's tooltip.
            notifyIcon = new NotifyIcon();
            notifyIcon.Icon = trayIcon;
            notifyIcon.Text = AppName;
            notifyIcon.ContextMenuStrip = menu;
            notifyIcon.MouseClick += (sender, e) => { if (e.Button == MouseButtons.Left) window.ShowFromTray(); };
            notifyIcon.BalloonTipClicked += delegate { window.ShowFromTray(); };
            RebuildMenu();
            notifyIcon.Visible = true;
            window.HiddenToTray += OnHiddenToTray;
            window.OperationFinished += OnOperationFinished;
            window.ThemeApplied += OnThemeApplied;
            window.StatusDisplayChanged += delegate { UpdateTooltip(); };
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            window.HiddenToTray -= OnHiddenToTray;
            window.OperationFinished -= OnOperationFinished;
            window.ThemeApplied -= OnThemeApplied;
            notifyIcon.Visible = false;
            notifyIcon.Dispose();
            menu.Dispose();
            trayIcon.Dispose();
        }

        private void RebuildMenu()
        {
            menu.SuspendLayout();
            try
            {
                menu.Items.Clear();
                bool busy = window.IsOperationBusy;
                menu.Items.Add(new ToolStripMenuItem(busy ? "正在执行操作..." : MenuText(window.TraySummary)) { Enabled = false });
                menu.Items.Add(new ToolStripSeparator());

                ToolStripMenuItem switchMenu = new ToolStripMenuItem("快速切换") { Enabled = !busy && window.CanApplyFromTray };
                BuildThemeMenu(switchMenu);
                menu.Items.Add(switchMenu);

                ToolStripMenuItem pause = new ToolStripMenuItem(window.TrayPauseLabel)
                {
                    Enabled = !busy && window.CanTogglePauseFromTray
                };
                pause.Click += async delegate { await window.TogglePauseFromTrayAsync(); };
                menu.Items.Add(pause);
                menu.Items.Add(new ToolStripSeparator());

                ToolStripMenuItem open = new ToolStripMenuItem("打开管理器");
                open.Font = new Font(open.Font, FontStyle.Bold);
                open.Click += delegate { window.ShowFromTray(); };
                menu.Items.Add(open);

                ToolStripMenuItem autostart = new ToolStripMenuItem("开机自启")
                {
                    Checked = ManagerAutostart.IsEnabled(executablePath),
                    ToolTipText = "登录 Windows 后自动启动管理器并直接进入托盘"
                };
                autostart.Click += delegate { ToggleAutostart(); };
                menu.Items.Add(autostart);

                ToolStripMenuItem merge = new ToolStripMenuItem("新开的 Codex 并入皮肤窗口")
                {
                    Checked = settings.MergeExternalLaunches,
                    ToolTipText = "点通知、从开始菜单或链接打开的 Codex 会并入已打开的皮肤窗口，不再另开没有皮肤的窗口"
                };
                merge.Click += delegate { ToggleMergeExternalLaunches(); };
                menu.Items.Add(merge);
                menu.Items.Add(new ToolStripSeparator());

                ToolStripMenuItem exit = new ToolStripMenuItem("退出");
                exit.ToolTipText = "退出管理器；已显示的皮肤不受影响";
                exit.Click += delegate { window.ExitFromTray(); };
                menu.Items.Add(exit);
            }
            finally
            {
                menu.ResumeLayout();
            }
            UpdateTooltip();
        }

        private void BuildThemeMenu(ToolStripMenuItem parent)
        {
            List<ThemeOption> themes = window.GetThemeSnapshot();
            if (themes.Count == 0)
            {
                parent.DropDownItems.Add(new ToolStripMenuItem("主题列表尚未加载") { Enabled = false });
                return;
            }
            string activeId = window.ActiveThemeId;
            Dictionary<string, ThemeOption> byId = new Dictionary<string, ThemeOption>(StringComparer.OrdinalIgnoreCase);
            foreach (ThemeOption theme in themes)
                if (!string.IsNullOrWhiteSpace(theme.Id) && !byId.ContainsKey(theme.Id)) byId.Add(theme.Id, theme);

            bool hasRecent = false;
            foreach (string id in settings.RecentThemeIds)
            {
                ThemeOption theme;
                if (!byId.TryGetValue(id, out theme)) continue;
                if (!hasRecent)
                {
                    parent.DropDownItems.Add(new ToolStripMenuItem("最近使用") { Enabled = false });
                    hasRecent = true;
                }
                parent.DropDownItems.Add(ThemeItem(theme, activeId));
            }
            if (hasRecent) parent.DropDownItems.Add(new ToolStripSeparator());

            ToolStripMenuItem saved = new ToolStripMenuItem("我的主题");
            ToolStripMenuItem presets = new ToolStripMenuItem("内置主题");
            foreach (ThemeOption theme in themes)
                (theme.IsPreset ? presets : saved).DropDownItems.Add(ThemeItem(theme, activeId));
            if (saved.DropDownItems.Count == 0) saved.DropDownItems.Add(new ToolStripMenuItem("暂无") { Enabled = false });
            if (presets.DropDownItems.Count == 0) presets.DropDownItems.Add(new ToolStripMenuItem("暂无") { Enabled = false });
            parent.DropDownItems.Add(saved);
            parent.DropDownItems.Add(presets);
        }

        private ToolStripMenuItem ThemeItem(ThemeOption theme, string activeId)
        {
            ToolStripMenuItem item = new ToolStripMenuItem(MenuText(theme.Name));
            item.Checked = !string.IsNullOrWhiteSpace(activeId) &&
                string.Equals(theme.Id, activeId, StringComparison.OrdinalIgnoreCase);
            string themeId = theme.Id;
            item.Click += async delegate { await window.ApplyThemeFromTrayAsync(themeId); };
            return item;
        }

        private void ToggleAutostart()
        {
            bool enable = !ManagerAutostart.IsEnabled(executablePath);
            try
            {
                ManagerAutostart.SetEnabled(executablePath, enable);
            }
            catch (Exception ex)
            {
                ShowBalloon("开机自启设置失败", ex.Message, ToolTipIcon.Warning);
                return;
            }
            if (enable) OfferLegacyTrayCleanup();
            ShowBalloon(AppName, enable
                ? "已开启开机自启：登录 Windows 后管理器会直接进入托盘。"
                : "已关闭开机自启。", ToolTipIcon.Info);
        }

        private void ToggleMergeExternalLaunches()
        {
            settings.MergeExternalLaunches = !settings.MergeExternalLaunches;
            settings.Save(settingsPath);
            ShowBalloon(AppName, settings.MergeExternalLaunches
                ? "已开启：新开的 Codex 会并入已打开的皮肤窗口。"
                : "已关闭：新开的 Codex 不再并入皮肤窗口。", ToolTipIcon.Info);
        }

        // The older PowerShell tray created its own Startup shortcut; keeping both
        // would put two Dream Skin icons in the notification area after login.
        private static void OfferLegacyTrayCleanup()
        {
            string legacy = ManagerAutostart.LegacyTrayShortcutPath;
            if (!File.Exists(legacy)) return;
            System.Windows.MessageBoxResult answer = System.Windows.MessageBox.Show(
                "检测到旧版托盘工具的开机启动项：\n" + legacy + "\n\n两者同时开机启动会出现两个托盘图标。是否移除旧的启动项？",
                "开机自启", System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question);
            if (answer != System.Windows.MessageBoxResult.Yes) return;
            try { File.Delete(legacy); }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show("无法移除旧的启动项：" + ex.Message, "开机自启",
                    System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
            }
        }

        private void OnHiddenToTray(object sender, EventArgs e)
        {
            if (settings.TrayHintShown) return;
            settings.TrayHintShown = true;
            settings.Save(settingsPath);
            ShowBalloon("管理器仍在后台运行",
                "左键点击托盘图标重新打开；右键可快速切换主题、暂停皮肤或退出。", ToolTipIcon.Info);
        }

        private void OnOperationFinished(string message, bool error)
        {
            UpdateTooltip();
            if (window.IsVisible || string.IsNullOrWhiteSpace(message)) return;
            ShowBalloon(error ? "操作未完成" : AppName, message, error ? ToolTipIcon.Warning : ToolTipIcon.Info);
        }

        private void OnThemeApplied(string themeId)
        {
            settings.RememberTheme(themeId);
            settings.Save(settingsPath);
        }

        private void ShowBalloon(string title, string text, ToolTipIcon kind)
        {
            if (disposed || notifyIcon == null) return;
            string body = string.IsNullOrWhiteSpace(text) ? AppName : text.Trim();
            if (body.Length > 250) body = body.Substring(0, 247) + "...";
            notifyIcon.ShowBalloonTip(5000, title, body, kind);
        }

        private void UpdateTooltip()
        {
            if (disposed || notifyIcon == null) return;
            string summary = window.TraySummary;
            string text = string.IsNullOrWhiteSpace(summary) ? AppName : AppName + "\n" + summary;
            // NotifyIcon.Text is limited to 63 characters on .NET Framework.
            notifyIcon.Text = text.Length > 63 ? text.Substring(0, 60) + "..." : text;
        }

        private static string MenuText(string value)
        {
            return (value ?? "").Replace("&", "&&");
        }

        private static Icon LoadIcon(string executablePath)
        {
            try
            {
                using (Stream stream = typeof(TrayHost).Assembly.GetManifestResourceStream(IconResourceName))
                    if (stream != null) return new Icon(stream, SystemInformation.SmallIconSize);
            }
            catch { }
            try
            {
                Icon associated = Icon.ExtractAssociatedIcon(executablePath);
                if (associated != null) return associated;
            }
            catch { }
            return (Icon)SystemIcons.Application.Clone();
        }
    }
}
