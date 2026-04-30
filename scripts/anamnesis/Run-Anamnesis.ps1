<#
.SYNOPSIS
  Интерактивное меню Anamnesis Kit.

.DESCRIPTION
  Запускайте после установки через install-anamnesis.ps1.
  Из меню можно: прочитать README, выполнить первичную настройку SQL Server,
  запустить watcher (в отдельном окне с прогрессом), остановить и отправить архив.
  PowerShell 5.1 совместимо.

.PARAMETER RootPath
  Корневая папка kit'а (default: каталог самого скрипта, обычно C:\Anamnesis).

.EXAMPLE
  C:\Anamnesis\Run-Anamnesis.ps1
#>
[CmdletBinding()]
param(
    [string]$RootPath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

function Read-WithDefault([string]$prompt, [string]$default) {
    $val = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $default }
    return $val
}

function Pause-AnyKey {
    Write-Host ""
    Write-Host "Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
    [void](Read-Host)
}

function Show-Readme {
    $readme = Join-Path $RootPath 'README.md'
    if (-not (Test-Path $readme)) {
        Write-Host "README.md не найден в $RootPath" -ForegroundColor Red
        return
    }
    # Открыть в notepad — для длинного markdown это удобнее, чем more
    Start-Process notepad.exe -ArgumentList $readme
    Write-Host "README открыт в Notepad."
}

function Invoke-SetupSqlServer {
    Write-Host ""
    Write-Host "Первичная настройка SQL Server (один раз на экземпляр)" -ForegroundColor Cyan
    Write-Host "Будут выполнены три SQL-скрипта:"
    Write-Host "  01-enable-query-store          (Query Store + Auto Plan Correction)"
    Write-Host "  02-set-blocked-process-threshold  (BPT = 10 sec)"
    Write-Host "  03-create-xe-session              (Extended Events session)"
    Write-Host ""
    $server = Read-WithDefault "SQL Server (host\instance)" "MSSQL-TEST"
    $db = Read-WithDefault "Имя базы 1С" "eshn_test1"
    Write-Host ""

    $sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        Write-Host "sqlcmd.exe не найден в PATH. Установите SQL Server Command Line Utilities." -ForegroundColor Red
        return
    }

    $files = @(
        '01-enable-query-store.sql',
        '02-set-blocked-process-threshold.sql',
        '03-create-xe-session.sql'
    )
    foreach ($f in $files) {
        $path = Join-Path $RootPath "setup\$f"
        if (-not (Test-Path $path)) {
            Write-Host "Не найден файл: $path" -ForegroundColor Red
            continue
        }
        Write-Host "-- $f" -ForegroundColor Yellow
        # Флаг -b: exit-on-error для severity >= 11 (Microsoft Docs «sqlcmd Utility»).
        # Без него SQL-ошибки уровня <17 (например, Msg 207) не прерывают sqlcmd
        # и LASTEXITCODE остаётся 0 — setup рапортует «успешно» при реальной ошибке.
        # Флаг -f 65001: force UTF-8 input. Setup-скрипты с UTF-8 BOM, но на русской
        # Windows sqlcmd 13/14/15 нестабильно распознаёт BOM и читает как cp1251 —
        # ASCII идентификаторы потом ломаются на сервере. См. bd-wox.
        if ($f -eq '02-set-blocked-process-threshold.sql') {
            & sqlcmd.exe -S "$server" -f 65001 -i $path -b
        } else {
            & sqlcmd.exe -S "$server" -f 65001 -i $path -v "db=$db" -b
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Ошибка sqlcmd (exit=$LASTEXITCODE) на $f. Setup прерван." -ForegroundColor Red
            return
        }
    }
    Write-Host ""
    Write-Host "Настройка завершена." -ForegroundColor Green
}

