<#
.SYNOPSIS
  Останавливает задачу наблюдения Windows. Снимки остаются на диске.
.PARAMETER Server
  Если указан, завершает наблюдение только для этого экземпляра SQL Server.
.PARAMETER Database
  Если указана, завершает наблюдение только для этой базы.
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Database
)

$ErrorActionPreference = 'Stop'
$taskName = '_Diag1CAnamnesisWatcher'

$existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Output "Задача наблюдения отсутствует в планировщике."
    return
}

$snapScript = Join-Path $PSScriptRoot 'Snapshot-OneShot.ps1'
$expectedAction = '-File "{0}"' -f $snapScript
$arguments = $existing.Actions | Where-Object {
    $_.Arguments -like "*$([WildcardPattern]::Escape($expectedAction))*"
} | Select-Object -First 1 -ExpandProperty Arguments
if (-not $arguments) {
    throw "Задача $taskName относится к другой папке установки. Запустите Stop-Watcher.ps1 из той папки."
}

if ($Server) {
    $scheduledServer = [regex]::Match($arguments, '\s-Server "([^"]+)"').Groups[1].Value
    $localAlias = '^(\.|localhost|\(local\)|127\.0\.0\.1)(?=\\|,|$)'
    if (($scheduledServer -replace $localAlias, [Environment]::MachineName) -ne
        ($Server -replace $localAlias, [Environment]::MachineName)) {
        throw "Планировщик собирает снимки на экземпляре $scheduledServer. Выберите этот экземпляр, чтобы завершить наблюдение."
    }
}
if ($Database) {
    $dbToken = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Database))
    $scheduledDbToken = [regex]::Match($arguments, '\s-DatabaseBase64 "([^"]+)"').Groups[1].Value
    if ($scheduledDbToken -cne $dbToken) {
        throw "Планировщик собирает снимки для другой базы. Выберите эту базу, чтобы завершить наблюдение."
    }
}

if ($existing.State -eq 'Running') {
    $existing | Stop-ScheduledTask
    Start-Sleep -Seconds 2
}
$existing | Unregister-ScheduledTask -Confirm:$false

Write-Output "Наблюдение завершено. Снимки сохранены в исходной папке."
