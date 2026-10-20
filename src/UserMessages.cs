using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace CodexDreamSkinManager
{
    internal static class UserMessages
    {
        public const string AppTitle = "Codex 梦幻皮肤管理器";
        private const string UnknownFailure = "操作未完成，请重试；如仍失败，请查看管理器日志。";
        private static readonly object DiagnosticLock = new object();
        private static string lastDiagnostic = "";

        // Translate only diagnostics. Theme names, file paths, script arguments,
        // and machine-readable results must retain their original values.
        public static string Diagnostic(string message)
        {
            string original = (message ?? "").Trim();
            if (original.Length == 0) return "";
            List<string> lines = new List<string>();
            foreach (string rawLine in original.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string line = rawLine.Trim();
                if (Regex.IsMatch(line, @"^(?:at |At line:|CategoryInfo\s*:|FullyQualifiedErrorId\s*:|\+\s|~+)", RegexOptions.IgnoreCase))
                    continue;
                Match code = Regex.Match(line, @"DREAM_SKIN_([A-Z_]+):\s*");
                if (code.Success)
                {
                    string detail = line.Substring(code.Index + code.Length);
                    string prefix = line.Substring(0, code.Index);
                    line = prefix + (ContainsChinese(detail) ? TranslateLine(detail) : FailureReason(code.Groups[1].Value + " " + detail));
                }
                else line = TranslateLine(line);
                if (!lines.Contains(line)) lines.Add(line);
            }
            string translated = lines.Count > 0 ? string.Join(Environment.NewLine, lines.ToArray()) : UnknownFailure;
            if (!string.Equals(original, translated, StringComparison.Ordinal)) SaveDiagnostic(original);
            return translated;
        }

        public static string Operation(string scriptName, string action)
        {
            switch (action)
            {
                case "Status": return "读取皮肤状态";
                case "ListThemes": return "读取主题列表";
                case "ValidateImage": return "检查背景文件";
                case "ApplyTheme": return "应用皮肤";
                case "SaveTheme": return "保存主题";
                case "UpdateTheme": return "保存主题设置";
                case "ImportBatch": return "导入主题";
                case "DeleteTheme": case "DeletePreset": return "删除主题";
                case "Pause": return "暂停皮肤";
                case "Resume": return "继续显示皮肤";
                case "ResetTheme": return "恢复默认主题";
            }
            if (string.Equals(scriptName, "check-update.ps1", StringComparison.OrdinalIgnoreCase)) return "检查更新";
            if (string.Equals(scriptName, "restore-dream-skin.ps1", StringComparison.OrdinalIgnoreCase)) return "恢复原始外观";
            if (string.Equals(scriptName, "apply-theme-and-recover.ps1", StringComparison.OrdinalIgnoreCase)) return "启动并应用皮肤";
            return "皮肤管理操作";
        }

        private static string TranslateLine(string line)
        {
            if (!ContainsChinese(line)) return FailureReason(line);
            // An exception may have a Chinese operation prefix and an English
            // system error after it. Keep the operation context, translate the error.
            string masked = Regex.Replace(line, @"“[^”]*”|‘[^’]*’|""[^""]*""|'[^']*'|https?://\S+|[A-Za-z]:\\[^\r\n""<>|]*",
                delegate(Match match) { return new string(' ', match.Length); });
            Match english = Regex.Match(masked,
                @"\b(?:[A-Za-z]*Exception\b|EACCES\b|EPERM\b|ENOENT\b|ENOTFOUND\b|ENOSPC\b|ECONNREFUSED\b|ECONNRESET\b|ETIMEDOUT\b|ERR_[A-Z_]+\b|fetch failed|decode failed|access denied|not found|connection refused|(?:Could|Cannot|Unable|Failed|Invalid|Unsupported|Access|The|A|An|No|Another|Timed|Connection|Network|Request|Response|Error)\s+[A-Za-z]|[A-Za-z]+(?:[ \t]+[A-Za-z]+){2,})",
                RegexOptions.IgnoreCase);
            if (english.Success) return line.Substring(0, english.Index) + FailureReason(line.Substring(english.Index));
            return line;
        }

        private static string FailureReason(string detail)
        {
            string value = detail.ToLowerInvariant();
            if (Regex.IsMatch(value, @"cancelled|canceled"))
                return "操作已取消。";
            if (Regex.IsMatch(value, @"restart_required|restart consent|explicit.*restart"))
                return "Codex 需要重新启动才能应用皮肤，请确认后重试。";
            if (Regex.IsMatch(value, @"blocked by policy|blocked.*policy"))
                return "操作被安全策略阻止；系统未提供更具体的原因。";
            if (Regex.IsMatch(value, @"access.denied|permission|unauthorized|not permitted|eacces|eperm"))
                return "系统拒绝了访问请求，请检查文件是否被占用或受到权限限制。";
            if (Regex.IsMatch(value, @"another.*operation|operation.*already running"))
                return "已有皮肤操作正在进行，请等待完成后再试。";
            if (Regex.IsMatch(value, @"checksum|sha-256|hash verification|hash mismatch"))
                return "文件完整性校验未通过，请重新下载后重试。";
            if (Regex.IsMatch(value, @"download|network|internet|remote name|name resolution|http|ssl|tls|certificate|econnrefused|econnreset|enotfound|connection.*(?:refused|reset|closed)|fetch failed"))
                return "网络连接或下载失败，请检查网络后重试。";
            if (Regex.IsMatch(value, @"timed?\s*out|timeout|within \d+ seconds"))
                return "等待操作完成超时，请刷新状态后重试。";
            if (Regex.IsMatch(value, @"cdp|debugging (?:endpoint|argument|session)|reconnect_required|loopback"))
                return "无法连接 Codex 的皮肤服务，请重新点击“应用皮肤”。";
            if (Regex.IsMatch(value, @"video|codec|decode|playback|media error"))
                return "背景图片或视频无法播放，请更换文件后重试。";
            if (Regex.IsMatch(value, @"renderer|live_apply_failed|verification failed|visib.*verif"))
                return "尚未确认皮肤显示成功，请刷新状态或重新应用。";
            if (Regex.IsMatch(value, @"not found|does not exist|missing|incomplete|enoent"))
                return "所需文件缺失或不完整，请重新安装管理器或重新选择背景文件。";
            if (Regex.IsMatch(value, @"used by another process|sharing violation|file.*in use"))
                return "文件正在被其他程序使用，请关闭占用它的程序后重试。";
            if (Regex.IsMatch(value, @"disk.*full|not enough.*space|enospc"))
                return "磁盘剩余空间不足，请清理空间后重试。";
            if (Regex.IsMatch(value, @"reparse point|symbolic link|junction"))
                return "相关路径使用了链接目录，请改用普通文件夹。";
            if (Regex.IsMatch(value, @"invalid|unsupported|malformed|schema|manifest|json|format"))
                return "收到的数据或文件格式不受支持，请重新获取后重试。";
            return UnknownFailure;
        }

        private static bool ContainsChinese(string value)
        {
            return Regex.IsMatch(value, @"[\u3400-\u9fff]");
        }

        private static void SaveDiagnostic(string message)
        {
            // A translated message must not discard the original troubleshooting
            // evidence. Logging failures must never interrupt a skin operation.
            try
            {
                lock (DiagnosticLock)
                {
                    if (message == lastDiagnostic) return;
                    string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexDreamSkin");
                    Directory.CreateDirectory(root);
                    string path = Path.Combine(root, "manager-diagnostics.log");
                    if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                    {
                        File.Copy(path, Path.Combine(root, "manager-diagnostics.previous.log"), true);
                        File.WriteAllText(path, "", new UTF8Encoding(false));
                    }
                    string bounded = message.Length > 16384 ? message.Substring(0, 16384) : message;
                    File.AppendAllText(path, DateTime.UtcNow.ToString("O") + Environment.NewLine + bounded + Environment.NewLine, new UTF8Encoding(false));
                    lastDiagnostic = message;
                }
            }
            catch { }
        }
    }
}
