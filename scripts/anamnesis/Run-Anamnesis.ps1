<#
.SYNOPSIS
  Интерактивное меню Anamnesis Kit.

.DESCRIPTION
  Запускайте после установки через install-anamnesis.ps1.
  Из меню можно: прочитать README, выполнить первичную настройку SQL Server,
  запустить watcher (в отдельном окне с прогрессом), остановить и отправить архив.
  PowerShell 5.1 совместимо.

.PARAMETER RootPath
  Папка установки (по умолчанию каталог скрипта).
.PARAMETER Server
  Экземпляр SQL Server, например localhost или localhost\INSTANCE.
.PARAMETER Database
  Имя базы данных 1С. Если цель не указана, меню запросит её при запуске.

.EXAMPLE
  C:\Anamnesis\Run-Anamnesis.ps1
#>
[CmdletBinding()]
param(
    [string]$RootPath = $PSScriptRoot,
    [string]$Server,
    [string]$Database
)

$ErrorActionPreference = 'Stop'

function Read-Required([string]$Prompt) {
    do { $value = Read-Host $Prompt } while ([string]::IsNullOrWhiteSpace($value))
    return $value
}

function ConvertTo-SqlHex([string]$Text) {
    return [BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes($Text)).Replace('-', '')
}

function Copy-SqlcmdInput([string]$Path, [string]$Destination) {
    # UTF-16 LE с BOM позволяет sqlcmd корректно читать SQL на Windows с любой локалью.
    $sqlText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($Destination, $sqlText, [System.Text.Encoding]::Unicode)
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
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $readme)
    Write-Host "README открыт в Notepad."
}

function Invoke-SetupSqlServer {
    Write-Host ""
    Write-Host "Первичная настройка для $Server / $Database" -ForegroundColor Cyan

    $sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        throw "sqlcmd.exe не найден в PATH. Установите SQL Server Command Line Utilities."
    }

    $files = @(
        '01-enable-query-store.sql',
        '02-set-blocked-process-threshold.sql',
        '03-create-xe-session.sql'
    )
    $xeDir = Join-Path $RootPath 'data\xe'
    New-Item -ItemType Directory -Force -Path $xeDir | Out-Null
    $xeDirHex = ConvertTo-SqlHex $xeDir

    foreach ($f in $files) {
        $path = Join-Path $RootPath "setup\$f"
        Write-Host "-- $f" -ForegroundColor Yellow
        $tmpIn = [System.IO.Path]::GetTempFileName()
        try {
            Copy-SqlcmdInput -Path $path -Destination $tmpIn
            $sqlArgs = @('-S', $Server, '-d', 'master', '-E', '-l', '5', '-b', '-i', $tmpIn)
            if ($f -ne '02-set-blocked-process-threshold.sql') {
                $sqlArgs += @('-v', "db_hex=$databaseHex")
                if ($f -eq '03-create-xe-session.sql') { $sqlArgs += "xe_dir_hex=$xeDirHex" }
            }
            & $sqlcmd.Source @sqlArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Настройка прервана на $f (код sqlcmd $LASTEXITCODE)."
            }
        }
        finally {
            Remove-Item -LiteralPath $tmpIn -ErrorAction SilentlyContinue
        }
    }
    Write-Host ""
    Write-Host "Настройка завершена." -ForegroundColor Green
}

function Get-ServerSetupStatus {
    $result = @{ qs = $null; bpt = $null; rcsi = $null; xe = $null; available = $false }

    $sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmd) { return $result }

    $checkScript = Join-Path $RootPath 'setup\check-setup-status.sql'
    if (-not (Test-Path $checkScript)) { return $result }

    $tmpIn = [System.IO.Path]::GetTempFileName()
    try {
        Copy-SqlcmdInput -Path $checkScript -Destination $tmpIn
        $output = & $sqlcmd.Source -S $Server -d master -E -l 5 -i $tmpIn -b -h-1 -v "db_hex=$databaseHex" 2>&1
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
    finally {
        Remove-Item -LiteralPath $tmpIn -ErrorAction SilentlyContinue
    }
    return $result
}

