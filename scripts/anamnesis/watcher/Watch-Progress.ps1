<#
.SYNOPSIS
  Live-прогресс watcher'а в отдельном PowerShell окне.

.DESCRIPTION
  Запускается из Run-Anamnesis.ps1 → Start-Process powershell.exe -File.
  Каждые 5 сек обновляет: статус scheduled task, LastTaskResult,
  число и возраст снимков, последние строки watcher.log.

  Цветовая индикация:
    Task state Running     — голубой (выполняется)
    Task state Ready       — зелёный, если последний снимок свежий
    Task state Disabled/?  — красный
    Возраст снимка > 2×interval — красный (watcher молча падает)

  Закрытие окна не отменяет работу watcher'а — task в Windows Scheduler
  идёт независимо. PowerShell 5.1 совместимо.

.PARAMETER RootPath
  Корень комплекта с каталогом data\snapshots\.
.PARAMETER IntervalSec
  Ожидаемый интервал между снимками (для подсветки stale). Default 60.
#>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [int]$IntervalSec = 60
)

$ErrorActionPreference = 'SilentlyContinue'

$snapshotsDir = Join-Path $RootPath 'data\snapshots'
$logFile = Join-Path $RootPath 'data\watcher.log'

while ($true) {
    Clear-Host
    Write-Host 'Наблюдение за SQL Server' -ForegroundColor Cyan
    Write-Host (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host ''

    # 1) Scheduled task — состояние и последний результат запуска
    $task = Get-ScheduledTask -TaskName '_Diag1CAnamnesisWatcher' -TaskPath '\' -ErrorAction SilentlyContinue
    $info = if ($task) { $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue } else { $null }
    if ($task) {
        $state = switch ($task.State) {
            'Running'  { 'идёт сбор снимка' }
            'Ready'    { 'готова к запуску' }
            'Queued'   { 'в очереди' }
            'Disabled' { 'отключена' }
            default    { "состояние неизвестно ($($task.State))" }
        }
        Write-Host "Задача в планировщике: $state"
        if ($info) {
            Write-Host ('Последний запуск: {0:dd.MM.yyyy HH:mm:ss}. Код планировщика: 0x{1:X}' -f $info.LastRunTime, $info.LastTaskResult)
            if ($info.NextRunTime -gt (Get-Date)) {
                Write-Host ('Следующий запуск: {0:dd.MM.yyyy HH:mm:ss}' -f $info.NextRunTime)
            }
        }
    } else {
        Write-Host 'Не удалось получить задачу наблюдения из планировщика.' -ForegroundColor Yellow
    }
    Write-Host ''

    # 2) Снимки — счётчик, размер, возраст последнего
    $snaps = Get-ChildItem -Path $snapshotsDir -Filter 'snap-*.json' -ErrorAction SilentlyContinue
    $count = if ($snaps) { @($snaps).Count } else { 0 }
    if ($count -gt 0) {
        $sizeBytes = ($snaps | Measure-Object -Property Length -Sum).Sum
        # Размер в подходящих единицах (без округления в 0 MB для маленьких снимков)
        if ($sizeBytes -lt 1MB) {
            $sizeStr = '{0} КиБ' -f [math]::Round($sizeBytes / 1KB, 1)
        } else {
            $sizeStr = '{0} МиБ' -f [math]::Round($sizeBytes / 1MB, 2)
        }
        $last = $snaps | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $ageSec = [int]((Get-Date) - $last.LastWriteTime).TotalSeconds
        # Свежий = младше 2×interval; старее — watcher не пишет
        $ageColor = if ($ageSec -lt ($IntervalSec * 2)) { 'Green' } else { 'Red' }

        Write-Host ('Снимков: {0} ({1})' -f $count, $sizeStr)
        Write-Host -NoNewline ('Последний снимок: {0} ({1:HH:mm:ss}, ' -f $last.Name, $last.LastWriteTime)
        Write-Host ('{0} с назад)' -f $ageSec) -ForegroundColor $ageColor
    } else {
        Write-Host 'Снимков пока нет. Если задача уже запускалась, проверьте журнал ниже.' -ForegroundColor Yellow
    }
    Write-Host ''

    # 3) Хвост watcher.log — самая важная часть, показывает что snapshot реально делает
    Write-Host 'Журнал сбора (watcher.log, последние 8 строк)' -ForegroundColor DarkGray
    if (Test-Path $logFile) {
        $tail = Get-Content -Path $logFile -Tail 8 -ErrorAction SilentlyContinue
        foreach ($ln in $tail) {
            $color = 'Gray'
            if ($ln -match ' ERROR ') { $color = 'Red' }
            elseif ($ln -match ' WARN ') { $color = 'Yellow' }
            elseif ($ln -match ' OK wrote ') { $color = 'Green' }
            Write-Host $ln -ForegroundColor $color
        }
    } else {
        Write-Host 'Журнал пока недоступен.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'Закрыть окно можно без остановки задачи наблюдения.' -ForegroundColor DarkGray

    Start-Sleep -Seconds 5
}
