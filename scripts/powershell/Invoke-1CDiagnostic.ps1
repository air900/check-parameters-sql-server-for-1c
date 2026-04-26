<#
.SYNOPSIS
    Диагностика СУБД (PostgreSQL и MS SQL Server) для 1С:Предприятие

.DESCRIPTION
    Проверяет настройку СУБД-сервера, на котором работает 1С:Предприятие,
    и выявляет проблемы, влияющие на производительность.

    Скрипт автоматически:
    1. Определяет тип СУБД (PostgreSQL и/или MS SQL Server)
    2. Находит экземпляр и базу данных 1С
    3. Запускает диагностические проверки (read-only, безопасно)
    4. Показывает результаты с цветовой индикацией
    5. Сохраняет HTML-отчёт на Рабочий стол
    6. Предлагает отправить данные на углублённый анализ

.PARAMETER DBMS
    Тип СУБД: 'auto' (по умолчанию), 'postgresql' или 'mssql'.
    В режиме 'auto' предпочитается работающий экземпляр.

.PARAMETER PgHost
    Имя или IP-адрес сервера PostgreSQL. По умолчанию: localhost

.PARAMETER Port
    Порт СУБД. По умолчанию: определяется автоматически.

.PARAMETER Database
    Имя базы данных. Если не указано — автоматическое определение базы 1С.

.PARAMETER Username
    Имя пользователя PostgreSQL. По умолчанию: postgres
    (для MSSQL используется -SqlUsername).

.PARAMETER MssqlHost
    Имя или IP-адрес сервера MS SQL Server. По умолчанию: localhost

.PARAMETER MssqlInstance
    Имя экземпляра MS SQL Server (MSSQLSERVER для default).
    Если не указано — берётся из автоматического обнаружения.

.PARAMETER UseWindowsAuth
    Использовать Windows-аутентификацию для MSSQL (по умолчанию).
    Если выключить — потребуются -SqlUsername / -SqlPassword.

.PARAMETER SqlUsername
    Логин SQL-аутентификации MSSQL.

.PARAMETER SqlPassword
    Пароль SQL-аутентификации MSSQL.

.PARAMETER NoHtml
    Пропустить генерацию HTML-отчёта

.PARAMETER NoPrompt
    Пропустить предложение углублённого анализа (для автоматического запуска)

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1 -PgHost 192.168.1.10 -Port 5433 -Database my1c_db

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1 -DBMS mssql -MssqlInstance MSSQLSERVER

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1 -NoHtml -NoPrompt

.LINK
    https://github.com/air900/check-parameters-sql-server-for-1c
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('auto','postgresql','mssql')]
    [string]$DBMS = 'auto',

    [Parameter()]
    [string]$PgHost = "localhost",

    [Parameter()]
    [int]$Port = 0,

    [Parameter()]
    [string]$Database = "",

    [Parameter()]
    [string]$Username = "postgres",

    [Parameter()]
    [string]$MssqlHost = "localhost",

    [Parameter()]
    [string]$MssqlInstance = "",

    [Parameter()]
    [switch]$UseWindowsAuth,

    [Parameter()]
    [string]$SqlUsername = "",

    [Parameter()]
    [string]$SqlPassword = "",

    [Parameter()]
    [switch]$NoHtml,

    [Parameter()]
    [switch]$NoPrompt
)

# Windows Auth — по умолчанию TRUE если флаг не передан явно и нет SqlUsername
if (-not $PSBoundParameters.ContainsKey('UseWindowsAuth')) {
    $UseWindowsAuth = [string]::IsNullOrEmpty($SqlUsername)
}

$ErrorActionPreference = "Stop"

# ============================================================================
# Загрузка модулей
# ============================================================================

$modulesPath = Join-Path $PSScriptRoot "modules"

