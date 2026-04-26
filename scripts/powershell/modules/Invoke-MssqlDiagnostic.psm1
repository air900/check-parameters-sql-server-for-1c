#Requires -Version 5.1
# ============================================================================
# Модуль: Invoke-MssqlDiagnostic.psm1
# ============================================================================
#
# Назначение:
#   Запускает диагностический T-SQL-скрипт для MS SQL Server через sqlcmd.exe
#   и возвращает результаты в виде массива структурированных объектов
#   (совместимых с Show-DiagnosticResults / Export-DiagnosticReport).
#
# Совместимость: PowerShell 5.1+ (Windows), sqlcmd 13.1+
#
# Экспортируемые функции:
#   Test-MssqlConnection         — проверка подключения (Windows / SQL Auth)
#   Invoke-MssqlSqlDiagnostic    — запуск T-SQL коллектора, парсинг строк
#   Find-1CDatabasesOnMssql      — поиск баз 1С (по таблицам Config/Params/_users/_yearoffset)
#
# Архитектурные решения (см. README модулей и CLAUDE.md):
#   - sqlcmd запускается с -u (UTF-16 LE output) + -o tempfile, далее
#     Get-Content -Encoding Unicode. Это бронебойно по кириллице (Label/Display
#     в коллекторе содержат русский текст) и не зависит от консольной кодовой
#     страницы клиента.
#   - tcp:<host>,<port> — единый формат сервера (default или named instance).
#     Для default instance с MSSQLSERVER достаточно <host>, но единый формат
#     минует SQL Browser и более предсказуем при нестандартных портах.
#   - Все native-вызовы оборачиваются в try/catch + локальное переключение
#     $ErrorActionPreference='Continue', т.к. главный скрипт использует 'Stop'
#     и stderr от sqlcmd не должен бросать исключения (PS 5.1 pitfall).
#   - Кириллица в -Q НЕ передаётся: запросы ASCII-only, либо через -i файл.
#
# ============================================================================

# Путь к T-SQL-скрипту относительно папки модуля
$script:SqlScriptRelativePath = '..\..\sql\Collect-MSSQL-1C-Data.sql'

# Стандартные пути установки sqlcmd на Windows
# Порядок: сначала новый go-sqlcmd (из PATH), затем классический sqlcmd 17/15/13
$script:SqlcmdCommonPaths = @(
    'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\150\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\110\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\150\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\150\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\140\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\130\Tools\Binn\SQLCMD.EXE'
)

# ---------------------------------------------------------------------------
# Внутренние утилиты
# ---------------------------------------------------------------------------

function Find-SqlcmdExecutable {
    <#
    .SYNOPSIS
        Ищет sqlcmd.exe в PATH и стандартных путях установки.
    .OUTPUTS
        [string] Полный путь к sqlcmd.exe или $null, если не найден.
    #>
    [OutputType([string])]
    param()

    # Сначала ищем в PATH
    $cmd = Get-Command -Name 'sqlcmd' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    foreach ($path in $script:SqlcmdCommonPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    return $null
}

function Get-MssqlServerString {
    <#
    .SYNOPSIS
        Формирует строку сервера для sqlcmd -S из host/instance/port.
    .DESCRIPTION
        Используется единый формат tcp:<host>,<port> когда порт известен —
        он минует SQL Browser и предсказуем для default/named instance.
        Если порт не указан, возвращается host\instance (или host для default).
    .OUTPUTS
        [string]
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerHost,

        [Parameter()]
        [string]$InstanceName,

        [Parameter()]
        [int]$Port = 0
    )

    if ($Port -gt 0) {
        return "tcp:$ServerHost,$Port"
    }

    if ([string]::IsNullOrEmpty($InstanceName) -or $InstanceName -eq 'MSSQLSERVER') {
        return $ServerHost
    }

    return "$ServerHost`\$InstanceName"
}

