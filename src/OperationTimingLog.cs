using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace CodexDreamSkinManager
{
    // Stage timings shared with the PowerShell runtime in timing.log. The log is
    // diagnostic only: every failure is swallowed so it can never change the
    // outcome of the operation being measured.
    internal static class OperationTimingLog
    {
        private const long MaxBytes = 512 * 1024;
        private static readonly object Gate = new object();

        // Switched on by the application entry point only, so unit tests that
        // drive the window never write into the user's real log.
        internal static bool Enabled { get; set; }

        internal static string LogPath
        {
            get { return Path.Combine(ManagerPaths.StateRoot, "timing.log"); }
        }

        public static void Write(string operation, string stage, long elapsedMilliseconds)
        {
            if (!Enabled) return;
            try
            {
                string path = LogPath;
                string directory = Path.GetDirectoryName(path);
                if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory)) return;
                string line = string.Format(CultureInfo.InvariantCulture, "{0} [manager#{1}] {2} :: {3} (+{4} ms)\r\n",
                    DateTimeOffset.Now.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz", CultureInfo.InvariantCulture),
                    CurrentProcessId, Sanitize(operation), Sanitize(stage), elapsedMilliseconds);
                byte[] bytes = new UTF8Encoding(false).GetBytes(line);
                lock (Gate)
                {
                    for (int attempt = 0; attempt < 3; attempt++)
                    {
                        try
                        {
                            FileInfo existing = new FileInfo(path);
                            if (existing.Exists && existing.Length > MaxBytes)
                            {
                                string rotated = path + ".1";
                                if (File.Exists(rotated)) File.Delete(rotated);
                                File.Move(path, rotated);
                            }
                            using (FileStream stream = new FileStream(path, FileMode.Append, FileAccess.Write,
                                FileShare.ReadWrite | FileShare.Delete))
                                stream.Write(bytes, 0, bytes.Length);
                            return;
                        }
                        catch (IOException)
                        {
                            // A PowerShell writer may hold the file for a moment.
                            Thread.Sleep(15);
                        }
                    }
                }
            }
            catch
            {
            }
        }

        private static int CurrentProcessId
        {
            get
            {
                using (Process current = Process.GetCurrentProcess()) return current.Id;
            }
        }

        private static string Sanitize(string value)
        {
            return (value ?? "").Replace('\r', ' ').Replace('\n', ' ').Trim();
        }
    }

    // Measures one user-visible operation from click to final message.
    internal sealed class OperationTimer
    {
        private readonly Stopwatch stopwatch = Stopwatch.StartNew();
        private string lastStage = "";

        public OperationTimer(string operation)
        {
            Operation = string.IsNullOrWhiteSpace(operation) ? "operation" : operation.Trim();
            OperationTimingLog.Write(Operation, "start", 0);
        }

        public string Operation { get; private set; }

        public void Mark(string stage)
        {
            if (string.IsNullOrWhiteSpace(stage) || stage == lastStage) return;
            lastStage = stage;
            OperationTimingLog.Write(Operation, stage, stopwatch.ElapsedMilliseconds);
        }

        public void Finish(string outcome, string message)
        {
            OperationTimingLog.Write(Operation, outcome + ": " + (message ?? ""), stopwatch.ElapsedMilliseconds);
        }
    }
}
