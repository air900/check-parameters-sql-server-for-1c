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

# Per-DB скрипт (bd 70e): итерация по каждой 1С-базе для покрытия multi-DB инстансов
$script:PerDbSqlScriptRelativePath = '..\..\sql\Collect-MSSQL-1C-PerDB.sql'

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
          - Используется call operator `& $exe @args` с splat — на PS 5.1
            Start-Process -ArgumentList с argument'ом, содержащим пробелы или
            точки с запятой (например, "SET NOCOUNT ON; SELECT @@VERSION;"),
            ломается на quoting и sqlcmd видит args как разорванные → отдаёт
            usage (mojibake). Splat через `@allArgs` гарантированно цитирует
            каждый элемент как отдельный arg.
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

    # Готовим временный файл для stdout (UTF-16). stderr читаем через 2>&1 fan-in.
    $tmpOut = [System.IO.Path]::GetTempFileName()

    # Собираем итоговый список аргументов как НАСТОЯЩИЙ массив (не Generic.List —
    # на PS 5.1 List<string> в качестве splat-аргумента может повести себя
    # неожиданно при цитировании; обычный array надёжнее).
    $allArgs = @()
    foreach ($a in $BaseArgs) { $allArgs += $a }

    # -u UTF-16 LE output, -o tempfile, -b ERRORLEVEL on script errors,
    # -r 1: дублировать все error messages в stderr (по умолчанию sqlcmd шлёт
    #        SQL ошибки в stdout, который у нас в tempfile — пользователь не
    #        видит ошибку. См. bd 8up.)
    # -l 10 login timeout, -y 0 -Y 0 без обрезки колонок
    $allArgs += '-u'
    $allArgs += '-b'
    $allArgs += '-r'; $allArgs += '1'
    $allArgs += '-l'; $allArgs += '10'
    $allArgs += '-y'; $allArgs += '0'
    $allArgs += '-Y'; $allArgs += '0'
    $allArgs += '-o'; $allArgs += $tmpOut

    if (-not [string]::IsNullOrEmpty($InputFile)) {
        $allArgs += '-i'; $allArgs += $InputFile
    }
    elseif (-not [string]::IsNullOrEmpty($Query)) {
        $allArgs += '-Q'; $allArgs += $Query
    }

    Write-Verbose "Invoke-SqlcmdRaw exec: $SqlcmdPath $($allArgs -join ' ')"

    $exitCode = -1
    $errorText = ''
    $lines = @()

    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        # Call operator с splat — каждый элемент массива идёт как отдельный
        # quoted arg. Stderr направляем через 2>&1 в общий поток и
        # извлекаем строки с маркером "ERROR:" / non-empty трасировка.
        # Stdout у sqlcmd подавлен ключом -o (направлен в $tmpOut), так что
        # поток PS объекта содержит только stderr.
        $stderrLines = & $SqlcmdPath @allArgs 2>&1 | ForEach-Object { "$_" }
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        if ($stderrLines) { $errorText = ($stderrLines -join [Environment]::NewLine) }

        # Читаем stdout (sqlcmd запись в -o tmpfile) как UTF-16 LE
        if (Test-Path -LiteralPath $tmpOut) {
            $raw = Get-Content -LiteralPath $tmpOut -Encoding Unicode -ErrorAction SilentlyContinue
            if ($null -ne $raw) { $lines = @($raw) }
        }
    }
    catch {
        $errorText = $_.Exception.Message
    }
    finally {
        $ErrorActionPreference = $savedEAP
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        ExitCode  = $exitCode
        Lines     = $lines
        ErrorText = $errorText
    }
}

