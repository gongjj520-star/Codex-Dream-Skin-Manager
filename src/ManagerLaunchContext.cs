using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows;

namespace CodexDreamSkinManager
{
    internal static class ManagerLaunchContext
    {
        private const string StandardLaunchArgument = "--standard-launch-attempt";

        public static bool EnsureStandardLaunch(string[] arguments)
        {
            try
            {
                IntPtr desktopWindow;
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                {
                    if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) return true;
                    if (Array.IndexOf(arguments ?? new string[0], StandardLaunchArgument) >= 0)
                        throw new InvalidOperationException("Windows 仍将管理器作为管理员启动。请取消管理器属性、兼容性或快捷方式中的“以管理员身份运行”，再正常打开。当前 Codex 窗口保持不动。");

                    desktopWindow = RequireStandardDesktop(identity);
                }
                string executable;
                using (Process current = Process.GetCurrentProcess()) executable = current.MainModule.FileName;
                RelaunchThroughDesktop(executable, desktopWindow);
            }
            catch (Exception ex)
            {
                string message = ex is InvalidOperationException ? ex.Message
                    : "未能切换到普通权限启动管理器。请关闭管理器后正常打开，当前 Codex 窗口保持不动。";
                MessageBox.Show(message, UserMessages.AppTitle, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            // ShellExecute submits a request; only the new process's own token
            // check permits it to create a service or perform a skin operation.
            return false;
        }

        private static IntPtr RequireStandardDesktop(WindowsIdentity currentIdentity)
        {
            IntPtr window = GetShellWindow();
            uint processId;
            if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out processId) == 0)
                throw new InvalidOperationException("桌面尚未准备好，请稍后正常打开管理器。当前 Codex 窗口保持不动。");
            using (Process desktop = Process.GetProcessById((int)processId))
            using (Process current = Process.GetCurrentProcess())
            {
                string expected = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
                if (desktop.SessionId != current.SessionId ||
                    !string.Equals(desktop.MainModule.FileName, expected, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("无法确认当前桌面启动环境，请正常打开管理器。当前 Codex 窗口保持不动。");
            }
            IntPtr process = OpenProcess(0x1000, false, processId);
            if (process == IntPtr.Zero) throw new InvalidOperationException("无法读取桌面启动权限，请正常打开管理器。当前 Codex 窗口保持不动。");
            IntPtr token = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(process, 8, out token))
                    throw new InvalidOperationException("无法读取桌面启动权限，请正常打开管理器。当前 Codex 窗口保持不动。");
                int elevated, required;
                if (!GetTokenInformation(token, 20, out elevated, sizeof(int), out required) || elevated != 0)
                    throw new InvalidOperationException("当前桌面无法提供普通权限启动。请正常打开管理器，当前 Codex 窗口保持不动。");
                using (WindowsIdentity desktopIdentity = new WindowsIdentity(token))
                {
                    if (!currentIdentity.User.Equals(desktopIdentity.User))
                        throw new InvalidOperationException("当前桌面无法提供同一用户的普通权限启动。请正常打开管理器，当前 Codex 窗口保持不动。");
                }
            }
            finally
            {
                if (token != IntPtr.Zero) CloseHandle(token);
                CloseHandle(process);
            }
            return window;
        }