$requiredModules = @(
    'Find-PostgreSQL',
    'Invoke-SqlDiagnostic',
    'Find-MSSQL',
    'Invoke-MssqlDiagnostic',
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
        version      = '2.7.0'
        display_name = 'Диагностика PostgreSQL и MS SQL Server для 1С:Предприятие'
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
# Шаг 1: Определение СУБД (PostgreSQL и/или MS SQL Server)
# ============================================================================

Write-Host "  [1/6] Поиск СУБД (PostgreSQL и MS SQL Server)..." -ForegroundColor White

# --- Поиск PostgreSQL ---
$pgInstances = @()
try {
    $pgInstances = @(Find-PostgreSQL)
}
catch {
    Write-Verbose "Find-PostgreSQL завершился с ошибкой: $_"
}
$pgFound = ($pgInstances.Count -gt 0)

# --- Поиск MS SQL Server ---
$mssqlInstances = @()
try {
    $mssqlInstances = @(Find-MSSQL)
}
catch {
    Write-Verbose "Find-MSSQL завершился с ошибкой: $_"
}
$mssqlFound = ($mssqlInstances.Count -gt 0)

# --- Выбор движка по флагу -DBMS / автоопределение ---
$dbms = $null

if ($DBMS -eq 'postgresql') {
    if (-not $pgFound) {
        Write-Host ""
        Write-Host "  PostgreSQL не обнаружен (запрошен явно через -DBMS postgresql)." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $dbms = 'postgresql'
}
elseif ($DBMS -eq 'mssql') {
    if (-not $mssqlFound) {
        Write-Host ""
        Write-Host "  MS SQL Server не обнаружен (запрошен явно через -DBMS mssql)." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $dbms = 'mssql'
}
else {
    # auto: предпочитаем работающий экземпляр
    $pgRunning    = ($pgInstances    | Where-Object { $_.Status -eq 'Running' }).Count -gt 0
    $mssqlRunning = ($mssqlInstances | Where-Object { $_.Status -eq 'Running' }).Count -gt 0

    if ($pgFound -and -not $mssqlFound) {
        $dbms = 'postgresql'
    }
    elseif ($mssqlFound -and -not $pgFound) {
        $dbms = 'mssql'
    }
    elseif ($pgFound -and $mssqlFound) {
        # Оба обнаружены — предпочитаем работающий
        if ($pgRunning -and -not $mssqlRunning) {
            $dbms = 'postgresql'
        }
        elseif ($mssqlRunning -and -not $pgRunning) {
            $dbms = 'mssql'
        }
        else {
            Write-Host ""
            Write-Host "  Обнаружены обе СУБД: PostgreSQL и MS SQL Server." -ForegroundColor Yellow
            Write-Host "    [1] PostgreSQL" -ForegroundColor White
            Write-Host "    [2] MS SQL Server" -ForegroundColor White
            $choice = Read-Host "  Какую СУБД диагностировать? (1/2)"
            if ($choice.Trim() -eq '2') { $dbms = 'mssql' }
            else                         { $dbms = 'postgresql' }
        }
    }
    else {
        Write-Host ""
        Write-Host "  Ни PostgreSQL, ни MS SQL Server не обнаружены на этом сервере." -ForegroundColor Red
        Write-Host "  Укажите параметры подключения вручную:" -ForegroundColor Yellow
        Write-Host "    .\Invoke-1CDiagnostic.ps1 -PgHost <host> -Port <port>" -ForegroundColor Yellow
        Write-Host "    .\Invoke-1CDiagnostic.ps1 -DBMS mssql -MssqlHost <host>" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

# ============================================================================
# Ветвление: PostgreSQL vs MS SQL Server
# ============================================================================

# Общие переменные результата (заполняются в одной из веток)
$results    = @()
$serverInfo = @{}
$pgVersion  = $null

if ($dbms -eq 'postgresql') {

# Используем первый найденный экземпляр
$pg = $pgInstances[0]
$pgVersion = if ($pg.Version) { $pg.Version } else { "неизвестно" }
$pgStatus  = if ($pg.Status)  { $pg.Status }  else { "неизвестно" }

Write-Host "  Обнаружен: PostgreSQL $pgVersion, порт $($pg.Port) ($pgStatus)" -ForegroundColor Green

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
Write-Host "  Выполнение SQL-скрипта (может занять 1-2 мин)..." -ForegroundColor Gray

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

# Собираем информацию о сервере PostgreSQL (для отчёта и payload)
$serverInfo = @{
    pg_version = $pgVersion
    os         = [System.Environment]::OSVersion.VersionString
    ram        = "{0:N0} GB" -f ([math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 0))
    cpu_cores  = [Environment]::ProcessorCount
    hostname   = [Environment]::MachineName
    port       = $Port
    database   = $Database
}

}  # --- конец ветки PostgreSQL ---

elseif ($dbms -eq 'mssql') {

# ============================================================================
# Ветка MS SQL Server: шаги 1.MSSQL — 4.MSSQL
# ============================================================================

# --- Выбор экземпляра ---
# Если указан -MssqlInstance — ищем по имени; иначе берём первый Running, либо первый из списка
$ms = $null
if (-not [string]::IsNullOrEmpty($MssqlInstance)) {
    $ms = $mssqlInstances | Where-Object { $_.InstanceName -eq $MssqlInstance } | Select-Object -First 1
    if ($null -eq $ms) {
        Write-Host ""
        Write-Host "  Экземпляр '$MssqlInstance' не найден. Доступные:" -ForegroundColor Red
        foreach ($inst in $mssqlInstances) {
            Write-Host "    - $($inst.InstanceName) ($($inst.Status))" -ForegroundColor Yellow
        }
        Write-Host ""
        exit 1
    }
}
else {
    $running = $mssqlInstances | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1
    if ($running) { $ms = $running } else { $ms = $mssqlInstances[0] }
    $MssqlInstance = $ms.InstanceName
}

$msVersion = if ($ms.Version) { $ms.Version } else { 'неизвестно' }
$msStatus  = if ($ms.Status)  { $ms.Status }  else { 'неизвестно' }
$msEdition = if ($ms.Edition) { $ms.Edition } else { '' }

Write-Host "  Обнаружен: MS SQL Server $msVersion ($msEdition), экземпляр '$($ms.InstanceName)', порт $($ms.Port) ($msStatus)" -ForegroundColor Green

# Если несколько экземпляров — предупредить
if ($mssqlInstances.Count -gt 1) {
    Write-Host "  Найдено экземпляров: $($mssqlInstances.Count). Используем '$($ms.InstanceName)'." -ForegroundColor DarkYellow
    for ($i = 0; $i -lt $mssqlInstances.Count; $i++) {
        $inst = $mssqlInstances[$i]
        $marker = if ($inst.InstanceName -eq $ms.InstanceName) { ' <-- используем' } else { '' }
        Write-Host "    [$i] $($inst.InstanceName) (порт $($inst.Port), статус $($inst.Status))$marker" -ForegroundColor Gray
    }
}

# Применяем порт из обнаруженного экземпляра, если не задан явно
if ($Port -eq 0) { $Port = $ms.Port }

# ============================================================================
# Шаг 2 (MSSQL): подготовка аутентификации
# ============================================================================

Write-Host ""
Write-Host "  [2/6] Подключение к MS SQL Server..." -ForegroundColor White

# Если задан SqlUsername — используем SQL Auth
$mssqlUseWinAuth = $UseWindowsAuth
if (-not [string]::IsNullOrEmpty($SqlUsername)) {
    $mssqlUseWinAuth = $false
}

# Если SQL Auth и пароль не передан — спрашиваем
if (-not $mssqlUseWinAuth -and [string]::IsNullOrEmpty($SqlPassword)) {
    $securePass = Read-Host "  Пароль для пользователя SQL '$SqlUsername'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    $SqlPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ($mssqlUseWinAuth) {
    Write-Host "  Аутентификация: Windows (текущий пользователь)" -ForegroundColor Gray
}
else {
    Write-Host "  Аутентификация: SQL ('$SqlUsername')" -ForegroundColor Gray
}

# Тестовое подключение
Write-Host "  Проверка подключения..." -ForegroundColor Gray
$conn = Test-MssqlConnection `
    -ServerHost     $MssqlHost `
    -InstanceName   $ms.InstanceName `
    -Port           $Port `
    -UseWindowsAuth $mssqlUseWinAuth `
    -Username       $SqlUsername `
    -Password       $SqlPassword

if (-not $conn.Success) {
    Write-Host ""
    Write-Host "  [!] Ошибка подключения к MS SQL Server (exit $($conn.ExitCode)):" -ForegroundColor Red
    if ($conn.Error) {
        $conn.Error -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    Write-Host ""
    Write-Host "  Проверьте:" -ForegroundColor Yellow
    Write-Host "    - Доступность сервера ${MssqlHost}:$Port (порт открыт?)" -ForegroundColor Yellow
    Write-Host "    - Имя экземпляра '$($ms.InstanceName)'" -ForegroundColor Yellow
    if ($mssqlUseWinAuth) {
        Write-Host "    - Права текущего Windows-пользователя на инстанс" -ForegroundColor Yellow
    }
    else {
        Write-Host "    - Логин/пароль SQL Auth" -ForegroundColor Yellow
    }
    Write-Host ""
    exit 1
}
Write-Host "  Подключение успешно." -ForegroundColor Green

# ============================================================================
# Шаг 3 (MSSQL): поиск базы 1С
# ============================================================================

Write-Host ""
if ([string]::IsNullOrEmpty($Database)) {
    Write-Host "  [3/6] Поиск баз данных 1С..." -ForegroundColor White
    Write-Host "  Опрос экземпляра (может занять до 30 сек)..." -ForegroundColor Gray

    $oneCdbs = @(Find-1CDatabasesOnMssql `
        -ServerHost     $MssqlHost `
        -InstanceName   $ms.InstanceName `
        -Port           $Port `
        -UseWindowsAuth $mssqlUseWinAuth `
        -Username       $SqlUsername `
        -Password       $SqlPassword)

    if ($oneCdbs.Count -eq 0) {
        Write-Host "  Базы 1С не обнаружены. Используем master." -ForegroundColor Yellow
        $Database = 'master'
    }
    elseif ($oneCdbs.Count -eq 1) {
        $Database = $oneCdbs[0]
        Write-Host "  База 1С: $Database" -ForegroundColor Green
    }
    else {
        Write-Host "  Обнаружено баз 1С: $($oneCdbs.Count)" -ForegroundColor Green
        Write-Host ""
        for ($i = 0; $i -lt $oneCdbs.Count; $i++) {
            Write-Host "    [$($i + 1)] $($oneCdbs[$i])" -ForegroundColor White
        }
        Write-Host ""
        $choice = Read-Host "  Выберите базу для проверки (1-$($oneCdbs.Count))"
        $choiceIdx = 0
        if ([int]::TryParse($choice, [ref]$choiceIdx) -and $choiceIdx -ge 1 -and $choiceIdx -le $oneCdbs.Count) {
            $Database = $oneCdbs[$choiceIdx - 1]
        }
        else {
            $Database = $oneCdbs[0]
            Write-Host "  Некорректный выбор. Используем: $Database" -ForegroundColor Yellow
        }
        Write-Host "  Выбрана база: $Database" -ForegroundColor Green
    }
}
else {
    Write-Host "  [3/6] База данных: $Database (указана явно)" -ForegroundColor Green
}

# ============================================================================
# Шаг 4 (MSSQL): запуск T-SQL коллектора + сбор OS-context
# ============================================================================

Write-Host ""
Write-Host "  [4/6] Запуск диагностики MS SQL Server..." -ForegroundColor White
Write-Host "  Выполнение T-SQL скрипта (может занять 1-2 мин)..." -ForegroundColor Gray

try {
    $results = Invoke-MssqlSqlDiagnostic `
        -ServerHost     $MssqlHost `
        -InstanceName   $ms.InstanceName `
        -Port           $Port `
        -Database       $Database `
        -UseWindowsAuth $mssqlUseWinAuth `
        -Username       $SqlUsername `
        -Password       $SqlPassword

    if ($null -eq $results -or $results.Count -eq 0) {
        Write-Host "  Диагностика не вернула результатов. Проверьте подключение и права." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Получено проверок MS SQL Server: $($results.Count)" -ForegroundColor Green

    # OS-context (специфичный для MSSQL)
    Write-Host "  Сбор OS-данных (NTFS block size, Defender exclusions, power plan)..." -ForegroundColor White
    try {
        $osMssqlRows = @(Get-MssqlOSContext -Instances $mssqlInstances)
        # Преобразуем формат: коллектор возвращает Display+Value+Label, а главный пайплайн
        # ожидает поля Problem (=Label), CurrentValue (=Display), Status/Detected/Impact
        $osNormalized = @($osMssqlRows | ForEach-Object {
            [PSCustomObject]@{
                N            = $_.N
                Section      = $_.Section
                Key          = $_.Key
                Problem      = $_.Label
                CurrentValue = $_.Display
                Value        = $_.Value
                Status       = ''
                Detected     = ''
                Impact       = ''
            }
        })

        # Общий OS-блок (CPU/RAM/диски/сеть/виртуализация) — используем существующий Collect-OS
        $osCommon = @()
        try {
            $osCommon = @(Collect-OSData -DataDir $(if ($ms.DataDir) { $ms.DataDir } else { '' }))
        }
        catch {
            Write-Host "  Предупреждение: не удалось собрать общие данные ОС: $_" -ForegroundColor Yellow
        }

        $results = $results + $osNormalized + $osCommon
        Write-Host "  Данные ОС собраны: MSSQL-spec=$($osNormalized.Count), общих=$($osCommon.Count)" -ForegroundColor Green
    }
    catch {
        Write-Host "  Предупреждение: не удалось собрать OS-context для MSSQL: $_" -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "  Ошибка при выполнении диагностики:" -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Проверьте:" -ForegroundColor Yellow
    Write-Host "    - Доступность сервера ${MssqlHost}:$Port" -ForegroundColor Yellow
    Write-Host "    - Имя экземпляра и базы" -ForegroundColor Yellow
    Write-Host "    - Права пользователя на VIEW SERVER STATE" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
finally {
    # Очистка пароля из памяти
    $SqlPassword = $null
    [GC]::Collect()
}

# Информация о сервере для отчёта и payload (MSSQL)
$serverInfo = @{
    pg_version    = $null
    mssql_version = $msVersion
    mssql_edition = $msEdition
    mssql_instance= $ms.InstanceName
    os            = [System.Environment]::OSVersion.VersionString
    ram           = "{0:N0} GB" -f ([math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 0))
    cpu_cores     = [Environment]::ProcessorCount
    hostname      = [Environment]::MachineName
    port          = $Port
    database      = $Database
}

}  # --- конец ветки MS SQL Server ---

# ============================================================================
# Шаг 5: Показ результатов (общий для всех СУБД)
# ============================================================================

Write-Host ""
Write-Host "  [5/6] Результаты анализа:" -ForegroundColor White

$summary = Show-DiagnosticResults -Results $results

# ============================================================================
# Шаг 5b: Формирование payload (общий)
# ============================================================================

# Формируем payload для бэкенда
$payload = @{
    version    = "v$($project.version)"
    dbms       = $dbms
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

    Write-Host ""
    Write-Host "  Предварительный отчёт сохранён на Рабочий стол." -ForegroundColor Cyan
    Write-Host "  Данные готовы к отправке на анализ корректности настройки сервера СУБД." -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "  [6/6] Генерация HTML-отчёта пропущена (-NoHtml)" -ForegroundColor DarkGray
    Write-Host "  Данные готовы к отправке на анализ корректности настройки сервера СУБД." -ForegroundColor Cyan
}

# ============================================================================
# Шаг 6: Отправка данных на анализ
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
