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

.EXAMPLE
  irm https://raw.githubusercontent.com/air900/check-parameters-sql-server-for-1c/main/install-anamnesis.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$RootPath = 'C:\Anamnesis',
    [string]$Version = 'latest',
    [string]$SqlServer = 'localhost'
)

$ErrorActionPreference = 'Stop'

# PS 5.1 default is TLS 1.0 / 1.1; GitHub requires TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'air900/check-parameters-sql-server-for-1c'

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

# 5. Force-refresh: every install starts from a clean slate.
#
# Why full wipe instead of merge:
#   - The kit is a diagnostic tool, not a data store. Past snapshots/archives
#     belong to a finished diagnostic session and should not bleed into the next.
#   - Copy-Item -Force only overwrites EXISTING files; stale leftovers from a
#     prior install (corrupt or older-format) survive and silently break the
#     watcher (we hit exactly this in v2.11.12 -> v2.11.13: stale
#     Snapshot-OneShot.ps1 made Task Scheduler report success while producing
#     zero snapshots).
#
# Order matters: stop+unregister the running task BEFORE wiping the directory,
# otherwise the in-flight powershell.exe instance can still hold a file handle
# on watcher\Snapshot-OneShot.ps1 and Remove-Item fails with "in use".

$taskName = '_DiagEshnWatcher'
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Output "Stopping existing scheduled task $taskName ..."
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

# 5.1 Stop the XE session that the kit's setup option 2 leaves running.
# Without this, data\xe\*.xel is held open by sqlservr.exe and Remove-Item
# fails with IOException. The kit creates the session, the kit stops it.
#
# Default SqlServer is 'localhost' because the XE session writes to a local
# path (C:\Anamnesis\data\xe\), so SQL Server must be on this machine. For
# named instances the user can pass -SqlServer 'HOST\INSTANCE' explicitly.
# If sqlcmd is missing or the connection fails we fall through to the
# selective wipe below (it skips data\xe\).
$xeSessionName = '_diag_eshn_hang'
$xeStopped = $false
$sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
if ($sqlcmd) {
    $stopSql = "IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name='$xeSessionName') BEGIN PRINT 'Stopping XE'; ALTER EVENT SESSION [$xeSessionName] ON SERVER STATE = STOP; END; IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name='$xeSessionName') BEGIN PRINT 'Dropping XE'; DROP EVENT SESSION [$xeSessionName] ON SERVER; END;"
    Write-Output "Stopping XE session $xeSessionName on $SqlServer ..."
    & sqlcmd.exe -S $SqlServer -E -b -Q $stopSql
    if ($LASTEXITCODE -eq 0) {
        $xeStopped = $true
        Start-Sleep -Seconds 1  # let sqlservr.exe release the .xel file handle
    } else {
        Write-Output "  (sqlcmd exit=$LASTEXITCODE -- preserving data\xe\ to avoid in-use error)"
    }
} else {
    Write-Output "sqlcmd.exe not in PATH -- preserving data\xe\ to avoid in-use error."
}

# 5.2 Refresh files. If we successfully stopped the XE session, wipe all of
# RootPath; otherwise wipe everything except data\xe\.
if (Test-Path $RootPath) {
    if ($xeStopped) {
        Write-Output "Wiping $RootPath (full refresh) ..."
        Remove-Item -Recurse -Force $RootPath -ErrorAction SilentlyContinue
        if (Test-Path $RootPath) {
            Start-Sleep -Seconds 2
            Remove-Item -Recurse -Force $RootPath -ErrorAction Stop
        }
    } else {
        Write-Output "Refreshing $RootPath (code + transient data, data\xe\ kept) ..."
        Get-ChildItem -Path $RootPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer -and $_.Name -eq 'data') {
                Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Name -ne 'xe') {
                        Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
                    }
                }
            } else {
                Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
            }
        }
    }
}

if (-not (Test-Path $RootPath)) {
    New-Item -ItemType Directory -Force -Path $RootPath | Out-Null
}

Get-ChildItem -Path $anamnesisSrc.FullName | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $RootPath -Recurse -Force
}

# 6. Copy project.json (api_url + version) -- it lives 2 levels above anamnesis.
$repoRoot = Split-Path (Split-Path $anamnesisSrc.FullName -Parent) -Parent
$projectJson = Join-Path $repoRoot 'project.json'
if (Test-Path $projectJson) {
    Copy-Item $projectJson -Destination $RootPath -Force
}

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

# Sanity check: confirm the freshly-installed snapshot script declares -OutDir.
# A prior bug left stale files behind, causing Task Scheduler to silently fail
# with NamedParameterNotFound. If we see that the param block is wrong here,
# stop early so the menu doesn't even start.
$snapPs1 = Join-Path $RootPath 'watcher\Snapshot-OneShot.ps1'
if (Test-Path $snapPs1) {
    $snapHead = Get-Content -Path $snapPs1 -Raw -Encoding UTF8
    if ($snapHead -notmatch '\[string\]\$OutDir') {
        Write-Output "WARNING: $snapPs1 does NOT declare -OutDir. Install is broken."
        Write-Output "Try: Remove-Item -Recurse -Force $RootPath ; then re-run installer."
    } else {
        Write-Output "Sanity check: Snapshot-OneShot.ps1 declares -OutDir [OK]"
    }
}

# 9. Auto-run interactive menu (it is on disk now -- BOM and Cyrillic work fine).
$runScript = Join-Path $RootPath 'Run-Anamnesis.ps1'
if (Test-Path $runScript) {
    Write-Output ""
    Write-Output "Launching interactive menu..."
    Start-Sleep -Seconds 1
    & $runScript -RootPath $RootPath
} else {
    Write-Output ""
    Write-Output "To run the menu manually:"
    Write-Output "  $runScript"
    Write-Output ""
    Write-Output "(Run-Anamnesis.ps1 not found in archive -- old kit version?)"
}
