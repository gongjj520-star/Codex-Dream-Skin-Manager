function Resolve-DreamSkinLanguage {
  param(
    [string]$Language = $env:DREAMSKIN_LANG,
    [string]$StateRoot = ''
  )
  # This distribution always presents Chinese. Retain parameters for existing
  # callers, without overwriting their saved language settings.
  return 'zh-CN'
}

function Set-DreamSkinLanguage {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('system', 'en-US', 'zh-CN')]
    [string]$Language,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($root)
  }
  $preferencePath = Join-Path $root 'language.txt'
  if ($Language -ceq 'system') {
    Remove-Item -LiteralPath $preferencePath -Force -ErrorAction SilentlyContinue
    return
  }
  $temporary = Join-Path $root ('.language.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [System.IO.File]::WriteAllText(
      $temporary,
      $Language + [Environment]::NewLine,
      [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $preferencePath -Force
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

function Get-DreamSkinLanguagePreference {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  return 'zh-CN'
}

function ConvertTo-DreamSkinDisplayMessage {
  param([AllowEmptyString()][string]$Message)
  $original = if ($null -eq $Message) { '' } else { $Message.Trim() }
  if (-not $original) { return '' }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in @($original -split '\r?\n' | Where-Object { $_.Trim() })) {
    $display = $line.Trim()
    $classification = $display
    $display = $display -replace 'DREAM_SKIN_[A-Z_]+:\s*', ''
    # Protect names in quotes and paths while detecting English error prose.
    $masked = [regex]::Replace($display, '\u201c[^\u201d]*\u201d|\u2018[^\u2019]*\u2019|"[^"]*"|https?://\S+|[A-Za-z]:\\[^\r\n"<>|]*',
      [System.Text.RegularExpressions.MatchEvaluator]{ param($match) ' ' * $match.Length })
    $english = [regex]::Match($masked, '\b(?:[A-Za-z]*Exception\b|EACCES\b|EPERM\b|ENOENT\b|ENOTFOUND\b|ENOSPC\b|ECONNREFUSED\b|ECONNRESET\b|ETIMEDOUT\b|ERR_[A-Z_]+\b|fetch failed|decode failed|access denied|not found|connection refused|(?:Could|Cannot|Unable|Failed|Invalid|Unsupported|Access|The|No|Another|Connection|Network|Error)\s+[A-Za-z]|[A-Za-z]+(?:[ \t]+[A-Za-z]+){2,})', 'IgnoreCase')
    if ($display -notmatch '[\u3400-\u9fff]' -or $english.Success) {
      $reason = switch -Regex ($classification) {
        'access.denied|permission|unauthorized|eacces|eperm' { '系统拒绝了访问请求，请检查文件是否被占用或受到权限限制。'; break }
        'another.*operation|operation.*already running' { '已有皮肤操作正在进行，请等待完成后再试。'; break }
        'checksum|sha-256|hash mismatch' { '文件完整性校验未通过，请重新下载后重试。'; break }
        'download|network|http|ssl|tls|fetch|econnrefused|econnreset|enotfound|connection.*(?:refused|reset|closed)' { '网络连接或下载失败，请检查网络后重试。'; break }
        'timed?\s*out|timeout|within \d+ seconds' { '等待操作完成超时，请刷新状态后重试。'; break }
        'restart_required|restart consent' { 'Codex 需要重新启动才能应用皮肤，请确认后重试。'; break }
        'cdp|debugging|loopback' { '无法连接 Codex 的皮肤服务，请重新应用皮肤。'; break }
        'video|decode|codec|playback' { '背景图片或视频无法播放，请更换文件后重试。'; break }
        'renderer|verification failed' { '尚未确认皮肤显示成功，请刷新状态或重新应用。'; break }
        'not found|missing|incomplete|does not exist|enoent' { '所需文件缺失或不完整，请重新安装管理器或重新选择背景文件。'; break }
        'disk.*full|not enough.*space|enospc' { '磁盘剩余空间不足，请清理空间后重试。'; break }
        default { '操作未完成，请重试；如仍失败，请查看脚本日志。' }
      }
      $display = if ($english.Success -and $display -match '[\u3400-\u9fff]') {
        $display.Substring(0, $english.Index) + $reason
      } else { $reason }
    }
    if (-not $lines.Contains($display)) { $lines.Add($display) }
  }
  $translated = $lines -join [Environment]::NewLine
  if ($translated -cne $original) {
    try {
      $logRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
      [void][System.IO.Directory]::CreateDirectory($logRoot)
      $logPath = Join-Path $logRoot 'script-diagnostics.log'
      if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        [System.IO.File]::Copy($logPath, (Join-Path $logRoot 'script-diagnostics.previous.log'), $true)
        [System.IO.File]::WriteAllText($logPath, '')
      }
      $bounded = $original.Substring(0, [Math]::Min($original.Length, 16384))
      [System.IO.File]::AppendAllText($logPath, [DateTime]::UtcNow.ToString('O') + [Environment]::NewLine +
        $bounded + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {}
  }
  return $translated
}

function Get-DreamSkinText {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [string]$Language = '',
    [object[]]$FormatArguments = @()
  )
  $resolved = Resolve-DreamSkinLanguage -Language $Language
  $catalog = @{
    'en-US' = @{
      StatusPaused = 'Status: Paused'; StatusRunning = 'Status: Running'; StatusStopped = 'Status: Stopped'
      Apply = 'Apply or reapply'; Resume = 'Resume skin'; Pause = 'Pause skin'
      ChangeBackground = 'Change background image'; BackgroundTitle = 'Choose a Codex Dream Skin background image'
      BackgroundUpdated = 'Background image updated.'; ImportZip = 'Import theme ZIP...'
      ImportTitle = 'Choose a Codex Dream Skin theme ZIP'; SaveCurrent = 'Save current theme'
      SavePrompt = 'Theme name:'; SaveTitle = 'Save Codex Dream Skin theme'; Saved = 'Saved: {0}'
      SavedThemes = 'Saved themes'; NoSavedThemes = 'No saved themes'; Applied = 'Applied: {0}'
      OpenThemes = 'Open themes folder'; OpenImages = 'Open images folder'; CheckUpdate = 'Check for updates...'
      Gallery = 'Theme Gallery'; Studio = 'Online Studio'; OpenSite = 'Open DreamSkin.cc'
      LaunchAtLogin = 'Launch at login'; Restore = 'Fully restore Codex'; Exit = 'Exit tray'
      Language = 'Language / 语言'; LanguageSystem = 'System / 系统'; LanguageEnglish = 'English'; LanguageChinese = '中文'
      ApplyStarted = 'Skin apply started'; Applying = 'Applying skin...'
      ResumeStarted = 'Skin reapply started'; Reapplying = 'Reapplying skin...'
      ThemeExists = 'Theme already exists: {0}. No duplicate was written.'
      ThemeUpdated = 'Saved theme updated: {0}. The current theme did not change.'
      ThemeImported = 'Imported: {0}. The current theme did not change.'
      NewIdentifier = ' New identifier: {0}.'; NameCollision = ' A theme with the same name already exists.'
      CssValidated = ' theme.css passed local Safe CSS validation and will apply with this theme.'
      SignatureIgnored = ' manifest.sig is reserved and ignored by this version.'
      CleanupWarning = ' The theme was saved, but an old backup folder could not be cleaned up. Restart the client later and check its logs.'
      ImageFilter = 'Image and video files|*.png;*.apng;*.jpg;*.jpeg;*.webp;*.gif;*.mp4|All files|*.*'
      PauseNoSession = 'Pause was recorded, but no active session could be reached. The current window may still show the skin.'
      PauseSucceeded = 'Skin paused.'; PauseFailed = 'Pause was recorded, but removing the live skin failed. Retry pause or fully restore Codex.'
      UpdateTitle = 'Codex Dream Skin Update'; UpdateAvailable = 'Codex Dream Skin {0} is available.'
      UpdateQuestion = 'Download the verified installer and start the update?'; UpToDate = 'Codex Dream Skin {0} is up to date.'
      UpdateFailed = 'Could not check for updates.'
      RestartPrompt = 'Codex must restart once to enable Dream Skin. Unsaved input may be lost. Restart now?'
      LaunchCancelled = 'Dream Skin launch was cancelled; Codex was not changed.'
      RestoreClose = 'Restore will close Codex, remove Dream Skin and its CDP session, then reopen the official app. Continue?'
      RestoreCloseNoRelaunch = 'Restore will close Codex and remove Dream Skin plus its CDP session. Continue?'
      RestoreCancelled = 'Restore was cancelled; no state or configuration was changed.'
      CommunitySuccess = 'Theme “{0}” passed download, SHA-256, package, and Safe CSS validation and is now active in Codex.'
      CommunityCleanup = 'The theme was applied, but an old backup folder could not be cleaned up. The new theme will not be rolled back. Restart the client later and check its logs.'
      CommunityConfirmTitle = 'Confirm one-click theme apply'; CommunityConfirm = 'Download and apply “{0}” from DreamSkin.cc?'
      CommunityAuthor = 'Author: {0}'; CommunityVersion = 'Version: {0} · {1} MiB'; CommunityHash = 'SHA-256: {0}'
      CommunitySafety = 'The client connects only to the fixed official API and revalidates download size, SHA-256, ZIP, manifest, and Safe CSS. Codex may restart while applying, and unsaved input may be lost. Theme content is never executed as commands.'
      RecoveryVerified = 'The new theme did not become active. The previous theme was reapplied and passed visible-render verification.'
      RecoveryFailed = 'The new theme did not become active. Automatic restore or render verification of the previous theme did not finish. Reopen the client and inspect it.'
      RecoverySuperseded = 'Another theme operation was detected. The client kept the newer selection and did not overwrite it.'
      RecoveryUnconfirmed = 'The new theme did not enter verified active state.'
      RecoveryWorkRetained = 'The recovery work folder was retained and not deleted.'; DownloadCleaned = 'Temporary download files were cleaned up.'
      RollbackSnapshot = 'Rollback snapshot: {0}'; CommunityApplyFailed = 'One-click theme apply failed.'
      CommunityStartCdpLaunchFailed = 'The official Codex app could not be started with a debugging session.'
      CommunityStartCdpDirectAccessDenied = 'Windows denied direct launch of the validated Store executable after package activation dropped the debugging argument.'
      CommunityStartCdpEndpointUnavailable = 'This Codex build did not expose a verified local debugging endpoint.'
      CommunityStartPortUnavailable = 'No verified local debugging port was available.'
      CommunityStartStateReconciliationFailed = 'Dream Skin could not reconcile the previous local session safely.'
      CommunityStartInjectorFailed = 'The local Dream Skin renderer could not start.'
      CommunityStartRendererVerificationFailed = 'The active theme did not pass visible renderer verification.'
      CommunityStartSuperseded = 'A newer theme or pause action superseded this apply.'
      CommunityStartInternalFailure = 'Dream Skin could not complete the local start operation.'
      CommunityStartTimedOut = 'Dream Skin start and visible verification timed out. Background recovery was left running; active-theme files were preserved.'
      CommunityStartInvalidResult = 'Dream Skin start did not return a valid bounded result.'
      CommunityStartAppearanceRestored = 'The appearance settings changed by this attempt were restored.'
      CommunityStartAppearanceConflictPreserved = 'Newer appearance edits were preserved.'
      CommunityStartAppearanceBlocked = 'Appearance recovery was blocked because Codex could not be confirmed closed or the config changed again.'
      CommunityStartAppearancePreservedRendered = 'The appearance settings were kept because the theme was already visibly rendered.'
    }
    'zh-CN' = @{
      StatusPaused = '状态：已暂停'; StatusRunning = '状态：运行中'; StatusStopped = '状态：未运行'
      Apply = '应用或重新应用'; Resume = '继续显示皮肤'; Pause = '暂停皮肤'
      ChangeBackground = '更换背景图'; BackgroundTitle = '选择梦幻皮肤背景图'
      BackgroundUpdated = '背景图已更新。'; ImportZip = '导入主题压缩包…'
      ImportTitle = '选择梦幻皮肤主题压缩包'; SaveCurrent = '保存当前主题'
      SavePrompt = '输入主题名称：'; SaveTitle = '保存梦幻皮肤主题'; Saved = '已保存：{0}'
      SavedThemes = '已保存主题'; NoSavedThemes = '暂无已保存主题'; Applied = '已应用：{0}'
      OpenThemes = '打开主题文件夹'; OpenImages = '打开图片文件夹'; CheckUpdate = '检查更新…'
      Gallery = '主题库'; Studio = '在线编辑器'; OpenSite = '打开皮肤网站'
      LaunchAtLogin = '登录时启动'; Restore = '完全恢复 Codex'; Exit = '退出托盘'
      Language = '界面语言'; LanguageSystem = '跟随系统'; LanguageEnglish = '英语'; LanguageChinese = '简体中文'
      ApplyStarted = '已开始应用皮肤'; Applying = '正在应用皮肤…'
      ResumeStarted = '已开始重新应用皮肤'; Reapplying = '正在重新应用皮肤…'
      ThemeExists = '主题已存在：{0}。没有重复写入。'
      ThemeUpdated = '已更新已保存主题：{0}。当前主题没有改变。'
      ThemeImported = '已导入：{0}。当前主题没有改变。'
      NewIdentifier = ' 新标识：{0}。'; NameCollision = ' 主题库中已有同名主题。'
      CssValidated = ' 主题样式已通过安全检查，切换到该主题时会一并生效。'
      SignatureIgnored = ' 主题签名文件为预留功能，当前版本已忽略。'
      CleanupWarning = ' 主题已成功保存，但旧备份目录未能自动清理；新主题不会因此回滚。请稍后重启客户端并查看日志。'
      ImageFilter = '图片和视频文件|*.png;*.apng;*.jpg;*.jpeg;*.webp;*.gif;*.mp4|所有文件|*.*'
      PauseNoSession = '没有可连接的活动会话；已记录暂停，当前窗口可能仍显示皮肤。'
      PauseSucceeded = '皮肤已暂停。'; PauseFailed = '已记录暂停，但卸下当前皮肤失败；可重试暂停或完全恢复 Codex。'
      UpdateTitle = '梦幻皮肤管理器更新'; UpdateAvailable = '梦幻皮肤管理器 {0} 已发布。'
      UpdateQuestion = '是否下载并检查安装包，然后开始更新？'; UpToDate = '梦幻皮肤管理器 {0} 已是最新版本。'
      UpdateFailed = '无法检查更新。'
      RestartPrompt = 'Codex 需要重启一次才能启用皮肤，未保存的输入可能丢失。现在重启吗？'
      LaunchCancelled = '已取消启动皮肤；Codex 未发生改变。'
      RestoreClose = '恢复操作将关闭 Codex，移除皮肤及其连接，然后重新打开官方应用。是否继续？'
      RestoreCloseNoRelaunch = '恢复操作将关闭 Codex，并移除皮肤及其连接。是否继续？'
      RestoreCancelled = '已取消恢复；状态和配置均未改变。'
      CommunitySuccess = '主题“{0}”已通过文件完整性和样式安全检查，并已应用到 Codex。'
      CommunityCleanup = '主题已成功应用，但旧备份目录未能自动清理；新主题不会因此回滚。请稍后重启客户端并查看日志。'
      CommunityConfirmTitle = '确认一键换肤'; CommunityConfirm = '从 DreamSkin.cc 下载并应用“{0}”？'
      CommunityAuthor = '作者：{0}'; CommunityVersion = '版本：{0} · {1} 兆字节'; CommunityHash = '文件校验值：{0}'
      CommunitySafety = '客户端会检查下载文件是否完整、主题格式和样式是否安全。应用时 Codex 可能重启，未保存的输入可能丢失。主题内容不会作为命令执行。'
      RecoveryVerified = '新主题未能生效；此前主题已重新应用并完成可见渲染验证。'
      RecoveryFailed = '新主题未能生效；此前主题的自动恢复或渲染验证未完成。请重新打开客户端检查。'
      RecoverySuperseded = '检测到另一个换肤操作，客户端保留了较新的选择，没有覆盖它。'
      RecoveryUnconfirmed = '新主题未写入已验证的活动状态。'
      RecoveryWorkRetained = '恢复工作目录已保留，未自动删除。'; DownloadCleaned = '下载临时文件已清理。'
      RollbackSnapshot = '回滚快照：{0}'; CommunityApplyFailed = '一键换肤失败。'
      CommunityStartCdpLaunchFailed = '官方 Codex 应用无法以调试会话启动。'
      CommunityStartCdpDirectAccessDenied = '系统拒绝直接启动商店版 Codex，暂时无法建立皮肤连接。'
      CommunityStartCdpEndpointUnavailable = '当前 Codex 版本没有开放可验证的本地调试端点。'
      CommunityStartPortUnavailable = '没有可用且可验证的本地调试端口。'
      CommunityStartStateReconciliationFailed = '无法安全恢复上一次皮肤连接。'
      CommunityStartInjectorFailed = '本机皮肤服务无法启动。'
      CommunityStartRendererVerificationFailed = '当前主题未通过可见渲染验证。'
      CommunityStartSuperseded = '较新的主题或暂停操作已取代本次应用。'
      CommunityStartInternalFailure = '皮肤服务未能完成启动。'
      CommunityStartTimedOut = '启动并确认皮肤显示超时；后台恢复仍在继续，当前主题文件已保留。'
      CommunityStartInvalidResult = '皮肤服务未返回有效的启动结果。'
      CommunityStartAppearanceRestored = '本次尝试改动的外观设置已恢复。'
      CommunityStartAppearanceConflictPreserved = '已保留较新的外观编辑。'
      CommunityStartAppearanceBlocked = '由于无法确认 Codex 已关闭或配置再次变化，外观恢复已停止。'
      CommunityStartAppearancePreservedRendered = '主题已经可见渲染，因此保留了当前外观设置。'
    }
  }
  $value = $catalog[$resolved][$Key]
  if ($null -eq $value) { throw '所需提示文字缺失，请重新安装管理器。' }
  if ($FormatArguments.Count -gt 0) { return [string]::Format($value, $FormatArguments) }
  return $value
}
