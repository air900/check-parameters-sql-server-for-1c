<#
.SYNOPSIS
  Installer for Anamnesis Kit (long-running watch over SQL Server during 1C calculation).

.DESCRIPTION
  Downloads the latest GitHub release zip, extracts only scripts/anamnesis/* and
  project.json into RootPath. Creates data\snapshots, data\xe, data\archives
  for runtime artifacts. Then auto-runs the interactive menu Run-Anamnesis.ps1.

  This file is intentionally ASCII-only because it is intended to be invoked via
  `irm <url> | iex` -- Invoke-RestMethod returns the body decoded with PowerShell 5.1
  default encoding (system ANSI / cp1251 on Russian Windows), which mangles UTF-8
  Cyrillic regardless of BOM. All localized text lives in Run-Anamnesis.ps1 and
  other kit files which are read from disk with proper BOM handling.

  PowerShell 5.1 compatible.

.PARAMETER RootPath
  Where to install (default: C:\Anamnesis).

.PARAMETER Version
  Specific release tag (default: latest).

.PARAMETER SqlServer
  SQL Server instance. For an upgrade, use the instance monitored by the previous installation.
  If omitted, the installer prompts for it before applying an upgrade.

.PARAMETER Database
  Database to select in the interactive menu. If omitted, the menu prompts for it.

.EXAMPLE
  irm https://raw.githubusercontent.com/air900/check-parameters-sql-server-for-1c/main/install-anamnesis.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$RootPath = 'C:\Anamnesis',
    [string]$Version = 'latest',
    [string]$SqlServer,
    [string]$Database
)

$ErrorActionPreference = 'Stop'

# PS 5.1 default is TLS 1.0 / 1.1; GitHub requires TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'air900/check-parameters-sql-server-for-1c'

$RootPath = [System.IO.Path]::GetFullPath($RootPath)
$snapshotScript = Join-Path $RootPath 'watcher\Snapshot-OneShot.ps1'
$pathPattern = [regex]::Escape($snapshotScript)
$watcher = Get-ScheduledTask -ErrorAction Stop | Where-Object {
    $_.Actions | Where-Object { $_.Arguments -match "(?i)(?:^|\s)-File\s+(?:`"$pathPattern`"|$pathPattern)(?:\s|$)" }
} | Select-Object -First 1
if ($watcher) {
    throw "Scheduled task $($watcher.TaskPath)$($watcher.TaskName) uses this installation. Finish the existing observation and remove the task with the previous kit before running this installer again."
}

if ((Test-Path -LiteralPath $snapshotScript) -or (Test-Path -LiteralPath (Join-Path $RootPath 'Run-Anamnesis.ps1'))) {
    if ([string]::IsNullOrWhiteSpace($SqlServer)) {
        $SqlServer = Read-Host 'SQL Server instance monitored by the current installation'
    }
    if ([string]::IsNullOrWhiteSpace($SqlServer)) {
        throw 'Specify the SQL Server instance with -SqlServer to upgrade this installation.'
    }
    $sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        throw 'Install SQL Server Command Line Utilities (sqlcmd.exe) to verify existing Extended Events sessions before upgrading.'
    }

    $xeDir = (Join-Path $RootPath 'data\xe').TrimEnd('\') + '\'
    $xeDirLiteral = $xeDir.Replace("'", "''")
    $xeSql = @"
SET NOCOUNT ON;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
    THROW 50000, 'Upgrade requires an account in the sysadmin role to verify all active Extended Events sessions.', 1;
DECLARE @directory nvarchar(4000) = N'$xeDirLiteral';
SELECT DISTINCT s.name
FROM sys.server_event_sessions AS s
JOIN sys.dm_xe_sessions AS active ON active.name = s.name
JOIN sys.server_event_session_targets AS t ON t.event_session_id = s.event_session_id
JOIN sys.server_event_session_fields AS f
  ON f.event_session_id = t.event_session_id AND f.object_id = t.target_id
WHERE t.name = N'event_file' AND f.name = N'filename'
  AND LEFT(CONVERT(nvarchar(4000), f.value), LEN(@directory))
      COLLATE Latin1_General_100_CI_AS = @directory;
"@
    $activeSessions = & $sqlcmd.Source -S $SqlServer -d master -E -l 5 -b -h-1 -W -Q $xeSql
    if ($LASTEXITCODE -ne 0) {
        throw "Could not verify Extended Events on $SqlServer. Check the instance name and use an account with permission to read active sessions."
    }
    $activeSessions = @($activeSessions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($activeSessions.Count -gt 0) {
        throw "Extended Events sessions are writing under $xeDir on ${SqlServer}: $($activeSessions -join ', '). Stop those sessions in SQL Server Management Studio, then rerun the installer."
    }
}

# 1. Find the release and any *.zip asset (asset name not hard-coded).
if ($Version -eq 'latest') {
    $releaseApi = "https://api.github.com/repos/$repo/releases/latest"
} else {
    $releaseApi = "https://api.github.com/repos/$repo/releases/tags/$Version"
}

Write-Output "Querying $releaseApi ..."
$release = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'install-anamnesis' }
$asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
if (-not $asset) {
    throw "No zip asset found in release $($release.tag_name)"
}

$tag = $release.tag_name

# 2. Download to temp.
$tempZip = Join-Path $env:TEMP "anamnesis-kit-$tag.zip"
$tempExtract = Join-Path $env:TEMP "anamnesis-kit-extract-$tag"
Write-Output "Downloading $($asset.browser_download_url)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip -UseBasicParsing

# 3. Extract to temp folder.
if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

# 4. Locate scripts/anamnesis (zip layout: scripts/anamnesis/...).
$anamnesisSrc = Get-ChildItem -Path $tempExtract -Recurse -Directory -Filter 'anamnesis' |
    Where-Object { (Split-Path $_.Parent.FullName -Leaf) -eq 'scripts' } |
    Select-Object -First 1
if (-not $anamnesisSrc) {
    throw "scripts/anamnesis folder not found in archive $tempZip"
}

# 5. Update the kit files. Preserve previous snapshots, traces, and archives.
New-Item -ItemType Directory -Force -Path $RootPath | Out-Null
foreach ($name in @('setup', 'watcher', 'upload', 'Run-Anamnesis.ps1', 'README.md')) {
    $source = Join-Path $anamnesisSrc.FullName $name
    Copy-Item -LiteralPath $source -Destination $RootPath -Recurse -Force
}

# 6. Copy project.json (API URL and version).
$repoRoot = Split-Path (Split-Path $anamnesisSrc.FullName -Parent) -Parent
Copy-Item -LiteralPath (Join-Path $repoRoot 'project.json') -Destination $RootPath -Force

# 7. Create data\ subdirs for runtime artifacts.
$dataDir = Join-Path $RootPath 'data'
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'snapshots') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'xe') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'archives') | Out-Null

# 8. Cleanup temp.
Remove-Item -Recurse -Force $tempExtract -ErrorAction SilentlyContinue
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "Anamnesis Kit $tag installed: $RootPath"
Write-Output ""

# 9. Start the interactive menu.
$runScript = Join-Path $RootPath 'Run-Anamnesis.ps1'
Write-Output 'Launching interactive menu...'
& $runScript -RootPath $RootPath -Server $SqlServer -Database $Database
