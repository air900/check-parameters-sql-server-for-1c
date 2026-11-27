#Requires -Version 5.1
# ============================================================================
# Модуль: Invoke-MssqlDiagnostic.psm1
# ============================================================================
#
# Назначение:
#   Запускает диагностический T-SQL-скрипт для MS SQL Server через sqlcmd или SqlClient
#   и возвращает результаты в виде массива структурированных объектов
#   (совместимых с Show-DiagnosticResults / Export-DiagnosticReport).
#
# Совместимость: Windows PowerShell 5.1, sqlcmd 13.1+ при наличии
#
# Экспортируемые функции:
#   Test-MssqlConnection         — проверка подключения (Windows / SQL Auth)
#   Invoke-MssqlSqlDiagnostic    — запуск T-SQL коллектора, парсинг строк
#   Find-1CDatabasesOnMssql      — поиск баз 1С
#
# ============================================================================

# Путь к T-SQL-скрипту относительно папки модуля
$script:SqlScriptRelativePath = '../../sql/Collect-MSSQL-1C-Data.sql'

# Сбор данных по отдельным базам
$script:PerDbSqlScriptRelativePath = '../../sql/Collect-MSSQL-1C-PerDB.sql'

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
    $cmd = Get-Command -Name 'sqlcmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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

    # sqlcmd пишет данные в UTF-16 LE, ошибки направляет в stderr.
    $allArgs += '-u'
    $allArgs += '-b'
    $allArgs += '-r'; $allArgs += '1'
    $allArgs += '-l'; $allArgs += '10'
    $allArgs += '-y'; $allArgs += '0'
    $allArgs += '-Y'; $allArgs += '0'
    $allArgs += '-o'; $allArgs += $tmpOut

    # UTF-16 LE с BOM сохраняет кириллицу независимо от кодовой страницы Windows.
    $tmpIn = $null
    if (-not [string]::IsNullOrEmpty($InputFile)) {
        $tmpIn = [System.IO.Path]::GetTempFileName()
        $sqlBytes = [System.IO.File]::ReadAllBytes($InputFile)
        # Снимаем UTF-8 BOM (0xEF 0xBB 0xBF) если есть, остальное декодируем
        # как UTF-8 (наши .sql всегда сохраняем UTF-8 BOM).
        $offset = 0
        if ($sqlBytes.Length -ge 3 -and $sqlBytes[0] -eq 0xEF -and $sqlBytes[1] -eq 0xBB -and $sqlBytes[2] -eq 0xBF) {
            $offset = 3
        }
        $sqlText = [System.Text.Encoding]::UTF8.GetString($sqlBytes, $offset, $sqlBytes.Length - $offset)
        # Запись с UTF-16 LE BOM (Encoding.Unicode по умолчанию пишет с BOM).
        [System.IO.File]::WriteAllText($tmpIn, $sqlText, [System.Text.Encoding]::Unicode)
        $allArgs += '-i'; $allArgs += $tmpIn
    }
    elseif (-not [string]::IsNullOrEmpty($Query)) {
        $allArgs += '-Q'; $allArgs += $Query
    }

    Write-Verbose "Запуск sqlcmd: $SqlcmdPath"

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
        if ($tmpIn) { Remove-Item -LiteralPath $tmpIn -ErrorAction SilentlyContinue }
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
    .OUTPUTS
        [string]
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
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

