<#
.SYNOPSIS
  Один снимок состояния SQL Server для anamnesis-watcher'а.
.DESCRIPTION
  Запускает Snapshot-OneShot.sql через sqlcmd.exe и сохраняет
  результат как один JSON-файл с фиксированной schema из 7 секций.
  PowerShell 5.1 совместимо. Не требует модуля SqlServer.
.PARAMETER Server
  Адрес SQL Server (default: localhost).
.PARAMETER Database
  Имя БД для snapshot'а (default: eshn_test1).
.PARAMETER OutDir
  Папка для JSON-файлов (default: C:\Anamnesis\data\snapshots).
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Database = 'eshn_test1',
    [string]$OutDir = 'C:\Anamnesis\data\snapshots'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$outFile = Join-Path $OutDir "snap-$ts.json"

$scriptDir = Split-Path -Parent $PSCommandPath
$sqlFile = Join-Path $scriptDir 'Snapshot-OneShot.sql'

if (-not (Test-Path $sqlFile)) {
    throw "Не найден SQL-файл: $sqlFile"
}

# Запустить SQL через sqlcmd.exe (не требует модуля SqlServer)
$sqlcmdExe = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $sqlcmdExe) {
    Write-Warning "sqlcmd.exe не найден в PATH — snapshot пропущен ($ts)"
    return
}

$tempOut = Join-Path $env:TEMP "snap-$ts.json"
try {
    # SQL возвращает один JSON-объект с 7 ключами (FOR JSON PATH, WITHOUT_ARRAY_WRAPPER).
    # -f o:65001 — UTF-8 вывод, -h -1 — без заголовков, -W — без trailing spaces,
    # -y 0 -Y 0 — NVARCHAR(MAX) без усечения, -b — exit-on-error.
    & sqlcmd.exe -S $Server -d master -i $sqlFile -v "db=$Database" `
        -f o:65001 -h -1 -W -y 0 -Y 0 -b -o $tempOut
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "sqlcmd упал (exit=$LASTEXITCODE) при snapshot $ts"
        return
    }
    $raw = Get-Content -Path $tempOut -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Warning "Snapshot SQL вернул пустой результат ($ts)"
        return
    }
    $parsed = $raw.Trim() | ConvertFrom-Json
} catch {
    Write-Warning "Snapshot failed at $ts : $_"
    return
} finally {
    Remove-Item $tempOut -ErrorAction SilentlyContinue
}

# Собрать в фиксированный JSON
$snapshot = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    server = $Server
    database = $Database
    requests = $parsed.requests
    waits = $parsed.waits
    locks = $parsed.locks
    memory_grants = $parsed.memory_grants
    tempdb_usage = $parsed.tempdb_usage
    blocking = $parsed.blocking
    qstore_top = $parsed.qstore_top
}

# ConvertFrom-Json возвращает $null для пустого "[]" — заменим на пустой массив
foreach ($k in @('requests','waits','locks','memory_grants','tempdb_usage','blocking','qstore_top')) {
    if ($null -eq $snapshot[$k]) { $snapshot[$k] = @() }
    elseif ($snapshot[$k] -isnot [array]) { $snapshot[$k] = @($snapshot[$k]) }
}

# Записать без BOM — Python json.loads() не принимает UTF-8 BOM
$json = $snapshot | ConvertTo-Json -Depth 10 -Compress
[System.IO.File]::WriteAllText($outFile, $json, [System.Text.UTF8Encoding]::new($false))
Write-Output $outFile
