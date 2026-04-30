<#
.SYNOPSIS
  Один снимок состояния SQL Server для anamnesis-watcher'а.
.DESCRIPTION
  Выполняет Snapshot-OneShot.sql напрямую через .NET ADO.NET
  (System.Data.SqlClient) — без sqlcmd.exe и без модуля SqlServer.

  Почему не sqlcmd:
    - SQL Server при FOR JSON > 2033 символов сам разбивает результат
      на N строк (документированное поведение). sqlcmd печатает их с
      переносами и пробельным padding'ом — обратная сборка хрупкая.
    - sqlcmd сочетания флагов (-h -1 / -W / -y/-Y / -w) конфликтуют
      между собой и поведение зависит от версии sqlcmd.
    - SqlDataReader отдаёт чистые строки колонки — конкатенация
      детерминированна.

  Все шаги пишутся в watcher.log рядом с папкой снимков
  (под scheduled task / SYSTEM Write-Warning невидим).

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

# НЕ Stop — иначе любая ошибка убивает процесс ДО записи в лог.
$ErrorActionPreference = 'Continue'

$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')

$logDir = Split-Path -Parent $OutDir
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir 'watcher.log'

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} {1} [snap-{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $ts, $Message
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

Write-Log INFO "START server=$Server db=$Database outdir=$OutDir"

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$outFile = Join-Path $OutDir "snap-$ts.json"
$scriptDir = Split-Path -Parent $PSCommandPath
$sqlFile = Join-Path $scriptDir 'Snapshot-OneShot.sql'

if (-not (Test-Path $sqlFile)) {
    Write-Log ERROR "SQL-файл не найден: $sqlFile"
    return
}

# Загрузить System.Data — на PS 5.1 это System.Data.SqlClient (built-in).
Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

# Загрузить SQL и подставить sqlcmd-стиль переменную $(db) → $Database.
# В файле есть только одна такая переменная, GO-разделителей нет (одна batch).
$sqlText = Get-Content -Path $sqlFile -Raw -Encoding UTF8
$sqlText = $sqlText -replace '\$\(db\)', $Database

$connStr = "Server=$Server;Database=master;Integrated Security=True;Connection Timeout=10;Application Name=anamnesis-watcher"
$conn = $null
$jsonText = $null

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()

    $cmd = $conn.CreateCommand()
    $cmd.CommandTimeout = 30  # сек, на FOR JSON по dm_*-вьюхам обычно <1 сек
    $cmd.CommandText = $sqlText

    # FOR JSON разбивается SQL Server'ом на N строк по 2033 символа,
    # каждая строка = одна row, одна column. Собираем подряд.
    $reader = $cmd.ExecuteReader()
    try {
        $sb = New-Object System.Text.StringBuilder
        while ($reader.Read()) {
            $val = $reader.GetValue(0)
            if ($val -ne $null -and $val -isnot [System.DBNull]) {
                [void]$sb.Append([string]$val)
            }
        }
        $jsonText = $sb.ToString()
    } finally {
        $reader.Close()
        $reader.Dispose()
    }
} catch [System.Data.SqlClient.SqlException] {
    # SqlException даёт нам всю SQL-ошибку точно (Msg, severity, state, line)
    $sqlEx = $_.Exception
    Write-Log ERROR ("SqlException Number={0} Class={1} State={2} Line={3} : {4}" -f `
        $sqlEx.Number, $sqlEx.Class, $sqlEx.State, $sqlEx.LineNumber, $sqlEx.Message)
    return
} catch {
    Write-Log ERROR "ADO.NET error: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    return
} finally {
    if ($conn -and $conn.State -ne 'Closed') {
        try { $conn.Close() } catch { }
    }
    if ($conn) { $conn.Dispose() }
}

if ([string]::IsNullOrWhiteSpace($jsonText)) {
    Write-Log ERROR "запрос вернул пустой результат (jsonText='')"
    return
}

# Парсинг — ConvertFrom-Json. На fail сохраняем сырое для разбора.
$parsed = $null
try {
    $parsed = $jsonText | ConvertFrom-Json
} catch {
    Write-Log ERROR "ConvertFrom-Json failed: $($_.Exception.Message) (length=$($jsonText.Length))"
    $rawCopy = Join-Path $logDir "raw-$ts.json"
    try { Set-Content -Path $rawCopy -Value $jsonText -Encoding UTF8 } catch { }
    Write-Log INFO "Сырой JSON сохранён в $rawCopy"
    return
}

# Собираем фиксированный snapshot-объект
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

# ConvertFrom-Json возвращает $null для "[]" — заменим на пустой массив
foreach ($k in @('requests','waits','locks','memory_grants','tempdb_usage','blocking','qstore_top')) {
    if ($null -eq $snapshot[$k]) { $snapshot[$k] = @() }
    elseif ($snapshot[$k] -isnot [array]) { $snapshot[$k] = @($snapshot[$k]) }
}

try {
    $json = $snapshot | ConvertTo-Json -Depth 10 -Compress
    # Без BOM — Python json.loads() не принимает UTF-8 BOM
    [System.IO.File]::WriteAllText($outFile, $json, [System.Text.UTF8Encoding]::new($false))
    $size = (Get-Item $outFile).Length
    Write-Log INFO "OK wrote $outFile size=$size bytes"

    # Подметаем raw-*.out / raw-*.json от прошлых упавших запусков —
    # успешный snapshot означает что предыдущая диагностика устарела.
    Get-ChildItem -Path $logDir -Filter 'raw-*.out' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter 'raw-*.json' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {
    Write-Log ERROR "запись в $outFile упала: $($_.Exception.Message)"
    return
}

Write-Output $outFile