function Get-ServerSetupStatus {
    # Опросить SQL Server по 4 настройкам Anamnesis Kit primary setup'а.
    # Возвращает hashtable: @{ qs=bool; bpt=int; rcsi=bool; xe=bool; available=bool }.
    # available=$false если SQL не отвечает — без падения, просто Skip.
    param([string]$ServerInstance)

    $result = @{ qs = $null; bpt = $null; rcsi = $null; xe = $null; available = $false }

    $sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmd) { return $result }

    $checkScript = Join-Path $RootPath 'setup\check-setup-status.sql'
    if (-not (Test-Path $checkScript)) { return $result }

    try {
        $output = & sqlcmd.exe -S "$ServerInstance" -d master -f 65001 -i $checkScript -b -h-1 2>&1
        if ($LASTEXITCODE -ne 0) { return $result }
        foreach ($line in $output) {
            $s = "$line".Trim()
            if ($s -match '^QS:(\d+)$')   { $result.qs   = ([int]$matches[1] -eq 1) }
            elseif ($s -match '^BPT:(\d+)$')  { $result.bpt  = [int]$matches[1] }
            elseif ($s -match '^RCSI:(\d+)$') { $result.rcsi = ([int]$matches[1] -eq 1) }
            elseif ($s -match '^XE:(\d+)$')   { $result.xe   = ([int]$matches[1] -eq 1) }
        }
        # Если хоть что-то распарсилось — соединение живо
        if ($null -ne $result.qs -or $null -ne $result.bpt) { $result.available = $true }
    } catch { }
    return $result
}

function Show-SetupStatusBlock {
    param([string]$ServerInstance)

    $st = Get-ServerSetupStatus -ServerInstance $ServerInstance
    Write-Host "Состояние сервера $ServerInstance (проверено только что):" -ForegroundColor Cyan
    if (-not $st.available) {
        Write-Host "  Не удалось проверить (SQL Server не отвечает)" -ForegroundColor Yellow
        Write-Host ""
        return $false
    }

    function Show-Mark([bool]$ok, [string]$text) {
        if ($ok) { Write-Host "  OK $text" -ForegroundColor Green }
        else     { Write-Host "  -- $text  (требуется настройка)" -ForegroundColor Yellow }
    }

    Show-Mark $st.qs   "Query Store включён"
    Show-Mark ($st.bpt -gt 0) "Длительные блокировки логируются (BPT = $($st.bpt) сек)"
    Show-Mark $st.rcsi "Снимочное чтение (RCSI) включено"
    Show-Mark $st.xe   "Сессия Extended Events `_diag_eshn_hang` запущена"
    Write-Host ""
    return ($st.qs -and ($st.bpt -gt 0) -and $st.rcsi -and $st.xe)
}

function Start-WatcherInteractive {
    Write-Host ""
    Write-Host "Запуск watcher перед расчётом ЕСХН" -ForegroundColor Cyan
    $server = Read-WithDefault "SQL Server (host\instance)" "MSSQL-TEST"
    $db = Read-WithDefault "Имя базы 1С" "eshn_test1"
    $hoursStr = Read-WithDefault "Сколько часов наблюдать" "8"
    $hours = [int]$hoursStr

    $startScript = Join-Path $RootPath 'watcher\Start-Watcher.ps1'
    if (-not (Test-Path $startScript)) {
        Write-Host "Не найден $startScript" -ForegroundColor Red
        return
    }

    Write-Host ""
    & $startScript -Server $server -Database $db -Hours $hours
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "Start-Watcher вернул ошибку." -ForegroundColor Red
        return
    }

    # Открываем отдельное окно PowerShell с live-прогрессом —
    # запускаем готовый файл Watch-Progress.ps1 через -File (без эскейпов).
    $watchScript = Join-Path $RootPath 'watcher\Watch-Progress.ps1'
    if (Test-Path $watchScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile',
            '-NoExit',
            '-File', $watchScript,
            '-RootPath', $RootPath
        )
        Write-Host ""
        Write-Host "Открыто отдельное окно с прогрессом сбора." -ForegroundColor Green
        Write-Host "Можно вернуться в это меню — закрытие окна прогресса не остановит watcher."
    } else {
        Write-Host "Не найден $watchScript — окно прогресса не открыто." -ForegroundColor Yellow
        Write-Host "Watcher всё равно собирает снимки — проверить вручную:"
        Write-Host "  Get-ChildItem '$($RootPath)\data\snapshots' -Filter snap-*.json | Measure-Object"
    }
}