function Show-SetupStatusBlock {
    $st = Get-ServerSetupStatus
    Write-Host "Состояние SQL Server $Server / $Database" -ForegroundColor Cyan
    if (-not $st.available) {
        Write-Host "  Не удалось проверить. Проверьте имя экземпляра, базы, права подключения и наличие sqlcmd.exe." -ForegroundColor Yellow
        Write-Host ""
        return $false
    }

    function Show-Mark([bool]$ok, [string]$text) {
        if ($ok) { Write-Host "  OK $text" -ForegroundColor Green }
        else     { Write-Host "  -- $text  (требуется настройка)" -ForegroundColor Yellow }
    }

    Show-Mark $st.qs   "Query Store включён"
    Show-Mark ($st.bpt -gt 0) "Длительные блокировки логируются (BPT = $($st.bpt) сек)"
    $rcsi = if ($st.rcsi) { 'включено' } else { 'выключено' }
    Write-Host "  Снимочное чтение (RCSI) $rcsi"
    Show-Mark $st.xe   "Сессия Extended Events запущена"
    Write-Host ""
    return ($st.qs -and ($st.bpt -gt 0) -and $st.xe)
}

function Start-WatcherInteractive {
    Write-Host ""
    Write-Host "Запуск наблюдения для $Server / $Database" -ForegroundColor Cyan
    $hoursText = Read-Host "Сколько часов наблюдать [8]"
    $hours = 8
    if ($hoursText -and (-not [int]::TryParse($hoursText, [ref]$hours) -or $hours -lt 1)) {
        throw "Укажите положительное целое число часов."
    }
    $startScript = Join-Path $RootPath 'watcher\Start-Watcher.ps1'
    & $startScript -Server $Server -Database $Database -Hours $hours

    # Открываем отдельное окно PowerShell с live-прогрессом —
    # запускаем готовый файл Watch-Progress.ps1 через -File (без эскейпов).
    $watchScript = Join-Path $RootPath 'watcher\Watch-Progress.ps1'
    if (Test-Path $watchScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile',
            '-NoExit',
            '-File', ('"{0}"' -f $watchScript),
            '-RootPath', ('"{0}"' -f $RootPath)
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
        & $stopScript -Server $Server -Database $Database
    } else {
        Write-Host "Не найден $stopScript" -ForegroundColor Red
        return
    }

    Write-Host ""
    $email = Read-Host "Email клиента (опционально, можно пусто)"

    if (-not (Test-Path $uploadScript)) {
        Write-Host "Не найден $uploadScript" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "-- Upload-Archive" -ForegroundColor Yellow
    & $uploadScript -Server $Server -Database $Database -ClientEmail $email
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

    # Блок состояния сервера ПЕРЕД пунктами меню
    $allOk = Show-SetupStatusBlock
    $setupTag = if ($allOk) { "[выполнено]" } else { "[требуется]" }
    $setupColor = if ($allOk) { "Green" } else { "Yellow" }

    Write-Host "  1. Открыть документацию (README.md)"
    Write-Host -NoNewline "  2. Применить первичную настройку SQL Server "
    Write-Host $setupTag -ForegroundColor $setupColor
    Write-Host "     (Query Store + длительные блокировки + Extended Events)"
    Write-Host "  3. Начать наблюдение перед запуском расчёта"
    Write-Host "     (открывается отдельное окно)"
    Write-Host "  4. Завершить наблюдение и отправить снимки на анализ"
    Write-Host "  5. Выйти"
    Write-Host ""
}

$RootPath = [System.IO.Path]::GetFullPath($RootPath)
if ([string]::IsNullOrWhiteSpace($Server)) {
    $Server = Read-Required "SQL Server (localhost или localhost\INSTANCE)"
}
if ([string]::IsNullOrWhiteSpace($Database)) {
    $Database = Read-Required "Имя базы 1С"
}

if ($Server.Contains('"') -or $Database.Length -gt 128) {
    throw 'Проверьте имя экземпляра и имя базы SQL Server.'
}
$databaseHex = ConvertTo-SqlHex $Database

while ($true) {
    Show-Menu
    $choice = Read-Host "Выбор"
    try {
        switch ($choice) {
            '1' { Show-Readme; Pause-AnyKey }
            '2' { Invoke-SetupSqlServer; Pause-AnyKey }
            '3' { Start-WatcherInteractive; Pause-AnyKey }
            '4' { Stop-AndUpload; Pause-AnyKey }
            '5' { Write-Host "Выход."; return }
            ''  { continue }
            default {
                Write-Host "Неизвестный выбор '$choice'. Введите число от 1 до 5." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Pause-AnyKey
    }
}
