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
  (планировщик не отображает сообщения скрипта в интерактивной консоли).

.PARAMETER Server
  Экземпляр SQL Server на этой машине.
.PARAMETER Database
  Имя базы 1С.
.PARAMETER OutDir
  Папка для JSON-файлов. По умолчанию data/snapshots рядом с комплектом.
#>
[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory, ParameterSetName = 'Direct')] [ValidateLength(1, 128)] [string]$Database,
    [Parameter(Mandatory, ParameterSetName = 'FromTask', DontShow)] [string]$DatabaseBase64,
    [string]$OutDir
)

if ($PSCmdlet.ParameterSetName -eq 'FromTask') {
    $Database = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($DatabaseBase64))
}
if ([string]::IsNullOrWhiteSpace($Database) -or $Database.Length -gt 128) {
    throw 'Укажите действительное имя базы 1С.'
}
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'data\snapshots' }

$ErrorActionPreference = 'Stop'

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
    exit 1
}

# Загрузить System.Data — на PS 5.1 это System.Data.SqlClient (built-in).
Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

$sqlText = Get-Content -LiteralPath $sqlFile -Raw -Encoding UTF8
$connection = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$connection.DataSource = $Server
$connection.InitialCatalog = 'master'
$connection.IntegratedSecurity = $true
$connection.ConnectTimeout = 10
$connection.ApplicationName = 'anamnesis-watcher'

$conn = $null
$jsonText = $null

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connection.ConnectionString)
    $conn.Open()

    $cmd = $conn.CreateCommand()
    $cmd.CommandTimeout = 30  # сек, на FOR JSON по dm_*-вьюхам обычно <1 сек
    $cmd.CommandText = $sqlText
    $cmd.Parameters.Add('@database', [System.Data.SqlDbType]::NVarChar, 128).Value = $Database

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
    exit 1
} catch {
    Write-Log ERROR "ADO.NET error: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    exit 1
} finally {
    if ($conn -and $conn.State -ne 'Closed') {
        try { $conn.Close() } catch { }
    }
    if ($conn) { $conn.Dispose() }
}

if ([string]::IsNullOrWhiteSpace($jsonText)) {
    Write-Log ERROR "запрос вернул пустой результат (jsonText='')"
    exit 1
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
    exit 1
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
    exit 1
}

Write-Output $outFile
