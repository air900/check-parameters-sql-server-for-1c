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
        if ($f -eq '02-set-blocked-process-threshold.sql') {
            & sqlcmd.exe -S "$server" -i $path -b
        } else {
            & sqlcmd.exe -S "$server" -i $path -v "db=$db" -b
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Ошибка sqlcmd (exit=$LASTEXITCODE) на $f. Setup прерван." -ForegroundColor Red
            return
        }
    }
    Write-Host ""
    Write-Host "Настройка завершена." -ForegroundColor Green
}

function Test-SnapshotOnce {
    # Запускает Snapshot-OneShot.ps1 один раз интерактивно (не через scheduled task).
    # Видны все ошибки sqlcmd / PowerShell, чтобы понять причину "0 файлов" ДО запуска watcher'а.
    Write-Host ""
    Write-Host "Тест: один snapshot вручную" -ForegroundColor Cyan
    Write-Host "Запускает Snapshot-OneShot.ps1 один раз — видно реальную ошибку, если есть."
    Write-Host ""
    $server = Read-WithDefault "SQL Server (host\instance)" "MSSQL-TEST"
    $db = Read-WithDefault "Имя базы 1С" "eshn_test1"
    $outDir = Join-Path $RootPath 'data\snapshots'

    $snapScript = Join-Path $RootPath 'watcher\Snapshot-OneShot.ps1'
    if (-not (Test-Path $snapScript)) {
        Write-Host "Не найден $snapScript" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "-- $snapScript -Server $server -Database $db -OutDir $outDir" -ForegroundColor Yellow
    & $snapScript -Server $server -Database $db -OutDir $outDir

    Write-Host ""
    $logFile = Join-Path $RootPath 'data\watcher.log'
    if (Test-Path $logFile) {
        Write-Host "--- Последние 20 строк watcher.log ---" -ForegroundColor DarkGray
        Get-Content -Path $logFile -Tail 20
    }

    Write-Host ""
    $produced = Get-ChildItem -Path $outDir -Filter 'snap-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($produced) {
        Write-Host "Создан $($produced.Name) ($($produced.Length) байт)." -ForegroundColor Green
    } else {
        Write-Host "Снимок НЕ создан. См. лог выше." -ForegroundColor Red
    }
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
    Clear-Host
    $version = Get-KitVersion
    Write-Host ""
    Write-Host "Anamnesis Kit — главное меню (версия $version)" -ForegroundColor Cyan
    Write-Host ("Корень: $RootPath") -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  1. Прочитать README.md"
    Write-Host "  2. Первичная настройка SQL Server"
    Write-Host "     (Query Store + BPT + Extended Events; один раз на экземпляр)"
    Write-Host "  3. Тест: один snapshot вручную (диагностика watcher'а)"
    Write-Host "  4. Запустить watcher перед расчётом ЕСХН"
    Write-Host "     (откроется отдельное окно с live-прогрессом)"
    Write-Host "  5. После расчёта — остановить watcher и отправить архив"
    Write-Host "  6. Выход"
    Write-Host ""
}

# Главный цикл
while ($true) {
    Show-Menu
    $choice = Read-Host "Выбор"
    switch ($choice) {
        '1' { Show-Readme; Pause-AnyKey }
        '2' { Invoke-SetupSqlServer; Pause-AnyKey }
        '3' { Test-SnapshotOnce; Pause-AnyKey }
        '4' { Start-WatcherInteractive; Pause-AnyKey }
        '5' { Stop-AndUpload; Pause-AnyKey }
        '6' { Write-Host "Выход."; return }
        ''  { continue }
        default {
            Write-Host "Неизвестный выбор: '$choice'. Введите 1-6." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
