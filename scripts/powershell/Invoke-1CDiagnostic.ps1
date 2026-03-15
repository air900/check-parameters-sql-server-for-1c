<#
.SYNOPSIS
    Диагностика PostgreSQL для 1С:Предприятие

.DESCRIPTION
    Проверяет настройку PostgreSQL и выявляет проблемы, влияющие на
    производительность 1С:Предприятие.

    Скрипт автоматически:
    1. Находит установленный PostgreSQL на сервере
    2. Определяет базу данных 1С
    3. Запускает диагностические проверки (read-only, безопасно)
    4. Показывает результаты с цветовой индикацией
    5. Сохраняет HTML-отчёт на Рабочий стол
    6. Предлагает отправить данные на углублённый анализ

.PARAMETER PgHost
    Имя или IP-адрес сервера PostgreSQL. По умолчанию: localhost

.PARAMETER Port
    Порт PostgreSQL. По умолчанию: определяется автоматически или 5432

.PARAMETER Database
    Имя базы данных. Если не указано — автоматическое определение базы 1С

.PARAMETER Username
    Имя пользователя PostgreSQL. По умолчанию: postgres

.PARAMETER NoHtml
    Пропустить генерацию HTML-отчёта

.PARAMETER NoPrompt
    Пропустить предложение углублённого анализа (для автоматического запуска)

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1 -PgHost 192.168.1.10 -Port 5433 -Database my1c_db

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1 -NoHtml -NoPrompt

