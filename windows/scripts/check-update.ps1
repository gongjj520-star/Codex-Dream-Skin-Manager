[CmdletBinding()]
param(
  [switch]$Json,
  [switch]$Interactive,
  [switch]$Install,
  [string]$ExpectedVersion = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:DreamSkinRepository = 'rxkjovo/Codex-Dream-Skin-Manager'
$script:DreamSkinUpdateManifestUrl = "https://github.com/$script:DreamSkinRepository/releases/latest/download/update.json"
$script:DreamSkinReleasePage = "https://github.com/$script:DreamSkinRepository/releases/latest"
$script:DreamSkinMaximumChecksumBytes = 1MB
$script:DreamSkinMaximumInstallerBytes = 512MB
$script:DreamSkinEngineRoot = Split-Path -Parent $PSScriptRoot
$script:DreamSkinVersionPath = Join-Path $script:DreamSkinEngineRoot 'VERSION'
. (Join-Path $PSScriptRoot 'localization-windows.ps1')
$script:DreamSkinStateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$script:DreamSkinLanguage = Resolve-DreamSkinLanguage -StateRoot $script:DreamSkinStateRoot

function Get-DreamSkinUpdateText {
  param([Parameter(Mandatory = $true)][string]$Key, [object[]]$FormatArguments = @())
  Get-DreamSkinText -Key $Key -Language $script:DreamSkinLanguage -FormatArguments $FormatArguments
}

function ConvertTo-DreamSkinVersion {
  param([Parameter(Mandatory = $true)][string]$Value)
  $normalized = $Value.Trim()
  if ($normalized.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
    $normalized = $normalized.Substring(1)
  }
  if ($normalized -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "发布版本号无效：$Value"
  }
  $parsed = $null
  if (-not [version]::TryParse($normalized, [ref]$parsed)) {
    throw "发布版本号无效：$Value"
  }
  return $parsed
}

function Assert-DreamSkinReleaseAssetUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$AssetName
  )
  $uri = $null
  $expectedPath = "/$script:DreamSkinRepository/releases/download/$Tag/$AssetName"
  if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or
    $uri.AbsolutePath -cne $expectedPath -or $uri.Query -or $uri.Fragment) {
    throw "更新文件的下载地址与发布仓库不匹配：$AssetName"
  }
}

function Get-DreamSkinReleaseAsset {
  param(
    [Parameter(Mandatory = $true)][object]$Release,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$Tag
  )
  $assets = @($Release.assets | Where-Object { "$($_.name)" -ceq $Name })
  if ($assets.Count -ne 1) {
    throw "发布文件缺失或重复：$Name"
  }
  $url = "$($assets[0].browser_download_url)"
  Assert-DreamSkinReleaseAssetUrl -Url $url -Tag $Tag -AssetName $Name
  $sha256 = ''
  if ($null -ne $Release.PSObject.Properties['schemaVersion']) {
    $sha256 = "$($assets[0].sha256)"
    if ($sha256 -cnotmatch '^[0-9a-f]{64}$') {
      throw "更新信息中的文件校验值无效：$Name"
    }
  }
  return [pscustomobject]@{ Name = $Name; Url = $url; Sha256 = $sha256 }
}

function ConvertTo-DreamSkinUpdateResult {
  param(
    [Parameter(Mandatory = $true)][object]$Release,
    [Parameter(Mandatory = $true)][string]$CurrentVersionText
  )
  $current = ConvertTo-DreamSkinVersion -Value $CurrentVersionText
  if (-not $Release.tag_name) { throw '发布仓库没有返回版本号。' }
  $tag = "$($Release.tag_name)"
  $latest = ConvertTo-DreamSkinVersion -Value $tag
  $normalizedTag = 'v' + $latest.ToString()
  if ($tag -cne $normalizedTag) {
    throw "发布仓库返回的版本号格式不正确：$tag"
  }
  if ($Release.draft -eq $true) { throw '该版本尚为草稿，暂不能更新。' }
  if ($Release.prerelease -eq $true) { throw '该版本为预览版，暂不作为正式更新。' }

  $releaseUrl = "$($Release.html_url)"
  $releaseUri = $null
  $expectedReleasePath = "/$script:DreamSkinRepository/releases/tag/$tag"
  if (-not [uri]::TryCreate($releaseUrl, [UriKind]::Absolute, [ref]$releaseUri) -or
    $releaseUri.Scheme -cne 'https' -or $releaseUri.Host -cne 'github.com' -or
    $releaseUri.AbsolutePath -cne $expectedReleasePath -or $releaseUri.Query -or $releaseUri.Fragment) {
    throw '发布仓库返回的版本页面地址无效。'
  }

  $updateAvailable = $latest -gt $current
  $installerName = ''
  $installerUrl = ''
  $checksumUrl = ''
  $installerSha256 = ''
  if ($updateAvailable) {
    $installerName = "CodexDreamSkinManager-$normalizedTag-windows-x64-setup.exe"
    $installer = Get-DreamSkinReleaseAsset -Release $Release -Name $installerName `
      -Label 'Windows installer' -Tag $tag
    $checksum = Get-DreamSkinReleaseAsset -Release $Release -Name 'SHA256SUMS.txt' `
      -Label 'checksum manifest' -Tag $tag
    $installerUrl = $installer.Url
    $checksumUrl = $checksum.Url
    $installerSha256 = $installer.Sha256
  }

  return [pscustomobject][ordered]@{
    currentVersion = 'v' + $current.ToString()
    latestVersion = $normalizedTag
    updateAvailable = $updateAvailable
    releaseUrl = $releaseUrl
    installerAssetName = $installerName
    installerAssetUrl = $installerUrl
    checksumAssetUrl = $checksumUrl
    installerSha256 = $installerSha256
    installerStarted = $false
    installerProcessId = 0
  }
}