function Invoke-MssqlSqlClient {
    param(
        [hashtable]$Connection,
        [string]$Database,
        [string]$Query,
        [string]$InputFile
    )

    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Data
    $settings = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $settings['Data Source'] = $Connection.Server
    $settings['Initial Catalog'] = $Database
    $settings['Connect Timeout'] = 10
    $settings['Integrated Security'] = $Connection.UseWindowsAuth
    if (-not $Connection.UseWindowsAuth) {
        $settings['User ID'] = $Connection.Username
        $settings['Password'] = $Connection.Password
    }

    $batches = @($Query)
    if ($InputFile) {
        $sql = [System.IO.File]::ReadAllText($InputFile, [System.Text.Encoding]::UTF8)
        $batches = $sql -split '(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?\r?$'
    }

    $conn = New-Object System.Data.SqlClient.SqlConnection($settings.psbase.ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        try {
            $cmd.CommandTimeout = 0
            # GO разделяет пакеты. Временные таблицы живут до закрытия соединения.
            foreach ($batch in $batches) {
                if ([string]::IsNullOrWhiteSpace($batch)) { continue }
                $cmd.CommandText = $batch
                $reader = $cmd.ExecuteReader()
                try {
                    do {
                        if ($InputFile -and $reader.FieldCount -eq 6) {
                            while ($reader.Read()) {
                                $fields = for ($i = 0; $i -lt 6; $i++) {
                                    if ($reader.IsDBNull($i)) { 'NULL' }
                                    else { [Convert]::ToString($reader.GetValue($i), [Globalization.CultureInfo]::InvariantCulture) }
                                }
                                ConvertFrom-MssqlResultFields -Fields $fields
                            }
                        }
                        elseif (-not $InputFile -and $reader.FieldCount -eq 1) {
                            while ($reader.Read()) { $reader.GetString(0) }
                        }
                    } while ($reader.NextResult())
                }
                finally { $reader.Dispose() }
            }
        }
        finally { $cmd.Dispose() }
    }
    finally { $conn.Dispose() }
}

function Invoke-MssqlCommand {
    param(
        [hashtable]$Connection,
        [string]$Database = 'master',
        [string]$Query,
        [string]$InputFile
    )

    $rows = @()
    $err = ''
    $exitCode = -1
    try {
        if (-not $Connection.UseWindowsAuth -and [string]::IsNullOrEmpty($Connection.Username)) {
            throw 'Для SQL-аутентификации требуется параметр -Username.'
        }

        if ($Connection.SqlcmdPath) {
            if (-not (Test-Path -LiteralPath $Connection.SqlcmdPath -PathType Leaf)) {
                throw "Указанный путь к sqlcmd не существует: $($Connection.SqlcmdPath)"
            }
            $authArgs = Get-SqlcmdAuthArgs -UseWindowsAuth $Connection.UseWindowsAuth -Username $Connection.Username -Password $Connection.Password
            $baseArgs = @('-S', $Connection.Server) + $authArgs + @('-d', $Database)
            if ($InputFile) { $baseArgs += @('-s', '|') }
            $raw = Invoke-SqlcmdRaw -SqlcmdPath $Connection.SqlcmdPath -BaseArgs $baseArgs -Query $Query -InputFile $InputFile

            $exitCode = $raw.ExitCode
            $err = $raw.ErrorText
            if ($exitCode -ne 0 -and -not $err) {
                $err = Get-SqlcmdErrorTail -Lines $raw.Lines
            }
            if ($exitCode -eq 0) {
                $rows = @(
                    if ($InputFile) { ConvertFrom-MssqlPipeOutput -Lines $raw.Lines }
                    else { $raw.Lines }
                )
            }
        }
        else {
            Write-Verbose "Подключение через SqlClient: $($Connection.Server), БД '$Database'"
            $rows = @(Invoke-MssqlSqlClient -Connection $Connection -Database $Database -Query $Query -InputFile $InputFile)
            $exitCode = 0
        }
    }
    catch {
        $exitCode = -1
        $err = $_.Exception.GetBaseException().Message
    }

    if ($err -and -not $Connection.UseWindowsAuth -and $Connection.Password) {
        $err = $err.Replace($Connection.Password, '***')
    }

    return [PSCustomObject]@{
        ExitCode  = $exitCode
        Rows      = @($rows)
        ErrorText = $err
    }
}

# ---------------------------------------------------------------------------
# Публичные функции
# ---------------------------------------------------------------------------