        private static void RelaunchThroughDesktop(string executable, IntPtr verifiedDesktopWindow)
        {
            object windows = null, desktop = null, browser = null, view = null, folder = null, application = null;
            try
            {
                // Find the existing interactive desktop. Creating a new
                // Shell.Application in this process would not establish a
                // standard launch context.
                windows = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39")));
                object[] findArguments = { 0, 0, 8, 0, 1 }; // SWC_DESKTOP, SWFO_NEEDDISPATCH
                ParameterModifier modifier = new ParameterModifier(5);
                modifier[0] = true; modifier[1] = true; modifier[3] = true;
                desktop = windows.GetType().InvokeMember("FindWindowSW", BindingFlags.InvokeMethod, null, windows,
                    findArguments, new[] { modifier }, null, null);
                if (desktop == null) throw new InvalidOperationException("桌面启动服务尚未准备好，请稍后正常打开管理器。");
                if (GetShellWindow() != verifiedDesktopWindow ||
                    unchecked((uint)Convert.ToInt32(findArguments[3])) != unchecked((uint)verifiedDesktopWindow.ToInt64()))
                    throw new InvalidOperationException("桌面启动环境发生变化，请稍后正常打开管理器。当前 Codex 窗口保持不动。");
                Guid serviceId = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837"); // SID_STopLevelBrowser
                Guid browserId = typeof(IShellBrowser).GUID;
                Marshal.ThrowExceptionForHR(((IComServiceProvider)desktop).QueryService(ref serviceId, ref browserId, out browser));
                IShellView shellView;
                Marshal.ThrowExceptionForHR(((IShellBrowser)browser).QueryActiveShellView(out shellView));
                view = shellView;
                Guid dispatchId = new Guid("00020400-0000-0000-C000-000000000046");
                Marshal.ThrowExceptionForHR(shellView.GetItemObject(0, ref dispatchId, out folder));
                application = folder.GetType().InvokeMember("Application", BindingFlags.GetProperty, null, folder, null);
                application.GetType().InvokeMember("ShellExecute", BindingFlags.InvokeMethod, null, application,
                    new object[] { executable, StandardLaunchArgument, Path.GetDirectoryName(executable), "open", 1 });
            }
            finally
            {
                ReleaseCom(application); ReleaseCom(folder); ReleaseCom(view);
                ReleaseCom(browser); ReleaseCom(desktop); ReleaseCom(windows);
            }
        }

        private static void ReleaseCom(object value)
        {
            if (value == null || !Marshal.IsComObject(value)) return;
            try { Marshal.ReleaseComObject(value); } catch { }
        }

        [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int kind, out int value, int length, out int required);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

        [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IComServiceProvider
        {
            [PreserveSig] int QueryService(ref Guid serviceId, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out object result);
        }

        // Native vtable order includes both IOleWindow entries and every
        // preceding method. Unused parameters are ABI-compatible placeholders.
        [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellBrowser
        {
            [PreserveSig] int GetWindow(out IntPtr window);
            [PreserveSig] int ContextSensitiveHelp([MarshalAs(UnmanagedType.Bool)] bool enter);
            [PreserveSig] int InsertMenusSB(IntPtr menu, IntPtr widths);
            [PreserveSig] int SetMenuSB(IntPtr menu, IntPtr reserved, IntPtr activeWindow);
            [PreserveSig] int RemoveMenusSB(IntPtr menu);
            [PreserveSig] int SetStatusTextSB([MarshalAs(UnmanagedType.LPWStr)] string text);
            [PreserveSig] int EnableModelessSB([MarshalAs(UnmanagedType.Bool)] bool enabled);
            [PreserveSig] int TranslateAcceleratorSB(IntPtr message, ushort id);
            [PreserveSig] int BrowseObject(IntPtr item, uint flags);
            [PreserveSig] int GetViewStateStream(uint mode, out IntPtr stream);
            [PreserveSig] int GetControlWindow(uint id, out IntPtr window);
            [PreserveSig] int SendControlMsg(uint id, uint message, IntPtr wParam, IntPtr lParam, out IntPtr result);
            [PreserveSig] int QueryActiveShellView(out IShellView view);
            [PreserveSig] int OnViewWindowActive(IShellView view);
            [PreserveSig] int SetToolbarItems(IntPtr buttons, uint count, uint flags);
        }

        [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellView
        {
            [PreserveSig] int GetWindow(out IntPtr window);
            [PreserveSig] int ContextSensitiveHelp([MarshalAs(UnmanagedType.Bool)] bool enter);
            [PreserveSig] int TranslateAccelerator(IntPtr message);
            [PreserveSig] int EnableModeless([MarshalAs(UnmanagedType.Bool)] bool enabled);
            [PreserveSig] int UIActivate(uint state);
            [PreserveSig] int Refresh();
            [PreserveSig] int CreateViewWindow(IntPtr previous, IntPtr settings, IntPtr browser, IntPtr rectangle, out IntPtr window);
            [PreserveSig] int DestroyViewWindow();
            [PreserveSig] int GetCurrentInfo(IntPtr settings);
            [PreserveSig] int AddPropertySheetPages(uint reserved, IntPtr callback, IntPtr parameter);
            [PreserveSig] int SaveViewState();
            [PreserveSig] int SelectItem(IntPtr item, uint flags);
            [PreserveSig] int GetItemObject(uint item, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out object result);
        }
    }
}