function Get-DreamSkinExpectedChecksum {
  param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$AssetName
  )
  $matches = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($Manifest -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $entry = [regex]::Match($line, '^([0-9A-Fa-f]{64}) [ *](.+)$')
    if (-not $entry.Success) {
      throw '发布文件校验清单的格式不正确。'
    }
    if ($entry.Groups[2].Value -ceq $AssetName) {
      $matches.Add($entry.Groups[1].Value.ToLowerInvariant())
    }
  }
  if ($matches.Count -ne 1) {
    throw "更新文件的校验信息缺失或重复：$AssetName"
  }
  return $matches[0]
}

function Assert-DreamSkinInstallerChecksum {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedHash
  )
  if ($ExpectedHash -cnotmatch '^[0-9a-f]{64}$') {
    throw '安装包预期的文件校验值无效。'
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw '下载的安装包不存在，请重新下载。'
  }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw '下载的安装包不能是文件链接，请重新下载原始文件。'
  }
  if ($item.Length -le 0 -or $item.Length -gt $script:DreamSkinMaximumInstallerBytes) {
    throw '下载的安装包大小异常，请重新下载。'
  }
  $actualHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne $ExpectedHash) {
    throw '下载的安装包未通过完整性校验，请重新下载。'
  }
}

function Assert-DreamSkinPlainDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "更新目录不能使用链接文件夹：$Path"
  }
}

function Invoke-DreamSkinUpdateDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds
  )
  $null = Invoke-WebRequest -Uri $Url -Headers @{
    Accept = 'application/octet-stream'
    'User-Agent' = 'CodexDreamSkinManager'
  } -Method Get -UseBasicParsing -TimeoutSec $TimeoutSeconds -OutFile $Destination
}

