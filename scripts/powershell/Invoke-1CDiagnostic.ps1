<#
.SYNOPSIS
    Диагностика СУБД (PostgreSQL и MS SQL Server) для 1С:Предприятие

.DESCRIPTION
    Собирает сведения о сервере баз данных 1С, выводит их в консоль и
    сохраняет на рабочий стол в JSON и HTML. Для проверки настроек
    требуется отправить собранные данные в сервис анализа. Скрипт
    отправляет данные только после подтверждения в консоли.

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
    Не сохранять локальные файлы HTML и JSON.

.PARAMETER NoPrompt
    Не спрашивать об отправке и не отправлять данные на анализ.

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1

.EXAMPLE
    .\Invoke-1CDiagnostic.ps1 -PgHost 192.0.2.10 -Port 5433 -Database my1c_db

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
    $project = [PSCustomObject]@{
        version      = '2.12.16'
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
Write-Host "  $($project.display_name)  v$($project.version)  ($($project.vendor))" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Шаг 1: Определение СУБД (PostgreSQL и/или MS SQL Server)
# ============================================================================

Write-Host "  [1/6] Поиск PostgreSQL и MS SQL Server" -ForegroundColor White

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
$selectedEngine = $null

if ($DBMS -eq 'postgresql') {
    if (-not $pgFound) {
        Write-Host ""
        Write-Host "  PostgreSQL не найден. Проверьте, установлен ли он на этом сервере." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selectedEngine = 'postgresql'
}
elseif ($DBMS -eq 'mssql') {
    if (-not $mssqlFound) {
        Write-Host ""
        Write-Host "  MS SQL Server не найден. Проверьте, установлен ли он на этом сервере." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selectedEngine = 'mssql'
}
else {
    # auto: предпочитаем работающий экземпляр
    $pgRunning    = ($pgInstances    | Where-Object { $_.Status -eq 'Running' }).Count -gt 0
    $mssqlRunning = ($mssqlInstances | Where-Object { $_.Status -eq 'Running' }).Count -gt 0

    if ($pgFound -and -not $mssqlFound) {
        $selectedEngine = 'postgresql'
    }
    elseif ($mssqlFound -and -not $pgFound) {
        $selectedEngine = 'mssql'
    }
    elseif ($pgFound -and $mssqlFound) {
        # Оба обнаружены — предпочитаем работающий
        if ($pgRunning -and -not $mssqlRunning) {
            $selectedEngine = 'postgresql'
        }
        elseif ($mssqlRunning -and -not $pgRunning) {
            $selectedEngine = 'mssql'
        }
        else {
            Write-Host ""
            Write-Host "  Обнаружены обе СУБД: PostgreSQL и MS SQL Server." -ForegroundColor Yellow
            Write-Host "    [1] PostgreSQL" -ForegroundColor White
            Write-Host "    [2] MS SQL Server" -ForegroundColor White
            $choice = Read-Host "  Выберите сервер баз данных (1 или 2)"
            if ($choice.Trim() -eq '2') { $selectedEngine = 'mssql' }
            else                         { $selectedEngine = 'postgresql' }
        }
    }
    else {
        Write-Host ""
        Write-Host "На этом сервере не найдены PostgreSQL и MS SQL Server." -ForegroundColor Red
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

$databaseHost = if ($selectedEngine -eq 'postgresql') { $PgHost } else { $MssqlHost }
$localAddress = $null
$isLocalServer = ($databaseHost -in @('localhost', 'localhost.', '.', '(local)', [Environment]::MachineName) -or
    ([System.Net.IPAddress]::TryParse($databaseHost, [ref]$localAddress) -and
     [System.Net.IPAddress]::IsLoopback($localAddress)))

if ($selectedEngine -eq 'postgresql') {

# Используем первый найденный экземпляр
$pg = $pgInstances[0]
$pgVersion = if ($isLocalServer -and $pg.Version) { $pg.Version } else { "" }
$pgStatus  = if ($pg.Status)  { $pg.Status }  else { "неизвестно" }

if ($isLocalServer) {
    $pgVersionText = if ($pgVersion) { $pgVersion } else { "неизвестно" }
    Write-Host "  PostgreSQL $pgVersionText, порт $($pg.Port) ($pgStatus)" -ForegroundColor Green

    # Если несколько экземпляров — предупредить
    if ($pgInstances.Count -gt 1) {
        Write-Host "  Найдено экземпляров PostgreSQL: $($pgInstances.Count). Первый в списке — экземпляр с портом $($pg.Port)." -ForegroundColor DarkYellow
        for ($i = 0; $i -lt $pgInstances.Count; $i++) {
            $inst = $pgInstances[$i]
            $marker = if ($i -eq 0) { " <-- используем" } else { "" }
            Write-Host "    [$i] Порт $($inst.Port), версия $($inst.Version)$marker" -ForegroundColor Gray
        }
    }
}
else {
    Write-Host "  PostgreSQL на $PgHost"
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
Write-Host "  [2/6] Подключение к PostgreSQL" -ForegroundColor White

# Проверка раскладки клавиатуры перед вводом пароля
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $layout = [System.Windows.Forms.InputLanguage]::CurrentInputLanguage.Culture.Name
    if ($layout -match 'ru') {
        Write-Host "  Включена русская раскладка. Проверьте раскладку перед вводом пароля." -ForegroundColor Yellow
    }
}
catch { }

# Ввод пароля (скрыт звёздочками)
$securePass = Read-Host "  Введите пароль пользователя '$Username'" -AsSecureString
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
    Write-Host "  Подключение установлено." -ForegroundColor Green
}

# ============================================================================
# Шаг 3: Выбор базы данных
# ============================================================================

if (-not $Database) {
    Write-Host ""
    Write-Host "  [3/6] Поиск баз данных 1С" -ForegroundColor White

    # Определяем путь к psql для поиска баз
    $psqlForSearch = $psqlPath
    if (-not $psqlForSearch) {
        # Пробуем найти psql в PATH или стандартных путях
        $psqlCmd = Get-Command psql.exe -ErrorAction SilentlyContinue
        if ($psqlCmd) { $psqlForSearch = $psqlCmd.Source }
    }

    if ($psqlForSearch) {
        # statement_timeout=30s в запросе гарантирует, что скрипт не зависнет
        Write-Host "  Получение списка баз может занять до 30 секунд." -ForegroundColor Gray
        $databases = Find-1CDatabases -PsqlPath $psqlForSearch -PgHost $PgHost -Port $Port -Username $Username
        if ($null -eq $databases) { $databases = @() }

        if ($databases.Count -eq 0) {
            Write-Host "  Не удалось получить список баз данных." -ForegroundColor Yellow
        }
        elseif ($databases.Count -eq 1) {
            $Database = $databases[0].Name
            Write-Host "  База данных: $Database ($($databases[0].Size))" -ForegroundColor Green
        }
        else {
            Write-Host "  Найдено баз данных: $($databases.Count)" -ForegroundColor Green
            Write-Host ""
            for ($i = 0; $i -lt $databases.Count; $i++) {
                $db = $databases[$i]
                Write-Host "    [$($i + 1)] $($db.Name) ($($db.Size))" -ForegroundColor White
            }
            Write-Host ""

            $choice = Read-Host "  Выберите базу для сбора данных (1-$($databases.Count))"
            $choiceIdx = 0
            if ([int]::TryParse($choice, [ref]$choiceIdx) -and $choiceIdx -ge 1 -and $choiceIdx -le $databases.Count) {
                $Database = $databases[$choiceIdx - 1].Name
            }
            else {
                $Database = $databases[0].Name
                Write-Host "  В списке нет такого номера. Используется первая база." -ForegroundColor Yellow
            }
            Write-Host "  Выбрана база: $Database" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  psql не найден в PATH. Скрипт проверит папки установки PostgreSQL при сборе данных." -ForegroundColor Yellow
    }
}
else {
    Write-Host ""
    Write-Host "  [3/6] База данных: $Database" -ForegroundColor Green
}

# Очищаем PGPASSWORD после поиска баз (Invoke-SqlDiagnostic установит его сам)
Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

# ============================================================================
# Шаг 4: Запуск диагностики
# ============================================================================

Write-Host ""
Write-Host "  [4/6] Сбор данных PostgreSQL" -ForegroundColor White
Write-Host "  Сбор может занять 1–2 минуты." -ForegroundColor Gray

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
        $results = @(Invoke-SqlDiagnostic @invokeParams)

        if ($null -eq $results -or $results.Count -eq 0) {
            Write-Host "  PostgreSQL не вернул данные для отчёта. Проверьте подключение." -ForegroundColor Red
            exit 1
        }

        Write-Host "  Получено записей PostgreSQL: $($results.Count)" -ForegroundColor Green

        $sqlVersion = $results | Where-Object Key -eq '_info_pg_version' | Select-Object -First 1
        if ($sqlVersion.Value) {
            $pgVersion = $sqlVersion.Value
        }

        if ($isLocalServer) {
            # Сбор данных ОС и объединение с результатами SQL-диагностики
            Write-Host "  Сбор сведений об операционной системе" -ForegroundColor White
            try {
                $pgDataDir = if ($pg.DataDir) { $pg.DataDir } else { '' }
                $osResults = @(Collect-OSData -DataDir $pgDataDir)
                $results   = $results + $osResults
                Write-Host "  Получено записей об операционной системе: $($osResults.Count)" -ForegroundColor Green
            }
            catch {
                Write-Host "  Не удалось собрать сведения об операционной системе. $_" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "  Сбор данных прерван." -ForegroundColor Red
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

$serverInfo = @{
    pg_version = $pgVersion
    hostname   = $PgHost
    port       = $Port
    database   = $Database
}

}  # --- конец ветки PostgreSQL ---

elseif ($selectedEngine -eq 'mssql') {

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
        Write-Host "  Экземпляр '$MssqlInstance' не найден. Выберите имя из списка:" -ForegroundColor Red
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

$msVersion = if ($isLocalServer -and $ms.Version) { $ms.Version } else { 'неизвестно' }
$msStatus  = if ($ms.Status)  { $ms.Status }  else { 'неизвестно' }
$msEdition = if ($isLocalServer -and $ms.Edition) { $ms.Edition } else { '' }

# При неизвестном порте клиент подключается по имени экземпляра.
if ($Port -eq 0 -and $ms.Port) { $Port = $ms.Port }
$portText = if ($Port -gt 0) { ", порт $Port" } else { '' }
if ($isLocalServer) {
    Write-Host "  MS SQL Server $msVersion ($msEdition), экземпляр '$($ms.InstanceName)'$portText ($msStatus)" -ForegroundColor Green

    # Если несколько экземпляров — предупредить
    if ($mssqlInstances.Count -gt 1) {
        Write-Host "  Найдено экземпляров SQL Server: $($mssqlInstances.Count). Для сбора выбран '$($ms.InstanceName)'." -ForegroundColor DarkYellow
        for ($i = 0; $i -lt $mssqlInstances.Count; $i++) {
            $inst = $mssqlInstances[$i]
            $marker = if ($inst.InstanceName -eq $ms.InstanceName) { ' <-- используем' } else { '' }
            $instPortText = if ($inst.Port) { ", порт $($inst.Port)" } else { '' }
            Write-Host "    [$i] $($inst.InstanceName) ($($inst.Status)$instPortText)$marker" -ForegroundColor Gray
        }
    }
}
else {
    Write-Host "  MS SQL Server на $MssqlHost$portText"
}

# ============================================================================
# Шаг 2 (MSSQL): подготовка аутентификации
# ============================================================================

Write-Host ""
Write-Host "  [2/6] Подключение к MS SQL Server" -ForegroundColor White

# Если задан SqlUsername — используем SQL Auth
$mssqlUseWinAuth = $UseWindowsAuth
if (-not [string]::IsNullOrEmpty($SqlUsername)) {
    $mssqlUseWinAuth = $false
}

# Если SQL Auth и пароль не передан — спрашиваем
if (-not $mssqlUseWinAuth -and [string]::IsNullOrEmpty($SqlPassword)) {
    $securePass = Read-Host "  Введите пароль пользователя SQL '$SqlUsername'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    $SqlPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ($mssqlUseWinAuth) {
    Write-Host "  Подключаемся под текущей учётной записью Windows." -ForegroundColor Gray
}
else {
    Write-Host "  Подключаемся под учётной записью SQL Server '$SqlUsername'." -ForegroundColor Gray
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
    Write-Host "  Не удалось подключиться к MS SQL Server (код $($conn.ExitCode))." -ForegroundColor Red
    if ($conn.Error) {
        $conn.Error -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    Write-Host ""
    Write-Host "  Проверьте:" -ForegroundColor Yellow
    if ($Port -gt 0) {
        Write-Host "    - Доступность сервера ${MssqlHost}:$Port" -ForegroundColor Yellow
    }
    Write-Host "    - Имя экземпляра '$($ms.InstanceName)'" -ForegroundColor Yellow
    if ($mssqlUseWinAuth) {
        Write-Host "    - Права текущей учётной записи Windows на экземпляре" -ForegroundColor Yellow
    }
    else {
        Write-Host "    - Имя и пароль учётной записи SQL Server" -ForegroundColor Yellow
    }
    Write-Host ""
    exit 1
}
Write-Host "  Подключение установлено." -ForegroundColor Green

# ============================================================================
# Шаг 3 (MSSQL): поиск базы 1С
# ============================================================================

Write-Host ""
if ([string]::IsNullOrEmpty($Database)) {
    Write-Host "  [3/6] Поиск баз данных 1С" -ForegroundColor White
    Write-Host "  Поиск баз может занять до 30 секунд." -ForegroundColor Gray

    $oneCdbs = @(Find-1CDatabasesOnMssql `
        -ServerHost     $MssqlHost `
        -InstanceName   $ms.InstanceName `
        -Port           $Port `
        -UseWindowsAuth $mssqlUseWinAuth `
        -Username       $SqlUsername `
        -Password       $SqlPassword)

    if ($oneCdbs.Count -eq 0) {
        Write-Host "  Базы 1С не найдены. Сбор начнётся с системной базы master." -ForegroundColor Yellow
        $Database = 'master'
    }
    elseif ($oneCdbs.Count -eq 1) {
        $Database = $oneCdbs[0]
        Write-Host "  База 1С: $Database" -ForegroundColor Green
    }
    else {
        Write-Host "  Найдено баз 1С: $($oneCdbs.Count)" -ForegroundColor Green
        Write-Host ""
        for ($i = 0; $i -lt $oneCdbs.Count; $i++) {
            Write-Host "    [$($i + 1)] $($oneCdbs[$i])" -ForegroundColor White
        }
        Write-Host ""
        $choice = Read-Host "  Выберите базу для сбора данных (1-$($oneCdbs.Count))"
        $choiceIdx = 0
        if ([int]::TryParse($choice, [ref]$choiceIdx) -and $choiceIdx -ge 1 -and $choiceIdx -le $oneCdbs.Count) {
            $Database = $oneCdbs[$choiceIdx - 1]
        }
        else {
            $Database = $oneCdbs[0]
            Write-Host "  В списке нет такого номера. Используется первая база." -ForegroundColor Yellow
        }
        Write-Host "  Выбрана база: $Database" -ForegroundColor Green
    }
}
else {
    Write-Host "  [3/6] База данных: $Database" -ForegroundColor Green
}

# ============================================================================
# Шаг 4 (MSSQL): запуск T-SQL коллектора + сбор OS-context
# ============================================================================

Write-Host ""
Write-Host "  [4/6] Сбор данных MS SQL Server" -ForegroundColor White
Write-Host "  Сбор данных экземпляра может занять 1–2 минуты." -ForegroundColor Gray

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
        Write-Host "  MS SQL Server не вернул данные для отчёта. Проверьте подключение и права учётной записи." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Получено записей MS SQL Server: $($results.Count)" -ForegroundColor Green
    $productVersion = $results | Where-Object Key -eq '_info_sql_version' | Select-Object -First 1
    if ($productVersion.Value) { $msVersion = $productVersion.Value }
    if ($Port -eq 0) {
        $tcpPortRow = $results | Where-Object Key -eq '_info_tcp_port' | Select-Object -First 1
        $tcpPort = 0
        if ([int]::TryParse([string]$tcpPortRow.Value, [ref]$tcpPort) -and $tcpPort -ge 1 -and $tcpPort -le 65535) {
            $Port = $tcpPort
        }
    }

    if ($isLocalServer) {
        $reportedInstance = $ms.InstanceName
        # OS-context (специфичный для MSSQL)
        Write-Host "  Сбор сведений об операционной системе" -ForegroundColor White
        try {
            $osMssqlRows = @(Get-MssqlOSContext -Instances $mssqlInstances)
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
                Write-Host "  Не удалось собрать общие сведения об операционной системе. $_" -ForegroundColor Yellow
            }

            $results = $results + $osNormalized + $osCommon
            Write-Host "  Получено записей об операционной системе: $($osNormalized.Count + $osCommon.Count)" -ForegroundColor Green
        }
        catch {
            Write-Host "  Не удалось собрать сведения об операционной системе для SQL Server. $_" -ForegroundColor Yellow
        }
    }
    else {
        $sqlInstance = $results | Where-Object Key -eq '_info_instance' | Select-Object -First 1
        $sqlHost = $results | Where-Object Key -eq '_info_hostname' | Select-Object -First 1
        $reportedInstance = $sqlInstance.Value
    }
}
catch {
    Write-Host ""
    Write-Host "  Сбор данных прерван." -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host ""
    exit 1
}
finally {
    # Очистка пароля из памяти
    $SqlPassword = $null
    [GC]::Collect()
}

$serverInfo = @{
    pg_version     = ""
    mssql_version  = $msVersion
    mssql_edition  = $msEdition
    mssql_instance = $reportedInstance
    hostname       = if ($sqlHost.Value) { $sqlHost.Value } else { $MssqlHost }
    port           = if ($Port -gt 0) { $Port } else { 'instance:' + $ms.InstanceName.ToUpperInvariant() }
    database       = $Database
}

}  # --- конец ветки MS SQL Server ---

if ($isLocalServer) {
    $serverInfo.os = [Environment]::OSVersion.VersionString
    $serverInfo.ram = "{0:N0} GB" -f ([math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 0))
    $serverInfo.cpu_cores = [Environment]::ProcessorCount
    $serverInfo.hostname = [Environment]::MachineName
}
else {
    Write-Host "  Для удалённой СУБД собраны только данные SQL."
}

# Подготавливаем JSON с исходными именами разделов для сервиса анализа.
$payload = @{
    version    = "v$($project.version)"
    dbms       = $selectedEngine
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

# Названия разделов для консоли и локального HTML.
$sectionNames = @{
    all_settings    = 'Текущие настройки PostgreSQL'
    archiving       = 'Архивирование журнала транзакций'
    auth            = 'Аутентификация и права доступа'
    autovacuum      = 'Автоочистка таблиц'
    bgwriter        = 'Фоновая запись'
    bloat           = 'Неиспользуемое место в таблицах и индексах'
    compat_1c       = 'Совместимость с 1С'
    connections     = 'Подключения'
    extensions      = 'Расширения PostgreSQL'
    idle_sessions   = 'Неактивные сеансы'
    instance_config = 'Настройки экземпляра SQL Server'
    io              = 'Дисковый ввод-вывод'
    limits          = 'Лимиты и ожидание операций'
    locks           = 'Блокировки'
    maintenance     = 'Обслуживание баз данных'
    memory          = 'Память'
    metrics         = 'Накопленные показатели PostgreSQL'
    monitoring      = 'Настройки мониторинга'
    os_cpu          = 'Процессор'
    os_disk         = 'Диски'
    os_info         = 'Операционная система'
    os_mssql        = 'Среда SQL Server'
    os_net          = 'Сетевые интерфейсы'
    os_power        = 'Электропитание'
    os_ram          = 'Оперативная память Windows'
    os_swap         = 'Файл подкачки Windows'
    os_virt         = 'Виртуализация'
    parallelism     = 'Параллельное выполнение запросов'
    planner         = 'Планировщик запросов'
    query_store     = 'Хранилище запросов (Query Store)'
    recovery        = 'Восстановление баз данных'
    runtime         = 'Показатели работы SQL Server'
    runtime_agg     = 'Сводные показатели SQL Server'
    security        = 'Безопасность'
    server_info     = 'Сведения о сервере баз данных'
    sessions        = 'Сеансы PostgreSQL'
    statistics      = 'Статистика и индексы'
    temp_tables     = 'Временные таблицы'
    tempdb          = 'Временная база tempdb'
    top_tables      = 'Крупнейшие таблицы'
    traceflags      = 'Флаги трассировки'
    wait_events     = 'Ожидания PostgreSQL'
    wal             = 'Журнал транзакций (WAL)'
    workload        = 'Нагрузка базы данных'
}
$displayResults = @($results | ForEach-Object {
    $section = [string]$_.Section
    if ($sectionNames.ContainsKey($section)) { $section = $sectionNames[$section] }
    [pscustomobject]@{ Section = $section; Problem = $_.Problem; CurrentValue = $_.CurrentValue }
})

Write-Host ""
Write-Host "  [5/6] Собранные данные" -ForegroundColor White
$summary = Show-DiagnosticResults -Results $displayResults

Write-Host ""
if (-not $NoHtml) {
    Write-Host "  [6/6] Сохранение собранных данных" -ForegroundColor White

    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $fileName = "1c-$selectedEngine-diagnostic"
    try {
        $jsonPath = Join-Path $desktopPath "$fileName.json" -ErrorAction Stop
        $payload | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $jsonPath -Encoding UTF8 -ErrorAction Stop
        Write-Host "  Собранные данные (JSON) сохранены в $jsonPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  Не удалось сохранить собранные данные в JSON. $_" -ForegroundColor Yellow
    }

    try {
        $htmlPath = Join-Path $desktopPath "$fileName.html" -ErrorAction Stop
        $reportPath = Export-DiagnosticReport -Results $displayResults -ServerInfo $serverInfo -OutputPath $htmlPath
        Write-Host "  Сводка сбора (HTML) сохранена в $reportPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  Не удалось сохранить сводку сбора в HTML. $_" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  [6/6] Сохранение файлов пропущено (-NoHtml)" -ForegroundColor DarkGray
}

# ============================================================================
# Шаг 6: Отправка данных на анализ
# ============================================================================

if (-not $NoPrompt) {
    $analyzeUrl = "$($project.api_url)/analyze"
    Send-DiagnosticData -Results $results -Summary $summary -Payload $payload -Dbms $selectedEngine -ApiUrl $analyzeUrl
}
else {
    Write-Host "  Собранные данные не отправлены (-NoPrompt)." -ForegroundColor DarkGray
}


# ============================================================================
# Завершение
# ============================================================================

Write-Host ""
Write-Host "  Сбор данных завершён." -ForegroundColor Cyan
Write-Host "  https://github.com/air900/check-parameters-sql-server-for-1c" -ForegroundColor DarkGray
Write-Host ""
