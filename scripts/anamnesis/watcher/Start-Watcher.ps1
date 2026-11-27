<#
.SYNOPSIS
  Регистрирует задачу Windows, которая запускает Snapshot-OneShot.ps1.
.PARAMETER Server
  Экземпляр SQL Server на этой машине.
.PARAMETER Database
  Имя базы 1С.
.PARAMETER OutDir
  Папка снимков. По умолчанию data/snapshots рядом с комплектом.
.PARAMETER IntervalSec
  Интервал в секундах, минимум 60 по требованиям планировщика.
.PARAMETER Hours
  Длительность наблюдения в часах. По умолчанию 8.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Database,
    [string]$OutDir,
    [int]$IntervalSec = 60,
    [ValidateRange(1, 744)] [int]$Hours = 8
)

$ErrorActionPreference = 'Stop'
$taskName = '_Diag1CAnamnesisWatcher'
$kitRoot = Split-Path -Parent $PSScriptRoot
$defaultOutDir = Join-Path $kitRoot 'data\snapshots'
if (-not $OutDir) { $OutDir = $defaultOutDir }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if ([string]::IsNullOrWhiteSpace($Server) -or $Server.Contains('"') -or [string]::IsNullOrWhiteSpace($Database)) {
    throw 'Укажите действительные имена экземпляра SQL Server и базы 1С.'
}

# Windows Task Scheduler через cmdlet'ы не принимает RepetitionInterval < 60 сек.
# Если кто-то передал меньше — поднимаем до 60 (с предупреждением).
if ($IntervalSec -lt 60) {
    Write-Warning "Минимальный интервал для планировщика Windows — 60 секунд. Сбор будет запускаться раз в минуту."
    $IntervalSec = 60
}

$existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($existing) {
    throw "В планировщике уже есть задача наблюдения $taskName. Завершите предыдущее наблюдение перед запуском нового."
}
$snapScript = Join-Path $PSScriptRoot 'Snapshot-OneShot.ps1'
if (-not (Test-Path -LiteralPath $snapScript)) {
    throw "Файл для сбора снимка не найден: $snapScript."
}

# Передаём имя БД без преобразования кавычек и пробелов командной строкой планировщика.
$dbToken = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Database))
$argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Server "{1}" -DatabaseBase64 "{2}" -OutDir "{3}"' -f $snapScript, $Server, $dbToken, $OutDir.TrimEnd('\')
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine

# Trigger: каждые $IntervalSec, ограничено $Hours
$now = (Get-Date).AddSeconds(5)
$trigger = New-ScheduledTaskTrigger -Once -At $now `
    -RepetitionInterval (New-TimeSpan -Seconds $IntervalSec) `
    -RepetitionDuration (New-TimeSpan -Hours $Hours)

# Планировщик запускает сбор от текущей учётной записи Windows через S4U.
# Учётной записи нужны доступ к локальному SQL Server и право Log on as a batch job.
$currentUser = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew

if (Get-ChildItem -LiteralPath $OutDir -File -Filter 'snap-*.json' -ErrorAction SilentlyContinue | Select-Object -First 1) {
    if ($OutDir -ne $defaultOutDir) {
        throw "Папка $OutDir уже содержит снимки. Укажите новую папку для этого наблюдения."
    }
    $oldDir = 'snapshots-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
    $oldPath = Join-Path (Split-Path -Parent $OutDir) $oldDir
    Move-Item -LiteralPath $OutDir -Destination $oldPath
    Write-Output "Снимки предыдущего наблюдения сохранены в $oldPath"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Наблюдение за SQL Server для 1С. Интервал $IntervalSec с, длительность $Hours ч." | Out-Null

Write-Output "Задача сбора зарегистрирована в планировщике: $taskName"
Write-Output "  Учётная запись: $currentUser (S4U)"
Write-Output "  Интервал: $IntervalSec сек"
Write-Output "  Длительность: $Hours ч"
Write-Output "  Папка снимков: $OutDir"
Write-Output ""
Write-Output "Первый снимок появится после успешного запуска задачи."
$stopScript = (Join-Path $PSScriptRoot 'Stop-Watcher.ps1').Replace("'", "''")
Write-Output "Остановка наблюдения без отправки"
Write-Output "  & '$stopScript'"
