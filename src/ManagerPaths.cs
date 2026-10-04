using System;
using System.IO;

namespace CodexDreamSkinManager
{
    internal static class ManagerPaths
    {
        // Matches the PowerShell runtime, which resolves its state root from
        // %LOCALAPPDATA%; the known-folder API is only the fallback.
        internal static string StateRoot
        {
            get
            {
                string localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                if (string.IsNullOrWhiteSpace(localAppData) || !Path.IsPathRooted(localAppData))
                    localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return Path.Combine(localAppData, "CodexDreamSkin");
            }
        }
    }
}