.LINK
    https://github.com/air900/check-parameters-sql-server-for-1c
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string]$PgHost = "localhost",

    [Parameter()]
    [int]$Port = 0,

    [Parameter()]
    [string]$Database = "",

    [Parameter()]
    [string]$Username = "postgres",

    [Parameter()]
    [switch]$NoHtml,

    [Parameter()]
    [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Загрузка модулей
# ============================================================================

$modulesPath = Join-Path $PSScriptRoot "modules"

$requiredModules = @(
    'Find-PostgreSQL',
    'Invoke-SqlDiagnostic',
    'Collect-OS',
    'Show-DiagnosticResults',
    'Export-DiagnosticReport',
    'Send-DiagnosticData'
)

foreach ($mod in $requiredModules) {
    $modPath = Join-Path $modulesPath "$mod.psm1"
    if (-not (Test-Path $modPath)) {
        Write-Error "Модуль не найден: $modPath"
        exit 1
    }
    Import-Module $modPath -Force -DisableNameChecking -ErrorAction Stop
}

# ============================================================================
# Метаданные проекта из project.json
# ============================================================================

$projectJsonPath = Join-Path $PSScriptRoot '..\..\project.json'
if (Test-Path $projectJsonPath) {
    $project = Get-Content $projectJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    # Fallback если project.json не найден (например, при запуске из ZIP)
    $project = [PSCustomObject]@{
        version      = '1.5.2'
        display_name = 'Диагностика PostgreSQL для 1С:Предприятие'
        vendor       = 'audit-reshenie.ru'
        contact      = 'info@audit-reshenie.ru'
        api_url      = 'https://check-speed-sql-server-1c.audit-reshenie.ru:15443/api/v1'
    }
}

# ============================================================================
# Баннер
# ============================================================================

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "      $($project.display_name)  v$($project.version)" -ForegroundColor Cyan
Write-Host "                      $($project.vendor)" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Шаг 1: Поиск PostgreSQL
# ============================================================================

Write-Host "  [1/6] Поиск PostgreSQL..." -ForegroundColor White

$pgInstances = Find-PostgreSQL

if ($null -eq $pgInstances -or $pgInstances.Count -eq 0) {
    Write-Host ""
    Write-Host "  PostgreSQL не обнаружен на этом сервере." -ForegroundColor Red
    Write-Host "  Укажите параметры подключения:" -ForegroundColor Yellow
    Write-Host "    .\Invoke-1CDiagnostic.ps1 -PgHost <host> -Port <port>" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Используем первый найденный экземпляр
$pg = $pgInstances[0]
$pgVersion = if ($pg.Version) { $pg.Version } else { "неизвестно" }
$pgStatus  = if ($pg.Status)  { $pg.Status }  else { "неизвестно" }

Write-Host "  Обнаружен: PostgreSQL $pgVersion на порту $($pg.Port) ($pgStatus)" -ForegroundColor Green

# Если несколько экземпляров — предупредить
if ($pgInstances.Count -gt 1) {
    Write-Host "  Найдено экземпляров: $($pgInstances.Count). Используем первый." -ForegroundColor DarkYellow
    for ($i = 0; $i -lt $pgInstances.Count; $i++) {
        $inst = $pgInstances[$i]
        $marker = if ($i -eq 0) { " <-- используем" } else { "" }
        Write-Host "    [$i] Порт $($inst.Port), версия $($inst.Version)$marker" -ForegroundColor Gray
    }
}

# Применяем обнаруженный порт, если не указан явно
if ($Port -eq 0) {
    $Port = $pg.Port
}

# Определяем путь к psql.exe из найденного экземпляра
$psqlPath = $null
if ($pg.Path) {
    $candidate = Join-Path $pg.Path "psql.exe"
    if (Test-Path $candidate) {
        $psqlPath = $candidate
    }
}

# ============================================================================
# Шаг 2: Пароль
# ============================================================================

Write-Host ""
Write-Host "  [2/6] Подключение к PostgreSQL..." -ForegroundColor White

# Проверка раскладки клавиатуры перед вводом пароля
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $layout = [System.Windows.Forms.InputLanguage]::CurrentInputLanguage.Culture.Name
    if ($layout -match 'ru') {
        Write-Host "  [*] Раскладка клавиатуры: RU — переключите на EN для ввода пароля" -ForegroundColor Yellow
    }
}
catch { }

# Ввод пароля (скрыт звёздочками)
$securePass = Read-Host "  Пароль для пользователя '$Username'" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
$password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# Устанавливаем PGPASSWORD для psql
$env:PGPASSWORD = $password

# Проверка подключения перед продолжением
$testPsql = if ($psqlPath) { $psqlPath } else {
    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($cmd) { $cmd.Source } else { $null }
}
if ($testPsql) {
    Write-Host "  Проверка подключения..." -ForegroundColor Gray
    $testResult = & $testPsql '--host' $PgHost '--port' $Port '--username' $Username '--tuples-only' '--no-align' '--command' 'SELECT 1;' 'postgres' 2>&1
    $testExit = $LASTEXITCODE
    if ($testExit -ne 0) {
        Write-Host ""
        Write-Host "  [!] Ошибка подключения к PostgreSQL:" -ForegroundColor Red
        $testResult | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  Проверьте:" -ForegroundColor Yellow
        Write-Host "    - Правильность пароля" -ForegroundColor Yellow
        Write-Host "    - Доступность сервера ${PgHost}:${Port}" -ForegroundColor Yellow
        Write-Host "    - Права пользователя '$Username'" -ForegroundColor Yellow
        Write-Host ""
        return
    }
    Write-Host "  Подключение успешно." -ForegroundColor Green
}

# ============================================================================
# Шаг 3: Выбор базы данных
# ============================================================================

if (-not $Database) {
    Write-Host ""
    Write-Host "  [3/6] Поиск баз данных 1С..." -ForegroundColor White

    # Определяем путь к psql для поиска баз
    $psqlForSearch = $psqlPath
    if (-not $psqlForSearch) {
        # Пробуем найти psql в PATH или стандартных путях
        $psqlCmd = Get-Command psql.exe -ErrorAction SilentlyContinue
        if ($psqlCmd) { $psqlForSearch = $psqlCmd.Source }
    }

    if ($psqlForSearch) {
        # statement_timeout=30s в запросе гарантирует, что скрипт не зависнет
        Write-Host "  Запрос списка баз данных (может занять до 30 сек)..." -ForegroundColor Gray
        $databases = Find-1CDatabases -PsqlPath $psqlForSearch -PgHost $PgHost -Port $Port -Username $Username
        if ($null -eq $databases) { $databases = @() }

        if ($databases.Count -eq 0) {
            Write-Host "  Базы данных не обнаружены." -ForegroundColor Yellow
        }
        elseif ($databases.Count -eq 1) {
            $Database = $databases[0].Name
            Write-Host "  База данных: $Database ($($databases[0].Size))" -ForegroundColor Green
        }
        else {
            Write-Host "  Обнаружено баз данных: $($databases.Count)" -ForegroundColor Green
            Write-Host ""
            for ($i = 0; $i -lt $databases.Count; $i++) {
                $db = $databases[$i]
                Write-Host "    [$($i + 1)] $($db.Name) ($($db.Size))" -ForegroundColor White
            }
            Write-Host ""

            $choice = Read-Host "  Выберите базу для проверки (1-$($databases.Count))"
            $choiceIdx = 0
            if ([int]::TryParse($choice, [ref]$choiceIdx) -and $choiceIdx -ge 1 -and $choiceIdx -le $databases.Count) {
                $Database = $databases[$choiceIdx - 1].Name
            }
            else {
                $Database = $databases[0].Name
                Write-Host "  Некорректный выбор. Используем: $Database" -ForegroundColor Yellow
            }
            Write-Host "  Выбрана база: $Database" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  psql не найден — база данных будет определена автоматически." -ForegroundColor Yellow
    }
}
else {
    Write-Host ""
    Write-Host "  [3/6] База данных: $Database (указана явно)" -ForegroundColor Green
}

# Очищаем PGPASSWORD после поиска баз (Invoke-SqlDiagnostic установит его сам)
Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

# ============================================================================
# Шаг 4: Запуск диагностики
# ============================================================================

Write-Host ""
Write-Host "  [4/6] Запуск диагностики..." -ForegroundColor White

$invokeParams = @{
    Host     = $PgHost
    Port     = $Port
    Username = $Username
    Password = $password
}

if ($Database) {
    $invokeParams.Database = $Database
}

if ($psqlPath) {
    $invokeParams.PsqlPath = $psqlPath
}

try {
    try {
        $results = Invoke-SqlDiagnostic @invokeParams

        if ($null -eq $results -or $results.Count -eq 0) {
            Write-Host "  Диагностика не вернула результатов. Проверьте подключение." -ForegroundColor Red
            exit 1
        }

        Write-Host "  Получено проверок PostgreSQL: $($results.Count)" -ForegroundColor Green

        # Сбор данных ОС и объединение с результатами SQL-диагностики
        Write-Host "  Сбор данных операционной системы..." -ForegroundColor White
        try {
            $pgDataDir = if ($pg.DataDir) { $pg.DataDir } else { '' }
            $osResults = Collect-OSData -DataDir $pgDataDir
            $results   = $results + $osResults
            Write-Host "  Данные ОС собраны: $($osResults.Count) параметров" -ForegroundColor Green
        }
        catch {
            Write-Host "  Предупреждение: не удалось собрать данные ОС: $_" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ""
        Write-Host "  Ошибка при выполнении диагностики:" -ForegroundColor Red
        Write-Host "  $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Проверьте:" -ForegroundColor Yellow
        Write-Host "    - Правильность пароля" -ForegroundColor Yellow
        Write-Host "    - Доступность сервера $PgHost`:$Port" -ForegroundColor Yellow
        Write-Host "    - Права пользователя '$Username'" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}
finally {
    # Очистка пароля из памяти (выполняется всегда, даже при ошибке)
    $password = $null
    [GC]::Collect()
}

# ============================================================================
# Шаг 4: Показ результатов
# ============================================================================

Write-Host ""
Write-Host "  [5/6] Результаты анализа:" -ForegroundColor White

$summary = Show-DiagnosticResults -Results $results

# ============================================================================
# Шаг 5: HTML-отчёт
# ============================================================================

# Собираем информацию о сервере (нужно и для отчёта, и для отправки на бэкенд)
$serverInfo = @{
    pg_version = $pgVersion
    os         = [System.Environment]::OSVersion.VersionString
    ram        = "{0:N0} GB" -f ([math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 0))
    cpu_cores  = [Environment]::ProcessorCount
    hostname   = [Environment]::MachineName
    port       = $Port
    database   = $Database
}

# Формируем payload для бэкенда
$payload = @{
    version    = "v$($project.version)"
    dbms       = 'postgresql'
    timestamp  = (Get-Date -Format 'o')
    server     = $serverInfo
    parameters = @($results | ForEach-Object {
        @{
            key     = $_.Key
            value   = $_.Value
            display = $_.CurrentValue
            section = $_.Section
            label   = $_.Problem
        }
    })
}

if (-not $NoHtml) {
    Write-Host ""
    Write-Host "  [6/6] Сохранение отчёта..." -ForegroundColor White

    try {
        $reportPath = Export-DiagnosticReport -Results $results -ServerInfo $serverInfo
        Write-Host "  HTML-отчёт: $reportPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  Не удалось сохранить HTML-отчёт: $_" -ForegroundColor Yellow
    }

    # Сохраняем JSON
    try {
        $jsonPath = $reportPath -replace '\.html$', '.json'
        $payload | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host "  JSON-данные: $jsonPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  Не удалось сохранить JSON: $_" -ForegroundColor Yellow
    }

    # Спрашиваем, открыть ли HTML-отчёт
    if ($reportPath -and (Test-Path $reportPath)) {
        $openReport = Read-Host "  Открыть отчёт в браузере? (Y/N)"
        if ($openReport -match '^[YyДд]') {
            try { Start-Process -FilePath $reportPath }
            catch { Write-Host "  Не удалось открыть: $_" -ForegroundColor Yellow }
        }
    }
}
else {
    Write-Host ""
    Write-Host "  [6/6] Генерация HTML-отчёта пропущена (-NoHtml)" -ForegroundColor DarkGray
}

# ============================================================================
# Шаг 6: Предложение углублённого анализа
# ============================================================================

if (-not $NoPrompt) {
    $analyzeUrl = "$($project.api_url)/analyze"
    Send-DiagnosticData -Results $results -Summary $summary -Payload $payload -ApiUrl $analyzeUrl
}

# ============================================================================
# Завершение
# ============================================================================

Write-Host ""
Write-Host "  Диагностика завершена." -ForegroundColor Cyan
Write-Host "  https://github.com/air900/check-parameters-sql-server-for-1c" -ForegroundColor DarkGray
Write-Host ""
