<#
.SYNOPSIS
  Упаковать снимки в tar.gz и отправить на бэкенд anamnesis.

.DESCRIPTION
  Создаёт session-yyyyMMdd-HHmmss.tar.gz с manifest.json + всеми
  snap-*.json из SnapshotDir. POST на /api/v1/anamnesis/upload.
  Печатает session_id и постоянную ссылку на отчёт.

  PowerShell 5.1 совместимо. Использует tar.exe (есть в Win10 1803+).

.PARAMETER SnapshotDir
  Папка со снимками. По умолчанию data/snapshots рядом с комплектом.

.PARAMETER ArchiveDir
  Папка для архивов. По умолчанию data/archives рядом с комплектом.

.PARAMETER ApiUrl
  URL бэкенда. По умолчанию читается из project.json в корне kit'а.

.PARAMETER ClientEmail
  Email клиента для опционального связывания.

.PARAMETER Hostname
  Имя Windows-сервера, где работает SQL Server. По умолчанию имя этой машины.

.PARAMETER Server
  Если указан, скрипт проверит, что снимки собраны для этого экземпляра SQL Server.

.PARAMETER Database
  Если указано, скрипт проверит, что снимки собраны для этой базы. Имя для архива берётся из снимков.

.PARAMETER KitVersion
  Версия kit'а (для записи в manifest). По умолчанию читается из project.json
  в корне kit'а — единый источник правды. Не передавайте параметр явно если хотите
  использовать актуальную версию.

#>
[CmdletBinding()]
param(
    [string]$SnapshotDir,
    [string]$ArchiveDir,
    [string]$ApiUrl,
    [string]$ClientEmail,
    [string]$Hostname = [Environment]::MachineName,
    [string]$Database,
    [string]$Server,
    [string]$KitVersion
)

$ErrorActionPreference = 'Stop'

$kitRoot = Split-Path -Parent $PSScriptRoot
if (-not $SnapshotDir) { $SnapshotDir = Join-Path $kitRoot 'data\snapshots' }
if (-not $ArchiveDir) { $ArchiveDir = Join-Path $kitRoot 'data\archives' }

$projectJson = Join-Path $kitRoot 'project.json'
$config = $null
if (Test-Path $projectJson) {
    $config = Get-Content $projectJson -Raw | ConvertFrom-Json
}
if (-not $ApiUrl) {
    if ($config) { $ApiUrl = $config.api_url }
    if (-not $ApiUrl) {
        throw "ApiUrl не задан и project.json не найден"
    }
}
if (-not $KitVersion) {
    if ($config -and $config.anamnesis_kit_version) {
        $KitVersion = $config.anamnesis_kit_version
    } else {
        # Fallback только если project.json отсутствует — это аномалия, но не блокер
        $KitVersion = 'unknown'
    }
}

# 2. Проверить snapshot dir
if (-not (Test-Path -LiteralPath $SnapshotDir -PathType Container)) {
    throw "SnapshotDir не существует: $SnapshotDir"
}
$snapFiles = @(Get-ChildItem -LiteralPath $SnapshotDir -File -Filter 'snap-*.json')
if ($snapFiles.Count -lt 2) {
    throw "В $SnapshotDir меньше 2 снимков (нужно минимум 2 для дельты)"
}

function Get-ComparableServer([string]$Name) {
    return $Name -replace '^(\.|localhost|\(local\)|127\.0\.0\.1)(?=\\|,|$)', [Environment]::MachineName
}

$source = Get-Content -LiteralPath $snapFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($source.server) -or [string]::IsNullOrWhiteSpace($source.database)) {
    throw "В снимке $($snapFiles[0].Name) нет экземпляра SQL Server или имени базы."
}
$sourceServer = Get-ComparableServer $source.server
if ($Server -and (Get-ComparableServer $Server) -ne $sourceServer) {
    throw "Снимки собраны на экземпляре $($source.server). Введите этот экземпляр в меню или укажите каталог снимков при отдельной отправке."
}
if ($Database -and $Database -cne $source.database) {
    throw "Снимки собраны для базы $($source.database). Указана база $Database."
}
foreach ($file in ($snapFiles | Select-Object -Skip 1)) {
    $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-ComparableServer $item.server) -ne $sourceServer -or $item.database -cne $source.database) {
        throw "В $SnapshotDir есть снимки разных экземпляров SQL Server или баз. Разнесите их по папкам перед отправкой."
    }
}

# 3. Сгенерировать manifest.json
$manifest = [ordered]@{
    session_uuid = [guid]::NewGuid().ToString()
    kit_version = $KitVersion
    client_email = $ClientEmail
    hostname = $Hostname
    database = $source.database
    snapshot_count = $snapFiles.Count
    created_at = (Get-Date).ToUniversalTime().ToString('o')
}
$manifestPath = Join-Path $SnapshotDir 'manifest.json'
$manifestJson = $manifest | ConvertTo-Json
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

# 4. Упаковать в tar.gz
$ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
$archivePath = Join-Path $ArchiveDir "session-$ts.tar.gz"
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
$filesToArchive = @($snapFiles.Name) + 'manifest.json'
& tar.exe -czf $archivePath -C $SnapshotDir @filesToArchive
if ($LASTEXITCODE -ne 0) {
    throw "tar упал с кодом $LASTEXITCODE"
}

# 5. Отправить (curl.exe — PS 5.1 совместимо; Invoke-RestMethod -Form требует PS 6.1+)
$curl = Get-Command -Name curl.exe -ErrorAction SilentlyContinue
if (-not $curl) {
    throw "curl.exe не найден. Требуется Windows Server 2019+ / Windows 10 1803+."
}

Write-Output "Отправляю архив $archivePath для $($source.server) / $($source.database) ..."
$rawResponse = & curl.exe -sS --fail `
    -X POST `
    -F "archive=@${archivePath};type=application/gzip" `
    "$ApiUrl/anamnesis/upload"
if ($LASTEXITCODE -ne 0) {
    throw "curl.exe упал с кодом $LASTEXITCODE"
}
$response = $rawResponse | ConvertFrom-Json
if (-not $response.session_id -or -not $response.report_url) {
    throw "Ответ сервиса не содержит ссылку на отчёт. Архив сохранён в $archivePath."
}

# 6. Показать результат
Write-Output ""
Write-Output "Сессия отправлена."
Write-Output "Идентификатор:    $($response.session_id)"
Write-Output "Постоянная ссылка:"
Write-Output "  $($response.report_url)"
Write-Output ""

# 7. Удалить архив — он уже на бэкенде
Remove-Item $archivePath
Write-Output "Архив удалён: $archivePath"
