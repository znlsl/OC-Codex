using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace O_C_Launcher
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                string scriptPath = FindSwitcherScript();
                WriteLauncherLog("Launching PowerShell UI: " + scriptPath);
                string powershellPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    "System32",
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");

                if (!File.Exists(powershellPath))
                {
                    powershellPath = "powershell.exe";
                }

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = powershellPath;
                startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"";
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.WindowStyle = ProcessWindowStyle.Hidden;
                startInfo.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;

                Process.Start(startInfo);
            }
            catch (Exception ex)
            {
                WriteLauncherLog("Launcher failed: " + ex);
                MessageBox.Show(
                    ex.Message,
                    "O-C",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private static void WriteLauncherLog(string message)
        {
            try
            {
                string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                if (string.IsNullOrWhiteSpace(appData))
                {
                    appData = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        "AppData",
                        "Roaming");
                }

                string logDir = Path.Combine(appData, "C-O", "logs");
                Directory.CreateDirectory(logDir);
                string logPath = Path.Combine(logDir, "launcher.log");
                File.AppendAllText(
                    logPath,
                    "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine);
            }
            catch
            {
            }
        }

        private static string FindSwitcherScript()
        {
            DirectoryInfo current = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (current != null)
            {
                string candidate = Path.Combine(
                    current.FullName,
                    "Source_Codes",
                    "tools",
                    "CodexUnifiedSwitcher.ps1");

                if (File.Exists(candidate))
                {
                    return candidate;
                }

                current = current.Parent;
            }

            throw new FileNotFoundException(
                "Cannot find Source_Codes\\tools\\CodexUnifiedSwitcher.ps1. Please keep O-C.exe next to the Source_Codes folder.");
        }
    }
}