function Invoke-SqlcmdRaw {
    <#
    .SYNOPSIS
        Низкоуровневый запуск sqlcmd с UTF-16 LE выводом во временный файл.
    .DESCRIPTION
        Все вызовы sqlcmd идут через эту функцию. Особенности:
          - вывод направляется в tempfile через -o (бронебойно по кодировкам);
          - используется ключ -u (UTF-16 LE) — далее читаем Get-Content -Encoding Unicode;
          - -b: ошибки в скрипте поднимают ERRORLEVEL (даёт надёжный $LASTEXITCODE);
          - -l 10: login timeout 10 сек (быстрая ошибка вместо 30-сек висюки);
          - $ErrorActionPreference локально переводится в 'Continue' на время
            native-вызова (PS 5.1 pitfall: 'Stop' + stderr → исключение).
    .OUTPUTS
        [PSCustomObject] @{ ExitCode; Lines; ErrorText }
    #>
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlcmdPath,

        [Parameter(Mandatory = $true)]
        [string[]]$BaseArgs,

        [Parameter()]
        [string]$InputFile,

        [Parameter()]
        [string]$Query
    )

    # Готовим временные файлы для stdout (UTF-16) и stderr (ASCII/ANSI)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()

    # Собираем итоговый список аргументов
    $allArgs = New-Object System.Collections.Generic.List[string]
    foreach ($a in $BaseArgs) { [void]$allArgs.Add($a) }

    # -u UTF-16 LE output, -o tempfile, -b ERRORLEVEL on script errors,
    # -l 10 login timeout, -y 0 -Y 0 без обрезки колонок
    [void]$allArgs.Add('-u')
    [void]$allArgs.Add('-b')
    [void]$allArgs.Add('-l'); [void]$allArgs.Add('10')
    [void]$allArgs.Add('-y'); [void]$allArgs.Add('0')
    [void]$allArgs.Add('-Y'); [void]$allArgs.Add('0')
    [void]$allArgs.Add('-o'); [void]$allArgs.Add($tmpOut)

    if (-not [string]::IsNullOrEmpty($InputFile)) {
        [void]$allArgs.Add('-i'); [void]$allArgs.Add($InputFile)
    }
    elseif (-not [string]::IsNullOrEmpty($Query)) {
        [void]$allArgs.Add('-Q'); [void]$allArgs.Add($Query)
    }

    $exitCode = -1
    $errorText = ''
    $lines = @()

    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        # Используем Start-Process — позволяет надёжно перенаправить stderr в файл
        # и получить ExitCode без сюрпризов от $ErrorActionPreference.
        $proc = Start-Process -FilePath $SqlcmdPath `
            -ArgumentList $allArgs `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardError $tmpErr `
            -ErrorAction SilentlyContinue
        if ($null -ne $proc) { $exitCode = $proc.ExitCode }

        # Читаем stdout как UTF-16 LE
        if (Test-Path -LiteralPath $tmpOut) {
            $raw = Get-Content -LiteralPath $tmpOut -Encoding Unicode -ErrorAction SilentlyContinue
            if ($null -ne $raw) { $lines = @($raw) }
        }

        # Читаем stderr как UTF-8 (sqlcmd обычно пишет в OEM/UTF-8 в stderr,
        # но в любом случае это диагностика — не критично к кодировке).
        if (Test-Path -LiteralPath $tmpErr) {
            $errorText = (Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue)
            if ($null -eq $errorText) { $errorText = '' }
        }
    }
    catch {
        $errorText = $_.Exception.Message
    }
    finally {
        $ErrorActionPreference = $savedEAP
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpErr -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        ExitCode  = $exitCode
        Lines     = $lines
        ErrorText = $errorText
    }
}

function Get-SqlcmdAuthArgs {
    <#
    .SYNOPSIS
        Готовит аутентификационные аргументы sqlcmd: -E (Windows) либо -U/-P (SQL).
    .OUTPUTS
        [string[]]
    #>
    [OutputType([string[]])]
    param(
        [Parameter()]
        [bool]$UseWindowsAuth = $true,

        [Parameter()]
        [string]$Username,

        [Parameter()]
        [string]$Password
    )

    $authArgs = New-Object System.Collections.Generic.List[string]
    if ($UseWindowsAuth) {
        [void]$authArgs.Add('-E')
    }
    else {
        if ([string]::IsNullOrEmpty($Username)) {
            throw "Для SQL-аутентификации требуется параметр -Username."
        }
        [void]$authArgs.Add('-U'); [void]$authArgs.Add($Username)
        if ($null -ne $Password) {
            [void]$authArgs.Add('-P'); [void]$authArgs.Add($Password)
        }
    }
    return $authArgs.ToArray()
}

# ---------------------------------------------------------------------------
# Публичные функции
# ---------------------------------------------------------------------------

function Test-MssqlConnection {
    <#
    .SYNOPSIS
        Проверяет подключение к экземпляру MS SQL Server.
    .DESCRIPTION
        Запускает sqlcmd с простым ASCII-запросом ("SELECT @@VERSION").
        Поддерживает Windows-аутентификацию (по умолчанию) и SQL-аутентификацию
        (передайте -UseWindowsAuth:$false и -Username/-Password).
    .PARAMETER ServerHost
        Имя сервера или IP. По умолчанию: localhost.
    .PARAMETER InstanceName
        Имя экземпляра (MSSQLSERVER для default, либо named instance).
    .PARAMETER Port
        TCP-порт. Если задан — используется tcp:<host>,<port>.
    .PARAMETER UseWindowsAuth
        $true — Windows-аутентификация (-E). По умолчанию.
    .PARAMETER Username
        Логин для SQL-аутентификации.
    .PARAMETER Password
        Пароль для SQL-аутентификации.
    .PARAMETER SqlcmdPath
        Полный путь к sqlcmd.exe. Если не указан — автопоиск.
    .OUTPUTS
        [PSCustomObject] @{ Success; ExitCode; Output; Error }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string]$ServerHost = 'localhost',

        [Parameter()]
        [string]$InstanceName,

        [Parameter()]
        [int]$Port = 0,

        [Parameter()]
        [bool]$UseWindowsAuth = $true,

        [Parameter()]
        [string]$Username,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [string]$SqlcmdPath
    )

    if ([string]::IsNullOrEmpty($SqlcmdPath)) {
        $SqlcmdPath = Find-SqlcmdExecutable
    }
    if ([string]::IsNullOrEmpty($SqlcmdPath)) {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = -1
            Output   = ''
            Error    = 'sqlcmd.exe не найден. Установите Microsoft Command Line Utilities for SQL Server.'
        }
    }

    $serverStr = Get-MssqlServerString -ServerHost $ServerHost -InstanceName $InstanceName -Port $Port
    $authArgs  = Get-SqlcmdAuthArgs -UseWindowsAuth $UseWindowsAuth -Username $Username -Password $Password

    $baseArgs = New-Object System.Collections.Generic.List[string]
    [void]$baseArgs.Add('-S'); [void]$baseArgs.Add($serverStr)
    foreach ($a in $authArgs) { [void]$baseArgs.Add($a) }
    [void]$baseArgs.Add('-d'); [void]$baseArgs.Add('master')
    [void]$baseArgs.Add('-h'); [void]$baseArgs.Add('-1')
    [void]$baseArgs.Add('-W')

    $result = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $baseArgs.ToArray() -Query 'SET NOCOUNT ON; SELECT @@VERSION;'

    return [PSCustomObject]@{
        Success  = ($result.ExitCode -eq 0)
        ExitCode = $result.ExitCode
        Output   = (($result.Lines | Where-Object { $_ -is [string] -and $_.Trim() -ne '' }) -join [Environment]::NewLine)
        Error    = $result.ErrorText
    }
}

function Find-1CDatabasesOnMssql {
    <#
    .SYNOPSIS
        Находит базы 1С на экземпляре MS SQL Server.
    .DESCRIPTION
        Эвристика: база является базой 1С, если в ней присутствует ≥3 из таблиц
        Config, Params, _users, _yearoffset (учёт регистра — по правилам collation
        самой БД; ASCII-имена устойчивы).

        Алгоритм:
          1. Получить список online-баз через sys.databases (исключая системные
             master/tempdb/msdb/model/distribution/SSISDB и не-ONLINE состояния).
          2. Для каждой БД выполнить COUNT таблиц из этого набора, threshold ≥ 3.
          3. Каждый probe в try/catch — недоступная БД не должна обрывать цикл.

    .PARAMETER ServerHost
        Имя/IP сервера.
    .PARAMETER InstanceName
        Имя экземпляра (для default — MSSQLSERVER).
    .PARAMETER Port
        TCP-порт.
    .PARAMETER UseWindowsAuth
        $true — Windows-аутентификация (по умолчанию).
    .PARAMETER Username
        Логин SQL Auth.
    .PARAMETER Password
        Пароль SQL Auth.
    .PARAMETER SqlcmdPath
        Путь к sqlcmd.exe.
    .OUTPUTS
        [string[]] Имена баз, похожих на 1С.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [string]$ServerHost = 'localhost',

        [Parameter()]
        [string]$InstanceName,

        [Parameter()]
        [int]$Port = 0,

        [Parameter()]
        [bool]$UseWindowsAuth = $true,

        [Parameter()]
        [string]$Username,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [string]$SqlcmdPath
    )

    if ([string]::IsNullOrEmpty($SqlcmdPath)) {
        $SqlcmdPath = Find-SqlcmdExecutable
    }
    if ([string]::IsNullOrEmpty($SqlcmdPath)) {
        Write-Warning 'sqlcmd.exe не найден.'
        return @()
    }

    $serverStr = Get-MssqlServerString -ServerHost $ServerHost -InstanceName $InstanceName -Port $Port
    $authArgs  = Get-SqlcmdAuthArgs -UseWindowsAuth $UseWindowsAuth -Username $Username -Password $Password

    # --- Список пользовательских ONLINE-баз ---
    $listQuery = "SET NOCOUNT ON; SELECT name FROM sys.databases " +
                 "WHERE database_id > 4 " +
                 "AND name NOT IN ('distribution','SSISDB','ReportServer','ReportServerTempDB') " +
                 "AND state_desc = 'ONLINE' " +
                 "ORDER BY name;"

    $listBaseArgs = New-Object System.Collections.Generic.List[string]
    [void]$listBaseArgs.Add('-S'); [void]$listBaseArgs.Add($serverStr)
    foreach ($a in $authArgs) { [void]$listBaseArgs.Add($a) }
    [void]$listBaseArgs.Add('-d'); [void]$listBaseArgs.Add('master')
    [void]$listBaseArgs.Add('-h'); [void]$listBaseArgs.Add('-1')
    [void]$listBaseArgs.Add('-W')

    $listResult = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $listBaseArgs.ToArray() -Query $listQuery

    if ($listResult.ExitCode -ne 0) {
        Write-Warning "sqlcmd: не удалось получить список баз (exit $($listResult.ExitCode)). $($listResult.ErrorText)"
        return @()
    }

    $databases = @($listResult.Lines |
        Where-Object { $_ -is [string] -and $_.Trim() -ne '' } |
        ForEach-Object { $_.Trim() })

    if ($databases.Count -eq 0) {
        return @()
    }

    # --- Эвристика: ≥3 из {Config, Params, _users, _yearoffset} ---
    $probeQuery = "SET NOCOUNT ON; " +
                  "SELECT COUNT(*) FROM sys.tables " +
                  "WHERE name IN ('Config','Params','_users','_yearoffset');"

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($dbName in $databases) {
        try {
            $probeBaseArgs = New-Object System.Collections.Generic.List[string]
            [void]$probeBaseArgs.Add('-S'); [void]$probeBaseArgs.Add($serverStr)
            foreach ($a in $authArgs) { [void]$probeBaseArgs.Add($a) }
            [void]$probeBaseArgs.Add('-d'); [void]$probeBaseArgs.Add($dbName)
            [void]$probeBaseArgs.Add('-h'); [void]$probeBaseArgs.Add('-1')
            [void]$probeBaseArgs.Add('-W')

            $probe = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $probeBaseArgs.ToArray() -Query $probeQuery

            if ($probe.ExitCode -ne 0) { continue }

            $countLine = ($probe.Lines | Where-Object { $_ -is [string] -and $_.Trim() -ne '' } | Select-Object -First 1)
            if ($null -eq $countLine) { continue }

            $cnt = 0
            if ([int]::TryParse($countLine.Trim(), [ref]$cnt)) {
                if ($cnt -ge 3) {
                    [void]$found.Add($dbName)
                }
            }
        }
        catch {
            Write-Verbose "Find-1CDatabasesOnMssql: пропущена база '$dbName' — $($_.Exception.Message)"
            continue
        }
    }

    return $found.ToArray()
}

function ConvertFrom-MssqlPipeOutput {
    <#
    .SYNOPSIS
        Парсит вывод sqlcmd (формат -W -s "|" -h -1) в массив объектов.
    .DESCRIPTION
        Каждая строка должна содержать ровно 6 полей, разделённых '|':
            N | Section | Key | Label | Display | Value
        Пустые строки и строки с другим количеством полей пропускаются
        (между batch-ами с GO sqlcmd может вставлять пустые строки).
    .OUTPUTS
        [PSCustomObject[]]
    #>
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $results = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($lineRaw in $Lines) {
        if ($null -eq $lineRaw) { continue }
        $line = $lineRaw.TrimEnd()
        if ($line.Trim() -eq '') { continue }

        # sqlcmd может выводить служебные сообщения вида "(N rows affected)"
        # — отсекаем по отсутствию разделителя или некорректному кол-ву полей.
        if ($line -notlike '*|*') { continue }

        # split с лимитом 6 — Value может содержать '|' внутри JSON
        $fields = $line -split '\|', 6

        if ($fields.Count -lt 6) { continue }

        # Первое поле должно начинаться с цифры (это N)
        $n = $fields[0].Trim()
        if ($n -notmatch '^\d+$') { continue }

        $obj = [PSCustomObject]@{
            N            = $n
            Section      = $fields[1].Trim()
            Key          = $fields[2].Trim()
            Problem      = $fields[3].Trim()      # Label → Problem (совместимость)
            CurrentValue = $fields[4].Trim()      # Display → CurrentValue
            Value        = $fields[5].Trim()      # Value (machine-readable)
            Status       = ''
            Detected     = ''
            Impact       = ''
        }
        $results.Add($obj)
    }

    return $results.ToArray()
}

function Invoke-MssqlSqlDiagnostic {
    <#
    .SYNOPSIS
        Запускает T-SQL коллектор Collect-MSSQL-1C-Data.sql и возвращает результаты.
    .DESCRIPTION
        Использует sqlcmd с ключами -W -s "|" -h -1 — pipe-разделённый вывод
        без заголовков, без труcирования. Stdout направляется в tempfile в
        UTF-16 LE (-u + -o), затем читается Get-Content -Encoding Unicode —
        бронебойно по кириллице независимо от кодовой страницы консоли.

        База подключения по умолчанию: master (коллектор сам читает по серверу
        и tempdb; при необходимости можно указать -Database).
    .PARAMETER ServerHost
        Имя/IP сервера.
    .PARAMETER InstanceName
        Имя экземпляра (MSSQLSERVER для default).
    .PARAMETER Port
        TCP-порт; если указан — приоритетнее instance.
    .PARAMETER Database
        База для подключения (по умолчанию master).
    .PARAMETER UseWindowsAuth
        $true — Windows-аутентификация. По умолчанию.
    .PARAMETER Username
        Логин SQL Auth.
    .PARAMETER Password
        Пароль SQL Auth.
    .PARAMETER SqlcmdPath
        Путь к sqlcmd.exe.
    .PARAMETER SqlScriptPath
        Путь к T-SQL файлу. По умолчанию — Collect-MSSQL-1C-Data.sql рядом.
    .OUTPUTS
        [PSCustomObject[]]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [string]$ServerHost = 'localhost',

        [Parameter()]
        [string]$InstanceName,

        [Parameter()]
        [int]$Port = 0,

        [Parameter()]
        [string]$Database = 'master',

        [Parameter()]
        [bool]$UseWindowsAuth = $true,

        [Parameter()]
        [string]$Username,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [string]$SqlcmdPath,

        [Parameter()]
        [string]$SqlScriptPath
    )

    # --- 1. Поиск sqlcmd ---
    if ([string]::IsNullOrEmpty($SqlcmdPath)) {
        $SqlcmdPath = Find-SqlcmdExecutable
        if ([string]::IsNullOrEmpty($SqlcmdPath)) {
            throw "sqlcmd.exe не найден. Установите Microsoft Command Line Utilities for SQL Server."
        }
    }
    elseif (-not (Test-Path -LiteralPath $SqlcmdPath -PathType Leaf)) {
        throw "Указанный путь к sqlcmd не существует: $SqlcmdPath"
    }

    # --- 2. Путь к SQL-скрипту ---
    if ([string]::IsNullOrEmpty($SqlScriptPath)) {
        $moduleDir = $PSScriptRoot
        $SqlScriptPath = Join-Path -Path $moduleDir -ChildPath $script:SqlScriptRelativePath
        $SqlScriptPath = [System.IO.Path]::GetFullPath($SqlScriptPath)
    }
    if (-not (Test-Path -LiteralPath $SqlScriptPath -PathType Leaf)) {
        throw "T-SQL скрипт не найден: $SqlScriptPath"
    }
    Write-Verbose "T-SQL скрипт: $SqlScriptPath"

    # --- 3. Сборка аргументов ---
    $serverStr = Get-MssqlServerString -ServerHost $ServerHost -InstanceName $InstanceName -Port $Port
    $authArgs  = Get-SqlcmdAuthArgs -UseWindowsAuth $UseWindowsAuth -Username $Username -Password $Password

    $baseArgs = New-Object System.Collections.Generic.List[string]
    [void]$baseArgs.Add('-S'); [void]$baseArgs.Add($serverStr)
    foreach ($a in $authArgs) { [void]$baseArgs.Add($a) }
    [void]$baseArgs.Add('-d'); [void]$baseArgs.Add($Database)
    [void]$baseArgs.Add('-W')                # trim trailing whitespace
    [void]$baseArgs.Add('-s'); [void]$baseArgs.Add('|')
    [void]$baseArgs.Add('-h'); [void]$baseArgs.Add('-1')   # без заголовков

    Write-Verbose "Подключение: $serverStr (auth=$(if ($UseWindowsAuth) { 'Windows' } else { 'SQL' }))"
    Write-Verbose "Запуск sqlcmd с T-SQL коллектором..."

    $result = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $baseArgs.ToArray() -InputFile $SqlScriptPath

    if ($result.ExitCode -ne 0) {
        $errBody = $result.ErrorText
        if ([string]::IsNullOrEmpty($errBody)) { $errBody = '(stderr пуст)' }
        throw "sqlcmd завершился с кодом $($result.ExitCode).`n$errBody"
    }

    Write-Verbose "Получено строк вывода: $($result.Lines.Count)"

    if ($result.Lines.Count -eq 0) {
        throw "sqlcmd вернул пустой вывод. Возможно, в T-SQL скрипте есть ошибки или проблема с доступом."
    }

    $parsed = ConvertFrom-MssqlPipeOutput -Lines $result.Lines
    Write-Verbose "Разобрано записей: $($parsed.Count)"

    if ($parsed.Count -eq 0) {
        throw "Парсер не получил ни одной валидной строки результата (формат N|Section|Key|Label|Display|Value)."
    }

    return $parsed
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function 'Test-MssqlConnection', 'Invoke-MssqlSqlDiagnostic', 'Find-1CDatabasesOnMssql'
