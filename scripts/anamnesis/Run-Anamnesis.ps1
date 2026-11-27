<#
.SYNOPSIS
  Интерактивное меню Anamnesis Kit.

.DESCRIPTION
  Запускайте после установки через install-anamnesis.ps1.
  Из меню можно: прочитать README, выполнить первичную настройку SQL Server,
  запустить наблюдение, открыть окно сбора, завершить наблюдение и отправить архив.
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
    Write-Host "Нажмите Enter, чтобы вернуться в меню." -ForegroundColor DarkGray
    [void](Read-Host)
}

function Show-Readme {
    $readme = Join-Path $RootPath 'README.md'
    if (-not (Test-Path $readme)) {
        Write-Host "Руководство README.md не найдено в $RootPath." -ForegroundColor Red
        return
    }
    # Открыть в notepad — для длинного markdown это удобнее, чем more
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $readme)
    Write-Host "Руководство открыто в Блокноте."
}

function Invoke-SetupSqlServer {
    Write-Host ""
    Write-Host "Подготовка SQL Server к наблюдению ($Server / $Database)" -ForegroundColor Cyan

    $sqlcmd = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        throw "sqlcmd.exe не найден в PATH. Установите SQL Server Command Line Utilities."
    }

    $steps = [ordered]@{
        '01-enable-query-store.sql' = 'Включение Query Store для выбранной базы'
        '02-set-blocked-process-threshold.sql' = 'Настройка порога длительных блокировок на экземпляре'
        '03-create-xe-session.sql' = 'Запуск сеанса Extended Events'
    }
    $xeDir = Join-Path $RootPath 'data\xe'
    New-Item -ItemType Directory -Force -Path $xeDir | Out-Null
    $xeDirHex = ConvertTo-SqlHex $xeDir

    foreach ($f in $steps.Keys) {
        $path = Join-Path $RootPath "setup\$f"
        Write-Host $steps[$f] -ForegroundColor Yellow
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
                throw "Подготовка прервана на шаге «$($steps[$f])» (код sqlcmd $LASTEXITCODE)."
            }
        }
        finally {
            Remove-Item -LiteralPath $tmpIn -ErrorAction SilentlyContinue
        }
    }
    Write-Host ""
    Write-Host "Команды выполнены. Проверьте состояние подготовки в меню." -ForegroundColor Green
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
        $result.available = ($null -ne $result.qs -and $null -ne $result.bpt -and
                             $null -ne $result.rcsi -and $null -ne $result.xe)
    } catch { }
    finally {
        Remove-Item -LiteralPath $tmpIn -ErrorAction SilentlyContinue
    }
    return $result
}

function Show-SetupStatusBlock {
    $st = Get-ServerSetupStatus
    Write-Host "Настройки наблюдения для $Server / $Database" -ForegroundColor Cyan
    if (-not $st.available) {
        Write-Host "  Состояние настроек неизвестно. Проверьте имена экземпляра и базы, права учётной записи и наличие sqlcmd.exe." -ForegroundColor Yellow
        Write-Host ""
        return $null
    }

    $qsState = if ($st.qs) { 'включён' } else { 'выключен' }
    $lockState = if ($st.bpt -gt 0) { "$($st.bpt) с" } else { 'выключен' }
    $xeState = if ($st.xe) { 'запущен' } else { 'остановлен или отсутствует' }
    $rcsiState = if ($st.rcsi) { 'включено' } else { 'выключено' }
    Write-Host "  Query Store: $qsState"
    Write-Host "  Порог регистрации длительных блокировок: $lockState"
    Write-Host "  Сеанс Extended Events: $xeState"
    Write-Host "  Снимочное чтение (RCSI): $rcsiState"
    Write-Host ""
    return ($st.qs -and ($st.bpt -gt 0) -and $st.xe)
}

function Start-WatcherInteractive {
    Write-Host ""
    Write-Host "Запуск наблюдения для $Server / $Database" -ForegroundColor Cyan
    $hoursText = Read-Host "Сколько часов наблюдать? Введите от 1 до 744 или нажмите Enter для 8 часов"
    $hours = 8
    if ($hoursText -and (-not [int]::TryParse($hoursText, [ref]$hours) -or $hours -lt 1 -or $hours -gt 744)) {
        throw "Введите целое число от 1 до 744."
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
        Write-Host "Окно наблюдения открыто." -ForegroundColor Green
        Write-Host "Запустите операцию в 1С после первого снимка. При закрытии окна сбор продолжится."
    } else {
        Write-Host "Окно наблюдения не открылось. Не найден $watchScript." -ForegroundColor Yellow
        Write-Host "Задача сбора создана. Проверьте количество снимков командой ниже."
        Write-Host "  Get-ChildItem '$($RootPath)\data\snapshots' -Filter snap-*.json | Measure-Object"
    }
}

