<#
.SYNOPSIS
  Один снимок состояния SQL Server для anamnesis-watcher'а.
.DESCRIPTION
  Запускает Snapshot-OneShot.sql через sqlcmd.exe и сохраняет
  результат как один JSON-файл с фиксированной schema из 7 секций.
  PowerShell 5.1 совместимо. Не требует модуля SqlServer.

  Все шаги пишутся в watcher.log рядом с папкой снимков —
  потому что под scheduled task / SYSTEM Write-Warning невидим.
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

# Лог-файл: рядом с папкой снимков (data\watcher.log).
# Под SYSTEM Write-Warning никуда не уходит, поэтому всё пишем в файл.
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

$sqlcmdExe = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $sqlcmdExe) {
    Write-Log ERROR "sqlcmd.exe не найден в PATH"
    return
}

$tempOut = Join-Path $env:TEMP "snap-$ts.out"
$tempErr = Join-Path $env:TEMP "snap-$ts.err"

try {
    # ВАЖНО про флаги sqlcmd:
    #   -y 0 -Y 0   NVARCHAR(MAX) без усечения (default 256 — режет JSON > 256 байт).
    #   -w 65535    максимальная длина строки вывода — иначе FOR JSON wrap'ается.
    #   -b          exit-on-error (severity ≥ 11). Без этого Msg 207 даёт exit=0.
    #   -f o:65001  UTF-8 на выходе.
    # НЕ используем -h -1 и -W — конфликтуют с -y/-Y (см. memory: sqlcmd-flag-constellation).
    # Заголовок столбца отрежем сами при парсинге.
    & sqlcmd.exe -S $Server -d master -i $sqlFile -v "db=$Database" `
        -f o:65001 -y 0 -Y 0 -b -w 65535 -o $tempOut 2> $tempErr
    $exitCode = $LASTEXITCODE

    # Прочитать оба потока СРАЗУ — в finally{} они удаляются.
    # sqlcmd пишет SQL-ошибки (Msg ###, Login failed, server doesn't exist)
    # в STDOUT — поэтому при exit≠0 надо смотреть и stdout, и stderr.
    $stdoutText = ''
    $stderrText = ''
    if (Test-Path $tempOut) { $stdoutText = Get-Content -Path $tempOut -Raw -Encoding UTF8 }
    if (Test-Path $tempErr) { $stderrText = Get-Content -Path $tempErr -Raw -Encoding UTF8 }

    if ($stderrText -and $stderrText.Trim()) {
        Write-Log WARN "sqlcmd stderr: $($stderrText.Trim())"
    }

    if ($exitCode -ne 0) {
        Write-Log ERROR "sqlcmd exit=$exitCode"
        # На fail сохраняем ВЕСЬ stdout в лог построчно (короткие сообщения уместятся).
        # Для длинных — отдельный файл. Без этого silent-fail повторяется.
        if ($stdoutText -and $stdoutText.Trim()) {
            $stdoutTrim = $stdoutText.Trim()
            if ($stdoutTrim.Length -le 2000) {
                foreach ($ln in ($stdoutTrim -split "`n")) {
                    if ($ln.Trim()) { Write-Log ERROR "sqlcmd stdout: $($ln.TrimEnd())" }
                }
            } else {
                $rawCopy = Join-Path $logDir "raw-$ts.out"
                try { Copy-Item $tempOut $rawCopy -ErrorAction SilentlyContinue } catch { }
                Write-Log ERROR "sqlcmd stdout (length=$($stdoutTrim.Length)) сохранён в $rawCopy"
            }
        } else {
            Write-Log ERROR "sqlcmd stdout пуст — возможно sqlcmd сам не запустился"
        }
        return
    }

    $rawAll = $stdoutText
    if ([string]::IsNullOrWhiteSpace($rawAll)) {
        Write-Log ERROR "sqlcmd exit=0, но stdout пуст"
        return
    }

    # Из вывода (заголовок + dashes + JSON) извлекаем JSON-объект:
    # от первой '{' до последней '}'. Простой и надёжный способ.
    $startIdx = $rawAll.IndexOf('{')
    $endIdx = $rawAll.LastIndexOf('}')
    if ($startIdx -lt 0 -or $endIdx -le $startIdx) {
        Write-Log ERROR "JSON-объект не найден в выводе sqlcmd (length=$($rawAll.Length))"
        # сохраняем сырой output для анализа
        $rawCopy = Join-Path $logDir "raw-$ts.out"
        try { Copy-Item $tempOut $rawCopy -ErrorAction SilentlyContinue } catch { }
        Write-Log INFO "Сырой вывод сохранён в $rawCopy"
        return
    }

    $rawJson = $rawAll.Substring($startIdx, $endIdx - $startIdx + 1)

    try {
        $parsed = $rawJson | ConvertFrom-Json
    } catch {
        Write-Log ERROR "ConvertFrom-Json failed: $($_.Exception.Message)"
        $rawCopy = Join-Path $logDir "raw-$ts.json"
        try { Set-Content -Path $rawCopy -Value $rawJson -Encoding UTF8 } catch { }
        Write-Log INFO "Сырой JSON сохранён в $rawCopy"
        return
    }
} catch {
    Write-Log ERROR "exception в sqlcmd-блоке: $($_.Exception.Message)"
    return
} finally {
    Remove-Item $tempOut -ErrorAction SilentlyContinue
    Remove-Item $tempErr -ErrorAction SilentlyContinue
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
} catch {
    Write-Log ERROR "запись в $outFile упала: $($_.Exception.Message)"
    return
}

Write-Output $outFile