function Test-MssqlConnection {
    <#
    .SYNOPSIS
        Проверяет подключение к экземпляру MS SQL Server.
    .DESCRIPTION
        Выполняет простой запрос SELECT @@VERSION.
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
        Полный путь к sqlcmd.exe. Автопоиск при отсутствии пути, SqlClient при отсутствии sqlcmd.
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

    if (-not $SqlcmdPath) { $SqlcmdPath = Find-SqlcmdExecutable }
    $connection = @{
        Server         = Get-MssqlServerString -ServerHost $ServerHost -InstanceName $InstanceName -Port $Port
        SqlcmdPath     = $SqlcmdPath
        UseWindowsAuth = $UseWindowsAuth
        Username       = $Username
        Password       = $Password
    }

    $result = Invoke-MssqlCommand -Connection $connection -Query 'SET NOCOUNT ON; SELECT @@VERSION;'

    return [PSCustomObject]@{
        Success  = ($result.ExitCode -eq 0)
        ExitCode = $result.ExitCode
        Output   = (($result.Rows | Where-Object { $_ -is [string] -and $_.Trim() -ne '' }) -join [Environment]::NewLine)
        Error    = $result.ErrorText
    }
}

function Find-1CDatabasesOnMssql {
    <#
    .SYNOPSIS
        Находит базы 1С на экземпляре MS SQL Server.
    .DESCRIPTION
        Ищет характерные таблицы 1С в доступных пользовательских базах.
        При ошибке доступа к отдельной базе продолжает поиск.

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

    if (-not $SqlcmdPath) { $SqlcmdPath = Find-SqlcmdExecutable }
    $connection = @{
        Server         = Get-MssqlServerString -ServerHost $ServerHost -InstanceName $InstanceName -Port $Port
        SqlcmdPath     = $SqlcmdPath
        UseWindowsAuth = $UseWindowsAuth
        Username       = $Username
        Password       = $Password
    }

    # --- Список пользовательских ONLINE-баз ---
    # Маркер 'DB:' отличает данные от служебных строк sqlcmd.
    $listQuery = "SET NOCOUNT ON; SELECT 'DB:' + name AS row FROM sys.databases " +
                 "WHERE database_id > 4 " +
                 "AND name NOT IN ('distribution','SSISDB','ReportServer','ReportServerTempDB') " +
                 "AND state_desc = 'ONLINE' " +
                 "ORDER BY name;"

    $listResult = Invoke-MssqlCommand -Connection $connection -Query $listQuery
    if ($listResult.ExitCode -ne 0) {
        Write-Warning "Не удалось получить список баз (код $($listResult.ExitCode)). $($listResult.ErrorText)"
        return @()
    }

    # sqlcmd дополняет строки пробелами до ширины колонки.
    $databases = @($listResult.Rows |
        Where-Object { $_ -is [string] -and $_ -like 'DB:*' } |
        ForEach-Object {
            $dbName = $_.Substring(3)
            if ($SqlcmdPath) { $dbName.TrimEnd() } else { $dbName }
        })

    if ($databases.Count -eq 0) {
        return @()
    }

    # Маркер 'CNT:' отличает данные от служебных строк sqlcmd.
    $probeQuery = "SET NOCOUNT ON; " +
                  "SELECT 'CNT:' + CAST(COUNT(*) AS VARCHAR(10)) AS row FROM sys.tables " +
                  "WHERE name IN ('Config','Params','_users','_yearoffset');"

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($dbName in $databases) {
        $probe = Invoke-MssqlCommand -Connection $connection -Database $dbName -Query $probeQuery

        if ($probe.ExitCode -ne 0) {
            Write-Verbose "Пропущена база '$dbName': $($probe.ErrorText)"
            continue
        }

        $countLine = $probe.Rows | Where-Object { $_ -is [string] -and $_ -like 'CNT:*' } | Select-Object -First 1
        $count = 0
        if ($countLine -and [int]::TryParse($countLine.Substring(4), [ref]$count) -and $count -ge 3) {
            [void]$found.Add($dbName)
        }
    }

    return $found.ToArray()
}

function ConvertFrom-MssqlResultFields {
    param([string[]]$Fields)

    if ($Fields.Count -ne 6 -or $Fields[0].Trim() -notmatch '^\d+$') { return }

    return [PSCustomObject]@{
        N            = $Fields[0].Trim()
        Section      = $Fields[1].Trim()
        Key          = $Fields[2].Trim()
        Problem      = $Fields[3].Trim()
        CurrentValue = $Fields[4].Trim()
        Value        = $Fields[5].Trim()
        Status       = ''
        Detected     = ''
        Impact       = ''
    }
}

