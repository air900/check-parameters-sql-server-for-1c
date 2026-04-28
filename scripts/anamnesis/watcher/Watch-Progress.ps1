<#
.SYNOPSIS
  Live-прогресс watcher'а в отдельном PowerShell окне.

.DESCRIPTION
  Запускается из Run-Anamnesis.ps1 → Start-Process powershell.exe -File.
  Каждые 10 сек печатает: статус scheduled task, число снимков, размер папки.
  Закрытие окна не отменяет работу watcher'а — task в Windows Scheduler идёт независимо.
  PowerShell 5.1 совместимо.

.PARAMETER RootPath
  Корень kit'а (по умолчанию C:\Anamnesis), где живёт data\snapshots\.
#>
[CmdletBinding()]
param(
    [string]$RootPath = 'C:\Anamnesis'
)

$ErrorActionPreference = 'SilentlyContinue'

$snapshotsDir = Join-Path $RootPath 'data\snapshots'

while ($true) {
    Clear-Host
    Write-Host '=== Anamnesis watcher progress ===' -ForegroundColor Cyan
    Write-Host (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host ''

    $task = Get-ScheduledTask -TaskName '_DiagEshnWatcher' -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host ('Task state: ' + $task.State)
    } else {
        Write-Host 'Task _DiagEshnWatcher не найден (видимо watcher завершился).' -ForegroundColor Yellow
    }
    Write-Host ''

    $snaps = Get-ChildItem $snapshotsDir -Filter 'snap-*.json' -ErrorAction SilentlyContinue
    $count = if ($snaps) { @($snaps).Count } else { 0 }
    if ($count -gt 0) {
        $sizeBytes = ($snaps | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($sizeBytes / 1MB, 1)
    } else {
        $sizeMB = 0
    }
    Write-Host ('Snapshots: ' + $count + ' файлов, ' + $sizeMB + ' MB')

    if ($count -gt 0) {
        $last = $snaps | Sort-Object Name -Descending | Select-Object -First 1
        Write-Host ('Последний:  ' + $last.Name + '  (' + $last.LastWriteTime.ToString('HH:mm:ss') + ')')
    }
    Write-Host ''
    Write-Host 'Закрыть окно: Ctrl+C или просто закрыть. На watcher это не повлияет.' -ForegroundColor DarkGray

    Start-Sleep -Seconds 10
}