function Get-DreamSkinLatestRelease {
  $headers = @{ Accept = 'application/json'; 'User-Agent' = 'CodexDreamSkinManager'; 'Cache-Control' = 'no-cache' }
  try {
    $response = Invoke-WebRequest -Uri $script:DreamSkinUpdateManifestUrl -Headers $headers `
      -Method Get -UseBasicParsing -TimeoutSec 12 -MaximumRedirection 5
  } catch {
    $reason = ConvertTo-DreamSkinDisplayMessage -Message $_.Exception.Message
    throw "无法获取更新信息，请检查网络后重试。也可访问发布页面：$script:DreamSkinReleasePage 。$reason"
  }
  if ($response.RawContentLength -le 0 -or $response.RawContentLength -gt 1MB) {
    throw '更新信息的文件大小异常。'
  }
  # Release attachments may be served as application/octet-stream.
  $content = $response.Content
  if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
  $release = $content | ConvertFrom-Json
  if ($release.schemaVersion -ne 1) { throw '当前管理器不支持此更新信息格式。' }
  if ($release.draft -isnot [bool] -or $release.prerelease -isnot [bool]) {
    throw '更新信息缺少正式发布状态。'
  }
  return $release
}

function Install-DreamSkinUpdate {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [string]$Expected = ''
  )
  if (-not $Result.updateAvailable) { throw '当前已是最新版本，无需安装更新。' }
  if ($Expected) {
    $expectedParsed = ConvertTo-DreamSkinVersion -Value $Expected
    if (('v' + $expectedParsed.ToString()) -cne "$($Result.latestVersion)") {
      throw "最新版本已从 $Expected 变为 $($Result.latestVersion)，请重新检查更新。"
    }
  }

  Assert-DreamSkinPlainDirectory -Path $script:DreamSkinStateRoot
  $updatesRoot = Join-Path $script:DreamSkinStateRoot 'updates'
  Assert-DreamSkinPlainDirectory -Path $updatesRoot
  $downloadRoot = Join-Path $updatesRoot (
    $Result.latestVersion + '-' + [guid]::NewGuid().ToString('N'))
  [void][System.IO.Directory]::CreateDirectory($downloadRoot)
  Assert-DreamSkinPlainDirectory -Path $downloadRoot
  $checksumPath = Join-Path $downloadRoot 'SHA256SUMS.txt'
  $installerDownload = Join-Path $downloadRoot ($Result.installerAssetName + '.download')
  $installerPath = Join-Path $downloadRoot $Result.installerAssetName
  $keepDownload = $false
  try {
    Invoke-DreamSkinUpdateDownload -Url $Result.checksumAssetUrl -Destination $checksumPath -TimeoutSeconds 30
    $checksumItem = Get-Item -LiteralPath $checksumPath -Force
    if (($checksumItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      $checksumItem.Length -le 0 -or $checksumItem.Length -gt $script:DreamSkinMaximumChecksumBytes) {
      throw '文件校验清单的大小或类型异常。'
    }
    $manifest = [System.IO.File]::ReadAllText($checksumItem.FullName, [System.Text.Encoding]::UTF8)
    $expectedHash = Get-DreamSkinExpectedChecksum -Manifest $manifest -AssetName $Result.installerAssetName
    if ($Result.installerSha256 -and $expectedHash -cne $Result.installerSha256) {
      throw '更新信息与文件校验清单中的安装包校验值不一致。'
    }
    Invoke-DreamSkinUpdateDownload -Url $Result.installerAssetUrl -Destination $installerDownload -TimeoutSeconds 180
    Assert-DreamSkinInstallerChecksum -Path $installerDownload -ExpectedHash $expectedHash
    Move-Item -LiteralPath $installerDownload -Destination $installerPath
    Assert-DreamSkinInstallerChecksum -Path $installerPath -ExpectedHash $expectedHash
    $process = Start-Process -FilePath $installerPath -WorkingDirectory $downloadRoot -PassThru
    if ($null -eq $process -or $process.Id -le 0) { throw '安装包已通过校验，但安装程序未能启动。' }
    $keepDownload = $true
    $Result.installerStarted = $true
    $Result.installerProcessId = $process.Id
    return $Result
  } finally {
    if (-not $keepDownload) {
      Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Confirm-DreamSkinInteractiveUpdate {
  param([Parameter(Mandatory = $true)][object]$Result)
  Add-Type -AssemblyName System.Windows.Forms
  if (-not $Result.updateAvailable) {
    [void][System.Windows.Forms.MessageBox]::Show(
      (Get-DreamSkinUpdateText -Key 'UpToDate' -FormatArguments @($Result.currentVersion)),
      (Get-DreamSkinUpdateText -Key 'UpdateTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
    return $false
  }
  $choice = [System.Windows.Forms.MessageBox]::Show(
    ((Get-DreamSkinUpdateText -Key 'UpdateAvailable' -FormatArguments @($Result.latestVersion)) +
      [Environment]::NewLine + [Environment]::NewLine +
      (Get-DreamSkinUpdateText -Key 'UpdateQuestion')),
    (Get-DreamSkinUpdateText -Key 'UpdateTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
  return $choice -eq [System.Windows.Forms.DialogResult]::Yes
}

function Invoke-DreamSkinUpdateMain {
  if (-not (Test-Path -LiteralPath $script:DreamSkinVersionPath -PathType Leaf)) {
    throw "已安装版本的信息文件缺失：$script:DreamSkinVersionPath"
  }
  $currentText = ([System.IO.File]::ReadAllText($script:DreamSkinVersionPath)).Trim()
  $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Get-DreamSkinLatestRelease
    $result = ConvertTo-DreamSkinUpdateResult -Release $release -CurrentVersionText $currentText
    $shouldInstall = $Install
    if ($Interactive) { $shouldInstall = Confirm-DreamSkinInteractiveUpdate -Result $result }
    if ($shouldInstall) {
      $result = Install-DreamSkinUpdate -Result $result -Expected $ExpectedVersion
    }
    if ($Json) { $result | ConvertTo-Json -Compress }
    if (-not $Json -and -not $Interactive) {
      $availability = if ($result.updateAvailable) { '有新版本' } else { '已是最新版本' }
      $started = if ($result.installerStarted) { '安装程序已启动' } else { '安装程序未启动' }
      Write-Host "当前版本 $($result.currentVersion)，最新版本 $($result.latestVersion)；$availability；$started"
    }
  } finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  try {
    Invoke-DreamSkinUpdateMain
  } catch {
    if ($Json) {
      [pscustomobject]@{ error = $_.Exception.Message; releaseUrl = $script:DreamSkinReleasePage } |
        ConvertTo-Json -Compress
    }
    if ($Interactive) {
      Add-Type -AssemblyName System.Windows.Forms
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-DreamSkinUpdateText -Key 'UpdateFailed') + [Environment]::NewLine +
          [Environment]::NewLine + (ConvertTo-DreamSkinDisplayMessage -Message $_.Exception.Message)),
        (Get-DreamSkinUpdateText -Key 'UpdateTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      )
    }
    throw
  }
}
