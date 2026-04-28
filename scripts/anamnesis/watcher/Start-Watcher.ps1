<#
.SYNOPSIS
  Регистрирует scheduled task `_DiagEshnWatcher`, который вызывает
  Snapshot-OneShot.ps1 каждые $IntervalSec секунд в течение $Hours часов.
.PARAMETER Server, Database, OutDir
  Передаются в Snapshot-OneShot.ps1.
.PARAMETER IntervalSec
  Период между snapshot'ами (default: 60). Ограничение Windows Task Scheduler через
  New-ScheduledTaskTrigger: значения < 60 сек запрещены, иначе Register-ScheduledTask
  выбрасывает HRESULT 0x80041318 (out of range).
.PARAMETER Hours
  Длительность сессии (default: 8). По истечении — task самоудаляется
  через Stop-Watcher.ps1 (планируется через AT command).
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Database = 'eshn_test1',
    [string]$OutDir = 'C:\Anamnesis\data\snapshots',
    [int]$IntervalSec = 60,
    [int]$Hours = 8
)

$ErrorActionPreference = 'Stop'
$taskName = '_DiagEshnWatcher'

# Windows Task Scheduler через cmdlet'ы не принимает RepetitionInterval < 60 сек.
# Если кто-то передал меньше — поднимаем до 60 (с предупреждением).
if ($IntervalSec -lt 60) {
    Write-Warning "IntervalSec=$IntervalSec слишком маленький. Windows Task Scheduler требует >=60 сек. Поднимаю до 60."
    $IntervalSec = 60
}

# Удалить старую task если есть
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Output "Удалена существующая задача $taskName"
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$scriptDir = Split-Path -Parent $PSCommandPath
$snapScript = Join-Path $scriptDir 'Snapshot-OneShot.ps1'

# Action: powershell -NoProfile -ExecutionPolicy Bypass -File ... -Server ... -Database ... -OutDir ...
$argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$snapScript`" -Server $Server -Database $Database -OutDir `"$OutDir`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine

# Trigger: каждые $IntervalSec, ограничено $Hours
$now = (Get-Date).AddSeconds(5)
$trigger = New-ScheduledTaskTrigger -Once -At $now `
    -RepetitionInterval (New-TimeSpan -Seconds $IntervalSec) `
    -RepetitionDuration (New-TimeSpan -Hours $Hours)

$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Anamnesis watcher: snapshots каждые $IntervalSec сек, $Hours ч." | Out-Null

Write-Output "Watcher запущен: $taskName"
Write-Output "  Интервал: $IntervalSec sec"
Write-Output "  Длительность: $Hours h"
Write-Output "  Snapshot dir: $OutDir"
Write-Output ""
Write-Output "Для остановки:  .\Stop-Watcher.ps1"
Write-Output "Первый snapshot будет через ~$IntervalSec секунд."