function Stop-AndUpload {
    Write-Host ""
    Write-Host "Остановка watcher и отправка архива" -ForegroundColor Cyan

    $stopScript = Join-Path $RootPath 'watcher\Stop-Watcher.ps1'
    $uploadScript = Join-Path $RootPath 'upload\Upload-Archive.ps1'

    if (Test-Path $stopScript) {
        Write-Host "-- Stop-Watcher" -ForegroundColor Yellow
        & $stopScript
    } else {
        Write-Host "Не найден $stopScript" -ForegroundColor Red
        return
    }

    Write-Host ""
    $db = Read-WithDefault "Имя базы 1С (для метки в manifest)" "eshn_test1"
    $email = Read-Host "Email клиента (опционально, можно пусто)"

    if (-not (Test-Path $uploadScript)) {
        Write-Host "Не найден $uploadScript" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "-- Upload-Archive" -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($email)) {
        & $uploadScript -SnapshotDir (Join-Path $RootPath 'data\snapshots') -Database $db
    } else {
        & $uploadScript -SnapshotDir (Join-Path $RootPath 'data\snapshots') -Database $db -ClientEmail $email
    }
}

function Get-KitVersion {
    # project.json лежит рядом с Run-Anamnesis.ps1 в RootPath (положено инсталлером).
    $pj = Join-Path $RootPath 'project.json'
    if (Test-Path $pj) {
        try {
            $obj = Get-Content -Path $pj -Raw -Encoding UTF8 | ConvertFrom-Json
            $v = $obj.version
            $kv = $obj.anamnesis_kit_version
            if ($v -and $kv) { return "$v (anamnesis_kit $kv)" }
            if ($v) { return $v }
        } catch { }
    }
    return 'unknown'
}

function Show-Menu {
    param([string]$ServerInstance)

    Clear-Host
    $version = Get-KitVersion
    Write-Host ""
    Write-Host "Anamnesis Kit — главное меню (версия $version)" -ForegroundColor Cyan
    Write-Host ("Корень: $RootPath") -ForegroundColor DarkGray
    Write-Host ""

    # Блок состояния сервера ПЕРЕД пунктами меню
    $allOk = Show-SetupStatusBlock -ServerInstance $ServerInstance
    $setupTag = if ($allOk) { "[выполнено]" } else { "[требуется]" }
    $setupColor = if ($allOk) { "Green" } else { "Yellow" }

    Write-Host "  1. Открыть документацию (README.md)"
    Write-Host -NoNewline "  2. Применить первичную настройку SQL Server "
    Write-Host $setupTag -ForegroundColor $setupColor
    Write-Host "     (Query Store + длительные блокировки + Extended Events)"
    Write-Host "  3. Начать наблюдение перед запуском расчёта"
    Write-Host "     (открывается отдельное окно)"
    Write-Host "  4. Завершить наблюдение и отправить отчёт на анализ"
    Write-Host "  5. Выйти"
    Write-Host ""
}

# Главный цикл — спросить SQL-инстанс один раз и переиспользовать для status-блока
$serverForStatus = Read-WithDefault "SQL Server (host\instance)" "MSSQL-TEST"

while ($true) {
    Show-Menu -ServerInstance $serverForStatus
    $choice = Read-Host "Выбор"
    switch ($choice) {
        '1' { Show-Readme; Pause-AnyKey }
        '2' { Invoke-SetupSqlServer; Pause-AnyKey }
        '3' { Start-WatcherInteractive; Pause-AnyKey }
        '4' { Stop-AndUpload; Pause-AnyKey }
        '5' { Write-Host "Выход."; return }
        ''  { continue }
        default {
            Write-Host "Неизвестный выбор: '$choice'. Введите 1-5." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