function Stop-AndUpload {
    Write-Host ""
    Write-Host "Завершение наблюдения и отправка снимков" -ForegroundColor Cyan

    $stopScript = Join-Path $RootPath 'watcher\Stop-Watcher.ps1'
    $uploadScript = Join-Path $RootPath 'upload\Upload-Archive.ps1'

    if (Test-Path $stopScript) {
        & $stopScript -Server $Server -Database $Database
    } else {
        Write-Host "Не удалось завершить наблюдение. Не найден $stopScript." -ForegroundColor Red
        return
    }

    Write-Host ""
    $email = Read-Host "Почта для связи. Нажмите Enter, чтобы продолжить без неё"

    if (-not (Test-Path $uploadScript)) {
        Write-Host "Не удалось отправить снимки. Не найден $uploadScript." -ForegroundColor Red
        return
    }

    Write-Host ""
    & $uploadScript -Server $Server -Database $Database -ClientEmail $email
}

function Read-KitConfig {
    $path = Join-Path $RootPath 'project.json'
    if (Test-Path -LiteralPath $path) {
        try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { }
    }
    return $null
}

function Show-Menu {
    Clear-Host
    $config = Read-KitConfig
    $version = if ($config.anamnesis_kit_version) { $config.anamnesis_kit_version }
               elseif ($config.version) { $config.version }
               else { 'версия неизвестна' }
    $analysisUri = $config.api_url -as [uri]
    Write-Host ""
    Write-Host "Наблюдение за SQL Server для 1С (Anamnesis Kit $version)" -ForegroundColor Cyan
    Write-Host "Папка комплекта: $RootPath" -ForegroundColor DarkGray
    Write-Host ""

    # Блок состояния сервера ПЕРЕД пунктами меню
    $allOk = Show-SetupStatusBlock
    $setupTag = if ($null -eq $allOk) { '[состояние неизвестно]' }
                elseif ($allOk) { '[выполнено]' }
                else { '[требуется]' }
    $setupColor = if ($allOk) { 'Green' } else { 'Yellow' }

    Write-Host "  1. Открыть руководство (README.md)"
    Write-Host -NoNewline "  2. Применить первичную настройку SQL Server "
    Write-Host $setupTag -ForegroundColor $setupColor
    Write-Host "     Query Store, регистрация длительных блокировок, Extended Events"
    Write-Host "     На SQL Server 2017 и новее комплект пытается включить возврат"
    Write-Host "     к последнему удачному плану, если запрос начинает работать хуже."
    Write-Host "  3. Начать наблюдение"
    Write-Host "     Ход сбора виден в отдельном окне."
    Write-Host "  4. Завершить наблюдение и отправить снимки на анализ"
    if ($analysisUri.Authority) {
        Write-Host "     Получатель: сервис анализа $($analysisUri.Authority)."
    }
    else {
        Write-Host '     Адрес сервиса анализа не задан. Проверьте project.json.' -ForegroundColor Yellow
    }
    Write-Host '     В архив войдут снимки SQL Server, сведения о наблюдении и указанный email.'
    Write-Host "     В снимках могут быть тексты запросов и планы из разных баз экземпляра."
    Write-Host "  5. Выйти"
    Write-Host ""
}

$RootPath = [System.IO.Path]::GetFullPath($RootPath)
if ([string]::IsNullOrWhiteSpace($Server)) {
    $Server = Read-Required "Укажите экземпляр SQL Server (например, localhost или localhost\INSTANCE)"
}
if ([string]::IsNullOrWhiteSpace($Database)) {
    $Database = Read-Required "Укажите имя базы 1С"
}

if ($Server.Contains('"') -or $Database.Length -gt 128) {
    throw 'Проверьте имя экземпляра и имя базы SQL Server.'
}
$databaseHex = ConvertTo-SqlHex $Database

while ($true) {
    Show-Menu
    $choice = Read-Host "Введите номер пункта"
    try {
        switch ($choice) {
            '1' { Show-Readme; Pause-AnyKey }
            '2' { Invoke-SetupSqlServer; Pause-AnyKey }
            '3' { Start-WatcherInteractive; Pause-AnyKey }
            '4' { Stop-AndUpload; Pause-AnyKey }
            '5' { return }
            ''  { continue }
            default {
                Write-Host "Введите номер пункта от 1 до 5." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Pause-AnyKey
    }
}
