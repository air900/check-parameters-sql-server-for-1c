<#
.SYNOPSIS
  Останавливает и удаляет scheduled task _DiagEshnWatcher.
  Snapshot-файлы НЕ удаляет — оператор сам решает архивировать или нет.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = '_DiagEshnWatcher'

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Output "Task $taskName не зарегистрирована — нечего останавливать."
    return
}

# Остановить если выполняется
if ($existing.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
}

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

Write-Output "Watcher остановлен и удалён."
Write-Output "Snapshot-файлы оставлены в исходной папке (см. Start-Watcher OutDir)."
Write-Output "Для анализа:  .\..\analyze\Aggregate-Anamnesis.ps1 -SnapshotDir <path>"
