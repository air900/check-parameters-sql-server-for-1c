<#
.SYNOPSIS
  Установщик Anamnesis Kit — длительное наблюдение за расчётом.

.DESCRIPTION
  Скачивает последний релизный архив anamnesis-kit с GitHub Releases,
  распаковывает в указанную папку, печатает дальнейшие шаги.

.PARAMETER RootPath
  Куда установить (default: C:\Anamnesis).

.PARAMETER Version
  Конкретная версия (default — latest).

.EXAMPLE
  irm https://raw.githubusercontent.com/air900/check-parameters-sql-server-for-1c/main/install-anamnesis.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$RootPath = 'C:\Anamnesis',
    [string]$Version = 'latest'
)

$ErrorActionPreference = 'Stop'

$repo = 'air900/check-parameters-sql-server-for-1c'
$assetName = 'anamnesis-kit.zip'

if ($Version -eq 'latest') {
    $releaseApi = "https://api.github.com/repos/$repo/releases/latest"
} else {
    $releaseApi = "https://api.github.com/repos/$repo/releases/tags/$Version"
}

Write-Output "Запрашиваю $releaseApi ..."
$release = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'install-anamnesis' }
$asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
if (-not $asset) {
    throw "Не найден ассет $assetName в релизе $($release.tag_name)"
}

if (-not (Test-Path $RootPath)) {
    New-Item -ItemType Directory -Force -Path $RootPath | Out-Null
}

$zipPath = Join-Path $env:TEMP "anamnesis-kit-$($release.tag_name).zip"
Write-Output "Скачиваю $($asset.browser_download_url) → $zipPath"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

Write-Output "Распаковываю в $RootPath"
Expand-Archive -Path $zipPath -DestinationPath $RootPath -Force
Remove-Item $zipPath

# Создать папки для runtime-данных
$dataDir = Join-Path $RootPath 'data'
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'snapshots') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'xe') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'archives') | Out-Null

Write-Output ""
Write-Output "=== Anamnesis Kit установлен в $RootPath ==="
Write-Output ""
Write-Output "Дальнейшие шаги:"
Write-Output "  1. Прочитайте README.md в $RootPath"
Write-Output "  2. Один раз настройте SQL Server:"
Write-Output "     sqlcmd -S MSSQL-TEST -i $RootPath\setup\01-enable-query-store.sql -v db=eshn_test1"
Write-Output "     sqlcmd -S MSSQL-TEST -i $RootPath\setup\02-set-blocked-process-threshold.sql"
Write-Output "     sqlcmd -S MSSQL-TEST -i $RootPath\setup\03-create-xe-session.sql -v db=eshn_test1"
Write-Output "  3. Перед расчётом запустите watcher:"
Write-Output "     $RootPath\watcher\Start-Watcher.ps1 -Hours 8 -Database eshn_test1"
Write-Output "  4. После расчёта:"
Write-Output "     $RootPath\watcher\Stop-Watcher.ps1"
Write-Output "     $RootPath\upload\Upload-Archive.ps1 -Database eshn_test1"
