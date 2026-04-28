<#
.SYNOPSIS
  Один снимок состояния SQL Server для anamnesis-watcher'а.
.DESCRIPTION
  Запускает Snapshot-OneShot.sql через Invoke-Sqlcmd и сохраняет
  результат как один JSON-файл с фиксированной schema из 7 секций.
  PowerShell 5.1 совместимо.
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

# Запустить SQL и получить 7 столбцов
try {
    $row = Invoke-Sqlcmd `
        -ServerInstance $Server `
        -InputFile $sqlFile `
        -Variable "db=$Database" `
        -MaxCharLength 2147483647 `
        -QueryTimeout 30
} catch {
    Write-Warning "Snapshot failed at $ts : $_"
    return
}

# Собрать в фиксированный JSON
$snapshot = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    server = $Server
    database = $Database
    requests = (ConvertFrom-Json $row.requests)
    waits = (ConvertFrom-Json $row.waits)
    locks = (ConvertFrom-Json $row.locks)
    memory_grants = (ConvertFrom-Json $row.memory_grants)
    tempdb_usage = (ConvertFrom-Json $row.tempdb_usage)
    blocking = (ConvertFrom-Json $row.blocking)
    qstore_top = (ConvertFrom-Json $row.qstore_top)
}

# ConvertFrom-Json возвращает $null для пустого "[]" — заменим на пустой массив
foreach ($k in @('requests','waits','locks','memory_grants','tempdb_usage','blocking','qstore_top')) {
    if ($null -eq $snapshot[$k]) { $snapshot[$k] = @() }
    elseif ($snapshot[$k] -isnot [array]) { $snapshot[$k] = @($snapshot[$k]) }
}

$snapshot | ConvertTo-Json -Depth 10 -Compress | Set-Content -Encoding UTF8 -Path $outFile
Write-Output $outFile