function Get-SqlcmdErrorTail {
    <#
    .SYNOPSIS
        Извлекает диагностический хвост (последние N строк) из stdout sqlcmd
        для случая, когда stderr пуст.
    .DESCRIPTION
        sqlcmd по умолчанию пишет SQL-ошибки (Msg XYZ, Level N, State M, ...)
        в stdout. У нас stdout перенаправлен в UTF-16 tempfile (-o), поэтому
        $ErrorText (stderr) часто пуст. Эта функция возвращает последние 10
        непустых строк из Lines — там и лежит реальный текст ошибки.
        См. bd 8up.
    .OUTPUTS
        [string]
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,

        [Parameter()]
        [int]$TailCount = 10
    )

    if ($null -eq $Lines -or $Lines.Count -eq 0) { return '' }

    $tail = @($Lines |
        Where-Object { $_ -is [string] -and $_.Trim() -ne '' } |
        Select-Object -Last $TailCount)

    if ($tail.Count -eq 0) { return '' }
    return ($tail -join [Environment]::NewLine)
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
    # '-W' и '-h' убраны: конфликтуют с '-y/-Y' (Invoke-SqlcmdRaw).
    # Хедер строки (если появятся) будут отфильтрованы парсером (regex '^\d+$' на N).

    $result = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $baseArgs.ToArray() -Query 'SET NOCOUNT ON; SELECT @@VERSION;'

    # bd 8up: если stderr пуст — добавим tail из stdout, там реальная ошибка.
    $err = $result.ErrorText
    if ([string]::IsNullOrEmpty($err) -and $result.ExitCode -ne 0) {
        $err = Get-SqlcmdErrorTail -Lines $result.Lines
    }

    return [PSCustomObject]@{
        Success  = ($result.ExitCode -eq 0)
        ExitCode = $result.ExitCode
        Output   = (($result.Lines | Where-Object { $_ -is [string] -and $_.Trim() -ne '' }) -join [Environment]::NewLine)
        Error    = $err
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
    # bd 9nu: используем маркер 'DB:' в начале каждой строки данных. Без '-h -1'
    # (убран как конфликт с -y/-Y) sqlcmd выводит column header + dashes;
    # маркер позволяет надёжно отфильтровать только data-строки независимо от
    # padding, "(N rows affected)" и локализации.
    $listQuery = "SET NOCOUNT ON; SELECT 'DB:' + name AS row FROM sys.databases " +
                 "WHERE database_id > 4 " +
                 "AND name NOT IN ('distribution','SSISDB','ReportServer','ReportServerTempDB') " +
                 "AND state_desc = 'ONLINE' " +
                 "ORDER BY name;"

    $listBaseArgs = New-Object System.Collections.Generic.List[string]
    [void]$listBaseArgs.Add('-S'); [void]$listBaseArgs.Add($serverStr)
    foreach ($a in $authArgs) { [void]$listBaseArgs.Add($a) }
    [void]$listBaseArgs.Add('-d'); [void]$listBaseArgs.Add('master')
    # '-W' и '-h' убраны: конфликтуют с '-y/-Y'.

    $listResult = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $listBaseArgs.ToArray() -Query $listQuery

    if ($listResult.ExitCode -ne 0) {
        # bd 8up: при пустом stderr показываем tail из stdout — реальная SQL ошибка.
        $errMsg = $listResult.ErrorText
        if ([string]::IsNullOrEmpty($errMsg)) { $errMsg = Get-SqlcmdErrorTail -Lines $listResult.Lines }
        Write-Warning "sqlcmd: не удалось получить список баз (exit $($listResult.ExitCode)). $errMsg"
        return @()
    }

    # Фильтруем только строки с маркером DB:; .Trim() обязателен — без -W поля
    # имеют trailing whitespace до ширины колонки.
    $databases = @($listResult.Lines |
        Where-Object { $_ -is [string] -and $_.Trim() -match '^DB:' } |
        ForEach-Object { ($_.Trim() -replace '^DB:', '').Trim() } |
        Where-Object { $_ -ne '' })

    if ($databases.Count -eq 0) {
        return @()
    }

    # --- Эвристика: ≥3 из {Config, Params, _users, _yearoffset} ---
    # bd 9nu: маркер 'CNT:' аналогично DB: — фильтрует header/dashes/footer.
    $probeQuery = "SET NOCOUNT ON; " +
                  "SELECT 'CNT:' + CAST(COUNT(*) AS VARCHAR(10)) AS row FROM sys.tables " +
                  "WHERE name IN ('Config','Params','_users','_yearoffset');"

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($dbName in $databases) {
        try {
            $probeBaseArgs = New-Object System.Collections.Generic.List[string]
            [void]$probeBaseArgs.Add('-S'); [void]$probeBaseArgs.Add($serverStr)
            foreach ($a in $authArgs) { [void]$probeBaseArgs.Add($a) }
            [void]$probeBaseArgs.Add('-d'); [void]$probeBaseArgs.Add($dbName)
            # '-W' и '-h' убраны: конфликтуют с '-y/-Y'.

            $probe = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $probeBaseArgs.ToArray() -Query $probeQuery

            if ($probe.ExitCode -ne 0) { continue }

            # Берём первую строку с маркером CNT:
            $countLine = ($probe.Lines |
                Where-Object { $_ -is [string] -and $_.Trim() -match '^CNT:' } |
                Select-Object -First 1)
            if ($null -eq $countLine) { continue }

            $cntStr = ($countLine.Trim() -replace '^CNT:', '').Trim()
            $cnt = 0
            if ([int]::TryParse($cntStr, [ref]$cnt)) {
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
    # '-W' и '-h' убраны: оба конфликтуют с '-y/-Y' (Invoke-SqlcmdRaw).
    # Хедер/dashes/footer строки отсеются ConvertFrom-MssqlPipeOutput
    # (regex '^\d+$' на первое поле N + проверка на наличие '|').
    [void]$baseArgs.Add('-s'); [void]$baseArgs.Add('|')

    Write-Verbose "Подключение: $serverStr (auth=$(if ($UseWindowsAuth) { 'Windows' } else { 'SQL' }))"
    Write-Verbose "Запуск sqlcmd с T-SQL коллектором..."

    $result = Invoke-SqlcmdRaw -SqlcmdPath $SqlcmdPath -BaseArgs $baseArgs.ToArray() -InputFile $SqlScriptPath

    if ($result.ExitCode -ne 0) {
        # bd 8up: при пустом stderr (типичный случай для SQL ошибок типа
        # "Permission denied" / "Invalid object name") берём tail из stdout —
        # там лежит "Msg XYZ, Level N, State M, ...".
        $errBody = $result.ErrorText
        if ([string]::IsNullOrEmpty($errBody)) {
            $errBody = Get-SqlcmdErrorTail -Lines $result.Lines
        }
        if ([string]::IsNullOrEmpty($errBody)) { $errBody = '(stderr и stdout пусты)' }
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

    # --- 4. Per-DB итерация (bd 70e) ----------------------------------------
    # Основной коллектор работает в контексте одной БД (Database, по умолчанию
    # master). Per-DB блоки _apl_<db> и _stale_stats_* в основном скрипте
    # эмитят данные только для текущей подключённой базы (плюс защита
    # DB_ID() > 4 от системных баз). Чтобы покрыть multi-DB инстансы, после
    # основного прогона запускаем Collect-MSSQL-1C-PerDB.sql отдельно для
    # каждой 1С-базы и аппендим результаты.
    $perDbScriptPath = $null
    try {
        $perDbScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $script:PerDbSqlScriptRelativePath
        $perDbScriptPath = [System.IO.Path]::GetFullPath($perDbScriptPath)
    }
    catch {
        $perDbScriptPath = $null
    }

    if ($null -ne $perDbScriptPath -and (Test-Path -LiteralPath $perDbScriptPath -PathType Leaf)) {
        Write-Verbose "Per-DB скрипт: $perDbScriptPath"

        # Получаем список 1С-баз. Find-1CDatabasesOnMssql сам логирует sqlcmd-ошибки.
        $oneCDatabases = @()
        try {
            $oneCDatabases = @(Find-1CDatabasesOnMssql `
                -ServerHost $ServerHost `
                -InstanceName $InstanceName `
                -Port $Port `
                -UseWindowsAuth $UseWindowsAuth `
                -Username $Username `
                -Password $Password `
                -SqlcmdPath $SqlcmdPath)
        }
        catch {
            Write-Warning "Per-DB iteration: Find-1CDatabasesOnMssql упала — $($_.Exception.Message)"
            $oneCDatabases = @()
        }

        Write-Verbose "Per-DB iteration: найдено 1С-баз — $($oneCDatabases.Count)"

        if ($oneCDatabases.Count -gt 0) {
            # Уже собранные ключи (после основного коллектора), чтобы не делать
            # дубликаты, если основной коллектор уже эмитил _apl_<db> для этой
            # же базы (сценарий: -Database указали явно на 1С-базу).
            $existingKeys = New-Object System.Collections.Generic.HashSet[string]
            foreach ($r in $parsed) {
                if ($null -ne $r -and -not [string]::IsNullOrEmpty($r.Key)) {
                    [void]$existingKeys.Add($r.Key)
                }
            }

            $perDbRows = New-Object System.Collections.Generic.List[PSCustomObject]

            foreach ($dbName in $oneCDatabases) {
                if ([string]::IsNullOrEmpty($dbName)) { continue }
                try {
                    $perDbBaseArgs = New-Object System.Collections.Generic.List[string]
                    [void]$perDbBaseArgs.Add('-S'); [void]$perDbBaseArgs.Add($serverStr)
                    foreach ($a in $authArgs) { [void]$perDbBaseArgs.Add($a) }
                    [void]$perDbBaseArgs.Add('-d'); [void]$perDbBaseArgs.Add($dbName)
                    [void]$perDbBaseArgs.Add('-s'); [void]$perDbBaseArgs.Add('|')
                    # '-h' убран: конфликтует с '-y/-Y'; парсер фильтрует хедер/dashes.

                    $perDbResult = Invoke-SqlcmdRaw `
                        -SqlcmdPath $SqlcmdPath `
                        -BaseArgs $perDbBaseArgs.ToArray() `
                        -InputFile $perDbScriptPath

                    if ($perDbResult.ExitCode -ne 0) {
                        # bd 8up: показываем tail из stdout если stderr пуст.
                        $perDbErr = $perDbResult.ErrorText
                        if ([string]::IsNullOrEmpty($perDbErr)) { $perDbErr = Get-SqlcmdErrorTail -Lines $perDbResult.Lines }
                        Write-Warning "Per-DB '$dbName': sqlcmd exit=$($perDbResult.ExitCode). $perDbErr"
                        continue
                    }

                    $perDbParsed = ConvertFrom-MssqlPipeOutput -Lines $perDbResult.Lines

                    foreach ($row in $perDbParsed) {
                        if ($null -eq $row) { continue }
                        if ([string]::IsNullOrEmpty($row.Key)) { continue }
                        # Дедубликация по Key — _apl_<db>/_stale_stats_<db>_*
                        # уникальны по имени базы, поэтому коллизия означает
                        # что основной коллектор уже эмитил эту строку.
                        if ($existingKeys.Contains($row.Key)) { continue }
                        [void]$existingKeys.Add($row.Key)
                        [void]$perDbRows.Add($row)
                    }
                }
                catch {
                    Write-Warning "Per-DB '$dbName' пропущена: $($_.Exception.Message)"
                    continue
                }
            }

            if ($perDbRows.Count -gt 0) {
                Write-Verbose "Per-DB iteration: добавлено $($perDbRows.Count) строк по $($oneCDatabases.Count) базам."
                $parsed = @($parsed) + $perDbRows.ToArray()
            }
        }
    }
    else {
        Write-Verbose "Per-DB скрипт не найден: $perDbScriptPath — итерация пропущена."
    }

    return $parsed
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function 'Test-MssqlConnection', 'Invoke-MssqlSqlDiagnostic', 'Find-1CDatabasesOnMssql'
