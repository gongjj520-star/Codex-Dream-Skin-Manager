using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;

namespace CodexDreamSkinManager
{
    internal static class Program
    {
        private const string InstanceName = "Local\\CodexDreamSkinManager-1.1";

        [STAThread]
        private static void Main(string[] arguments)
        {
            Thread.CurrentThread.CurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("zh-CN");
            // Store apps inherit an elevated launch context and can exit before
            // CDP starts. Normalize before the mutex, service, or any config write.
            if (!ManagerLaunchContext.EnsureStandardLaunch(arguments)) return;
            SingleInstanceGuard acquiredGuard;
            try { acquiredGuard = SingleInstanceGuard.TryAcquire(InstanceName); }
            catch (UnauthorizedAccessException)
            {
                MessageBox.Show("旧的管理员权限管理器仍在运行，请先关闭它，再正常打开管理器。当前 Codex 窗口保持不动。",
                    UserMessages.AppTitle, MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            using (SingleInstanceGuard guard = acquiredGuard)
            {
                if (guard == null)
                {
                    ExistingWindowActivator.Activate(UserMessages.AppTitle);
                    ExistingWindowActivator.Activate("Codex Dream Skin Manager");
                    return;
                }
                Application application = new Application();
                application.ShutdownMode = ShutdownMode.OnMainWindowClose;
                DreamSkinService service = null;
                string startupError = "";
                try
                {
                    service = new DreamSkinService(AppDomain.CurrentDomain.BaseDirectory);
                }
                catch (Exception ex)
                {
                    startupError = UserMessages.Diagnostic(ex.Message);
                }

                MainWindow window = new MainWindow(service);
                if (!string.IsNullOrWhiteSpace(startupError)) window.SetStartupError(startupError);
                application.Run(window);
            }
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
