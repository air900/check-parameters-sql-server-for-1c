<#
.SYNOPSIS
  Упаковать снимки в tar.gz и отправить на бэкенд anamnesis.

.DESCRIPTION
  Создаёт session-yyyyMMdd-HHmmss.tar.gz с manifest.json + всеми
  snap-*.json из SnapshotDir. POST на /api/v1/anamnesis/upload.
  Печатает session_id и постоянную ссылку на отчёт.

  PowerShell 5.1 совместимо. Использует tar.exe (есть в Win10 1803+).

.PARAMETER SnapshotDir
  Папка со снимками (default: C:\Anamnesis\data\snapshots).

.PARAMETER ArchiveDir
  Папка для временных tar.gz архивов (default: C:\Anamnesis\data\archives).

.PARAMETER ApiUrl
  URL бэкенда. По умолчанию читается из project.json в корне kit'а.

.PARAMETER ClientEmail
  Email клиента для опционального связывания.

.PARAMETER Hostname
  Имя сервера (default — текущий hostname).

.PARAMETER Database
  Имя БД, под которой шёл расчёт.

.PARAMETER KitVersion
  Версия kit'а (для записи в manifest).
#>
[CmdletBinding()]
param(
    [string]$SnapshotDir = 'C:\Anamnesis\data\snapshots',
    [string]$ArchiveDir = 'C:\Anamnesis\data\archives',
    [string]$ApiUrl,
    [string]$ClientEmail,
    [string]$Hostname = $env:COMPUTERNAME,
    [string]$Database = 'eshn_test1',
    [string]$KitVersion = '1.0.0'
)

$ErrorActionPreference = 'Stop'

# 1. Загрузить ApiUrl если не передан
if (-not $ApiUrl) {
    $kitRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $projectJson = Join-Path $kitRoot 'project.json'
    if (Test-Path $projectJson) {
        $config = Get-Content $projectJson -Raw | ConvertFrom-Json
        $ApiUrl = $config.api_url
    }
    if (-not $ApiUrl) {
        throw "ApiUrl не задан и project.json не найден"
    }
}

# 2. Проверить snapshot dir
if (-not (Test-Path $SnapshotDir)) {
    throw "SnapshotDir не существует: $SnapshotDir"
}
$snapFiles = Get-ChildItem -Path $SnapshotDir -Filter 'snap-*.json'
if ($snapFiles.Count -lt 2) {
    throw "В $SnapshotDir меньше 2 снимков (нужно минимум 2 для дельты)"
}

# 3. Сгенерировать manifest.json
$manifest = [ordered]@{
    session_uuid = [guid]::NewGuid().ToString()
    kit_version = $KitVersion
    client_email = $ClientEmail
    hostname = $Hostname
    database = $Database
    snapshot_count = $snapFiles.Count
    created_at = (Get-Date).ToUniversalTime().ToString('o')
}
$manifestPath = Join-Path $SnapshotDir 'manifest.json'
$manifest | ConvertTo-Json | Set-Content -Encoding UTF8 -Path $manifestPath

# 4. Упаковать в tar.gz
$ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
$archivePath = Join-Path $ArchiveDir "session-$ts.tar.gz"
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
& tar.exe -czf $archivePath -C $SnapshotDir snap-*.json manifest.json
if ($LASTEXITCODE -ne 0) {
    throw "tar упал с кодом $LASTEXITCODE"
}

# 5. Отправить (curl.exe — PS 5.1 совместимо; Invoke-RestMethod -Form требует PS 6.1+)
$curl = Get-Command -Name curl.exe -ErrorAction SilentlyContinue
if (-not $curl) {
    throw "curl.exe не найден. Требуется Windows Server 2019+ / Windows 10 1803+."
}

Write-Output "Отправляю $archivePath на $ApiUrl/anamnesis/upload ..."
$rawResponse = & curl.exe -sS --fail `
    -X POST `
    -F "archive=@${archivePath};type=application/gzip" `
    "$ApiUrl/anamnesis/upload" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "curl.exe упал с кодом $LASTEXITCODE. Вывод: $rawResponse"
}
$response = $rawResponse | ConvertFrom-Json

# 6. Показать результат
Write-Output ""
Write-Output "=== Сессия отправлена ==="
Write-Output "ID:               $($response.session_id)"
Write-Output "Главный вердикт:  $($response.summary.primary_verdict)"
Write-Output "Все вердикты:     $($response.verdicts -join ', ')"
Write-Output "Постоянная ссылка:"
Write-Output "  $($response.report_url)"
Write-Output ""

# 7. Удалить архив — он уже на бэкенде
Remove-Item $archivePath
Write-Output "Архив удалён: $archivePath"