function ConvertFrom-MssqlPipeOutput {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -notlike '*|*') { continue }
        # Value может содержать '|' внутри JSON.
        ConvertFrom-MssqlResultFields -Fields ($line -split '\|', 6)
    }
}

function Invoke-MssqlSqlDiagnostic {
    <#
    .SYNOPSIS
        Запускает T-SQL коллектор Collect-MSSQL-1C-Data.sql и возвращает результаты.
    .DESCRIPTION
        Использует sqlcmd при наличии или встроенный в Windows PowerShell SqlClient.
        Оба варианта сохраняют кириллицу в результатах коллектора.

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

    if (-not $SqlcmdPath) { $SqlcmdPath = Find-SqlcmdExecutable }
    $connection = @{
        Server         = Get-MssqlServerString -ServerHost $ServerHost -InstanceName $InstanceName -Port $Port
        SqlcmdPath     = $SqlcmdPath
        UseWindowsAuth = $UseWindowsAuth
        Username       = $Username
        Password       = $Password
    }

    if ([string]::IsNullOrEmpty($SqlScriptPath)) {
        $moduleDir = $PSScriptRoot
        $SqlScriptPath = Join-Path -Path $moduleDir -ChildPath $script:SqlScriptRelativePath
        $SqlScriptPath = [System.IO.Path]::GetFullPath($SqlScriptPath)
    }
    if (-not (Test-Path -LiteralPath $SqlScriptPath -PathType Leaf)) {
        throw "Файл сбора данных SQL Server не найден: $SqlScriptPath"
    }
    Write-Verbose "T-SQL скрипт: $SqlScriptPath"

    $SqlScriptPath = (Get-Item -LiteralPath $SqlScriptPath).FullName
    $result = Invoke-MssqlCommand -Connection $connection -Database $Database -InputFile $SqlScriptPath
    if ($result.ExitCode -ne 0) {
        throw "SQL Server не вернул данные (код $($result.ExitCode)). $($result.ErrorText)"
    }

    $parsed = $result.Rows
    if ($parsed.Count -eq 0) {
        throw "В ответе SQL Server нет записей в ожидаемом формате."
    }
    Write-Verbose "Получено записей: $($parsed.Count)"

    $sqlMajor = 0
    $majorRow = $parsed | Where-Object Key -eq '_info_sql_major' | Select-Object -First 1
    if ($majorRow) { [void][int]::TryParse($majorRow.Value, [ref]$sqlMajor) }

    # Per-DB коллектор дополняет основной сбор данными выбранной базы или найденных 1С-баз.
    $systemDbs = @('master', 'tempdb', 'model', 'msdb')
    $dbScopeCount = [int]($systemDbs -notcontains $Database)
    $emptyAplDbCount = 0
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

        $oneCDatabases = @()

        if ($systemDbs -notcontains $Database.ToLower()) {
            # Указана конкретная пользовательская БД — итерируем только её.
            $oneCDatabases = @($Database)
            Write-Verbose "Per-DB iteration: scope=selected → только '$Database' (как PostgreSQL-подход)"
        }
        else {
            # При запуске из системной базы сначала ищем базы 1С.
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
                Write-Warning "Не удалось найти базы 1С для сбора данных. $($_.Exception.Message)"
                $oneCDatabases = @()
            }
            Write-Verbose "Per-DB iteration: scope=discovery (master mode) → найдено 1С-баз: $($oneCDatabases.Count)"
        }

        $dbScopeCount = $oneCDatabases.Count
        if ($dbScopeCount -gt 0) {
            $scopeLabel = if ($oneCDatabases.Count -eq 1) {
                "Сбор статистики и сведений о фрагментации индексов базы '$($oneCDatabases[0])'..."
            } else {
                "Сбор статистики и сведений о фрагментации индексов по базам 1С ($($oneCDatabases.Count))."
            }
            Write-Host ''
            Write-Host "  $scopeLabel" -ForegroundColor Yellow
            Write-Host '  Сбор данных по крупной базе может занять несколько минут.' -ForegroundColor Yellow
            Write-Host '  Дождитесь завершения сбора.' -ForegroundColor Yellow
            Write-Host ''

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
            $dbIdx = 0

            foreach ($dbName in $oneCDatabases) {
                if ([string]::IsNullOrEmpty($dbName)) { continue }
                $dbIdx++
                $dbStart = Get-Date
                Write-Host ('  [{0}/{1}] {2} — сбор данных...' -f $dbIdx, $oneCDatabases.Count, $dbName) -ForegroundColor Gray -NoNewline
                try {
                    $perDbResult = Invoke-MssqlCommand -Connection $connection -Database $dbName -InputFile $perDbScriptPath
                    if ($perDbResult.ExitCode -ne 0) {
                        Write-Host ''
                        Write-Warning "Не удалось собрать данные базы '$dbName' (код $($perDbResult.ExitCode)). $($perDbResult.ErrorText)"
                        continue
                    }

                    foreach ($row in $perDbResult.Rows) {
                        if ($null -eq $row) { continue }
                        if ([string]::IsNullOrEmpty($row.Key)) { continue }
                        # Дедубликация по Key — _apl_<db>/_stale_stats_<db>_*
                        # уникальны по имени базы, поэтому коллизия означает
                        # что основной коллектор уже эмитил эту строку.
                        if ($existingKeys.Contains($row.Key)) { continue }
                        [void]$existingKeys.Add($row.Key)
                        [void]$perDbRows.Add($row)
                    }
                    # Запрос APL не возвращает строки, если в базе нет индексов.
                    if (-not $existingKeys.Contains(('_apl_' + $dbName).TrimEnd())) { $emptyAplDbCount++ }
                    # Завершить inline-прогресс «X — анализ...» с длительностью
                    $dbSecs = [int][math]::Round((New-TimeSpan -Start $dbStart -End (Get-Date)).TotalSeconds)
                    Write-Host (' завершён за {0} сек.' -f $dbSecs) -ForegroundColor Green
                }
                catch {
                    Write-Host '' # break the inline progress line before warning
                    Write-Warning "Сбор данных базы '$dbName' прерван. $($_.Exception.Message)"
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

    # Рассчитываем сводные показатели по измерениям из отдельных баз.
    $maxMetrics = @(
        @{ N = 750; Section = 'statistics'; Key = 'worst_stats_high_change_count'; Source = '_stats_summary_'; Field = 'high_change'
           Label = 'Макс. количество статистик с >20% изменений (по всем БД)' }
        @{ N = 751; Section = 'statistics'; Key = 'worst_stats_max_age_days'; Source = '_stats_summary_'; Field = 'max_age_days'
           Label = 'Макс. возраст статистик (по всем БД), дн' }
        @{ N = 752; Section = 'statistics'; Key = 'worst_stats_older_7d_count'; Source = '_stats_summary_'; Field = 'older_7d'
           Label = 'Макс. количество статистик старше 7 дней (по всем БД)' }
        @{ N = 753; Section = 'statistics'; Key = 'worst_stats_older_30d_count'; Source = '_stats_summary_'; Field = 'older_30d'
           Label = 'Макс. количество статистик старше 30 дней (по всем БД)' }
        @{ N = 754; Section = 'statistics'; Key = 'worst_allow_page_locks_off_pct'; Source = '_apl_'; Field = 'pct'; Format = 'F3'
           Label = 'Макс. % индексов без ALLOW_PAGE_LOCKS=ON (по всем БД)' }
        @{ N = 755; Section = 'maintenance'; Key = 'worst_index_high_frag_count'; Source = '_index_fragmentation_summary_'; Field = 'high_frag_count'
           Label = 'Макс. количество индексов с фрагментацией > 30% (по всем БД)' }
        @{ N = 756; Section = 'maintenance'; Key = 'worst_index_max_frag_pct'; Source = '_index_fragmentation_summary_'; Field = 'max_frag_pct'; Format = 'F1'
           Label = 'Макс. % фрагментации индекса (по всем БД)' }
        @{ N = 757; Section = 'maintenance'; Key = 'worst_large_uncompressed_table_count'; Source = '_large_uncompressed_'; Field = 'count'
           Label = 'Макс. количество несжатых таблиц > 10 ГБ (по всем БД)' }
    )
    foreach ($metric in $maxMetrics) {
        $metric.Maximum = 0.0
        $metric.Observed = if ($metric.Source -eq '_apl_') { $emptyAplDbCount } else { 0 }
    }
    $totalLegacyCeOnCount       = 0
    $totalDscMaxdopOverride     = 0
    $totalDscParamSniffingOff   = 0
    $totalQsOffCount            = 0
    $totalQsReadOnlyCount       = 0
    $totalTrustworthyOnCount    = 0
    $totalAdrDisabledLargeCount = 0
    $observed = @{ LegacyCe = 0; Maxdop = 0; Sniffing = 0; QueryStore = 0; Trustworthy = 0; Adr = 0 }
    foreach ($r in $parsed) {
        if ($null -eq $r -or [string]::IsNullOrEmpty($r.Key)) { continue }
        try {
            if ($r.Key -match '^(_stats_summary_|_apl_|_index_fragmentation_summary_|_large_uncompressed_)') {
                $source = $Matches[1]
                # SUM над пустым набором статистик даёт SQL NULL во всей строке JSON.
                $emptyStats = $source -eq '_stats_summary_' -and
                    ([string]::IsNullOrEmpty($r.Value) -or $r.Value -ceq 'NULL')
                $j = if (-not $emptyStats) { ConvertFrom-Json $r.Value -ErrorAction Stop }
                foreach ($metric in $maxMetrics) {
                    if ($metric.Source -ne $source) { continue }
                    $sample = if ($emptyStats) { 0 } else { $j.PSObject.Properties[$metric.Field].Value }
                    if ($null -eq $sample) { continue }
                    $metric.Maximum = [Math]::Max($metric.Maximum, [double]$sample)
                    $metric.Observed++
                }
            }
            elseif ($r.Key -like '_dsc_*') {
                $j = ConvertFrom-Json $r.Value -ErrorAction Stop
                $value = 0
                if (-not [int]::TryParse([string]$j.value, [ref]$value)) { continue }
                switch ($j.name) {
                    'LEGACY_CARDINALITY_ESTIMATION' {
                        $observed.LegacyCe++
                        if ($value -eq 1) { $totalLegacyCeOnCount++ }
                    }
                    'MAXDOP' {
                        $observed.Maxdop++
                        if ($value -ne 0) { $totalDscMaxdopOverride++ }
                    }
                    'PARAMETER_SNIFFING' {
                        $observed.Sniffing++
                        if ($value -eq 0) { $totalDscParamSniffingOff++ }
                    }
                }
            }
            elseif ($r.Key -like '_query_store_*') {
                $j = ConvertFrom-Json $r.Value -ErrorAction Stop
                $state = 0
                if ([int]::TryParse([string]$j.actual_state, [ref]$state)) {
                    $observed.QueryStore++
                    if ($state -eq 0) { $totalQsOffCount++ }
                    elseif ($state -eq 1) { $totalQsReadOnlyCount++ }
                }
            }
            elseif ($r.Key -like '_trustworthy_*') {
                $j = ConvertFrom-Json $r.Value -ErrorAction Stop
                $trustworthy = 0
                if ([int]::TryParse([string]$j.trustworthy_on, [ref]$trustworthy)) {
                    $observed.Trustworthy++
                    if ($trustworthy -eq 1) { $totalTrustworthyOnCount++ }
                }
            }
            elseif ($r.Key -like '_adr_*') {
                $j = ConvertFrom-Json $r.Value -ErrorAction Stop
                $adrOn = 0
                $sizeGb = 0
                if ([int]::TryParse([string]$j.adr_on, [ref]$adrOn) -and
                    [int]::TryParse([string]$j.size_gb, [ref]$sizeGb)) {
                    $observed.Adr++
                    if ($adrOn -eq 0 -and $sizeGb -ge 100) { $totalAdrDisabledLargeCount++ }
                }
            }
        } catch { }
    }

    # Десятичный разделитель чисел в данных не зависит от локали.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($maxMetrics | Where-Object { $_.Observed -lt $dbScopeCount }) {
        Write-Warning 'По части показателей есть данные только для отдельных баз. Общие значения по этим показателям пропущены.'
    }
    $aggRows = @(
        foreach ($metric in $maxMetrics) {
            if ($metric.Observed -eq 0 -or $metric.Observed -ne $dbScopeCount) { continue }
            $value = $metric.Maximum.ToString($metric.Format, $inv)
            $display = if ($metric.Format) { $metric.Maximum.ToString('F1', $inv) + ' %' } else { $value }
            [PSCustomObject]@{
                N = $metric.N; Section = $metric.Section; Key = $metric.Key
                Label = $metric.Label; Problem = $metric.Label
                Display = $display; CurrentValue = $display; Value = $value
            }
        }
    )

    if ($dbScopeCount -gt 0) {
        $dbCounts = @(
            @{ N = 758; Section = 'instance_config'; Key = 'legacy_cardinality_estimator_db_count';
                Label = 'Баз 1С с устаревшим оценщиком количества строк (LEGACY_CE = ON)';
                Count = $totalLegacyCeOnCount; Observed = $observed.LegacyCe; MinMajor = 13 },
            @{ N = 760; Section = 'instance_config'; Key = 'dsc_maxdop_override_db_count';
                Label = 'Баз 1С с переопределением MAXDOP в БД (override server)';
                Count = $totalDscMaxdopOverride; Observed = $observed.Maxdop; MinMajor = 13 },
            @{ N = 761; Section = 'instance_config'; Key = 'dsc_parameter_sniffing_off_db_count';
                Label = 'Баз 1С с выключенным parameter sniffing';
                Count = $totalDscParamSniffingOff; Observed = $observed.Sniffing; MinMajor = 13 },
            @{ N = 762; Section = 'query_store'; Key = 'query_store_off_db_count';
                Label = 'Баз 1С с выключенным Query Store';
                Count = $totalQsOffCount; Observed = $observed.QueryStore; MinMajor = 13 },
            @{ N = 763; Section = 'query_store'; Key = 'query_store_read_only_db_count';
                Label = 'Баз 1С с переполненным Query Store (READ_ONLY)';
                Count = $totalQsReadOnlyCount; Observed = $observed.QueryStore; MinMajor = 13 },
            @{ N = 764; Section = 'security'; Key = 'trustworthy_on_db_count';
                Label = 'Баз 1С с TRUSTWORTHY = ON (security risk)';
                Count = $totalTrustworthyOnCount; Observed = $observed.Trustworthy; MinMajor = 0 },
            @{ N = 765; Section = 'recovery'; Key = 'adr_disabled_large_db_count';
                Label = 'Крупных 1С-баз (>=100 ГБ) без ускоренного восстановления';
                Count = $totalAdrDisabledLargeCount; Observed = $observed.Adr; MinMajor = 15 }
        )

        foreach ($metric in $dbCounts) {
            if ($sqlMajor -gt 0 -and $sqlMajor -lt $metric.MinMajor) { continue }
            $incomplete = $metric.Observed -ne $dbScopeCount
            if ($incomplete -and $metric.Count -eq 0) { continue }

            $display = [string]$metric.Count
            if ($incomplete) { $display = "Не менее $display" }
            $aggRows += [PSCustomObject]@{
                N = $metric.N
                Section = $metric.Section
                Key = $metric.Key
                Label = $metric.Label
                Problem = $metric.Label
                Display = $display
                CurrentValue = $display
                Value = [string]$metric.Count
            }
        }
    }
    $parsed = @($parsed) + $aggRows
    Write-Verbose "Сводные показатели по выборке из $dbScopeCount баз: $($aggRows.Count)"

    return $parsed
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function 'Test-MssqlConnection', 'Invoke-MssqlSqlDiagnostic', 'Find-1CDatabasesOnMssql'
