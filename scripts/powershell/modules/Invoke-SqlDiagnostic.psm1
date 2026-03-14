# ============================================================================
# Модуль: Invoke-SqlDiagnostic.psm1
# ============================================================================
#
# Назначение:
#   Запускает диагностический SQL-скрипт для PostgreSQL через psql
#   и возвращает результаты в виде массива структурированных объектов.
#
# Совместимость: PowerShell 5.1+
#
# Использование:
#   Import-Module .\Invoke-SqlDiagnostic.psm1
#   $results = Invoke-SqlDiagnostic -Database 'mydb' -Password 'secret'
#
# ============================================================================

# Путь к SQL-скрипту относительно папки модуля
$script:SqlScriptRelativePath = '..\..\sql\Collect-PostgreSQL-1C-Data.sql'

# Стандартные пути установки psql на Windows
$script:PsqlCommonPaths = @(
    'C:\Program Files\PostgreSQL\17\bin\psql.exe',
    'C:\Program Files\PostgreSQL\16\bin\psql.exe',
    'C:\Program Files\PostgreSQL\15\bin\psql.exe',
    'C:\Program Files\PostgreSQL\14\bin\psql.exe',
    'C:\Program Files\PostgreSQL\13\bin\psql.exe',
    'C:\Program Files\PostgreSQL\12\bin\psql.exe',
    'C:\Program Files\PostgreSQL\11\bin\psql.exe',
    'C:\Program Files\PostgreSQL\10\bin\psql.exe',
    'C:\Program Files (x86)\PostgreSQL\17\bin\psql.exe',
    'C:\Program Files (x86)\PostgreSQL\16\bin\psql.exe',
    'C:\Program Files (x86)\PostgreSQL\15\bin\psql.exe'
)

function Find-PsqlExecutable {
    <#
    .SYNOPSIS
        Ищет исполняемый файл psql в PATH и стандартных путях установки.
    .OUTPUTS
        [string] Полный путь к psql.exe или $null если не найден.
    #>
    [OutputType([string])]
    param()

    # Сначала ищем в PATH
    $psqlInPath = Get-Command -Name 'psql' -ErrorAction SilentlyContinue
    if ($null -ne $psqlInPath) {
        return $psqlInPath.Source
    }

    # Проверяем стандартные пути установки
    foreach ($path in $script:PsqlCommonPaths) {
        if (Test-Path -Path $path -PathType Leaf) {
            return $path
        }
    }

    return $null
}

function Find-1CDatabases {
    <#
    .SYNOPSIS
        Возвращает список пользовательских баз данных на сервере PostgreSQL.
    .DESCRIPTION
        Один запрос к pg_database — возвращает имена и размеры всех
        пользовательских баз (кроме postgres и шаблонов).
        Не подключается к каждой базе отдельно — работает мгновенно.
    .PARAMETER PsqlPath
        Путь к psql.exe.
    .PARAMETER PgHost
        Имя или IP-адрес сервера PostgreSQL.
    .PARAMETER Port
        Порт PostgreSQL.
    .PARAMETER Username
        Имя пользователя для подключения.
    .OUTPUTS
        [PSCustomObject[]] Массив объектов с полями Name и Size.
    #>
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PsqlPath,

        [Parameter(Mandatory = $true)]
        [string]$PgHost,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Username
    )

    # Один запрос — список баз с размерами, без подключения к каждой
    $listDbQuery = "SELECT datname || '|' || pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY pg_database_size(datname) DESC;"
    $psqlArgs = @(
        '--host', $PgHost,
        '--port', $Port,
        '--username', $Username,
        '--tuples-only',
        '--no-align',
        '--command', $listDbQuery,
        'postgres'
    )

    try {
        $dbListOutput = & $PsqlPath @psqlArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Warning "Ошибка при получении списка баз данных: $_"
        return @()
    }

    if ($exitCode -ne 0) {
        Write-Warning "psql завершился с кодом $exitCode при получении списка БД."
        return @()
    }

    $results = @()
    $dbListOutput |
        Where-Object { $_ -is [string] -and $_.Trim() -ne '' } |
        ForEach-Object {
            $parts = $_.Trim() -split '\|', 2
            if ($parts.Count -ge 2) {
                $results += [PSCustomObject]@{
                    Name = $parts[0].Trim()
                    Size = $parts[1].Trim()
                }
            }
        }

    return $results
}

function Get-1CDatabase {
    <#
    .SYNOPSIS
        Автоматически определяет базу данных 1С:Предприятие на сервере PostgreSQL.
    .DESCRIPTION
        Запрашивает список баз данных, затем проверяет наличие таблицы _reference1,
        которая является признаком базы 1С.
        Если баз 1С несколько — возвращает первую найденную.
        Для получения всех баз 1С используйте Find-1CDatabases.
    .PARAMETER PsqlPath
        Путь к psql.exe.
    .PARAMETER Host
        Имя или IP-адрес сервера PostgreSQL.
    .PARAMETER Port
        Порт PostgreSQL.
    .PARAMETER Username
        Имя пользователя для подключения.
    .OUTPUTS
        [string] Имя базы данных 1С или $null если не найдена.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PsqlPath,

        [Parameter(Mandatory = $true)]
        [string]$Host,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Username
    )

    # Получаем список всех пользовательских баз данных
    $listDbQuery = "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;"
    $psqlArgs = @(
        '--host', $Host,
        '--port', $Port,
        '--username', $Username,
        '--tuples-only',
        '--no-align',
        '--command', $listDbQuery,
        'postgres'
    )

    try {
        $dbListOutput = & $PsqlPath @psqlArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Warning "Ошибка при получении списка баз данных: $_"
        return $null
    }

    if ($exitCode -ne 0) {
        Write-Warning "psql завершился с кодом $exitCode при получении списка БД."
        return $null
    }

    # Парсим список баз данных (убираем пустые строки)
    $databases = $dbListOutput |
        Where-Object { $_ -is [string] -and $_.Trim() -ne '' } |
        ForEach-Object { $_.Trim() }

    if ($databases.Count -eq 0) {
        Write-Warning "Не найдено пользовательских баз данных."
        return $null
    }

    # Проверяем каждую базу на наличие таблицы _reference1 (признак 1С)
    $checkTableQuery = "SELECT 1 FROM information_schema.tables WHERE table_name = '_reference1' LIMIT 1;"
    foreach ($dbName in $databases) {
        $psqlCheckArgs = @(
            '--host', $Host,
            '--port', $Port,
            '--username', $Username,
            '--tuples-only',
            '--no-align',
            '--command', $checkTableQuery,
            $dbName
        )

        try {
            $checkOutput = & $PsqlPath @psqlCheckArgs 2>&1
            $checkExitCode = $LASTEXITCODE
        }
        catch {
            continue
        }

        if ($checkExitCode -eq 0 -and ($checkOutput -join '').Trim() -eq '1') {
            Write-Verbose "Обнаружена база данных 1С: $dbName"
            return $dbName
        }
    }

    # Если таблица _reference1 не найдена ни в одной БД — возвращаем первую доступную
    Write-Warning "База данных 1С (с таблицей _reference1) не обнаружена. Используется первая доступная: $($databases[0])"
    return $databases[0]
}

function ConvertFrom-PsqlOutput {
    <#
    .SYNOPSIS
        Парсит вывод psql в формате --csv в массив объектов PSCustomObject.
    .DESCRIPTION
        SQL-скрипт Collect-PostgreSQL-1C-Data.sql возвращает 4 колонки:
        N, Раздел, Параметр, Значение
        Функция преобразует каждую строку в объект с английскими именами свойств.
        Для совместимости с модулями Show-DiagnosticResults и Export-DiagnosticReport
        результат содержит поля Section, Problem (= Параметр), CurrentValue (= Значение).
        Поля Status, Detected, Impact оставлены пустыми (интерпретация выполняется на бэкенде).
    .PARAMETER Lines
        Массив строк вывода psql.
    .OUTPUTS
        [PSCustomObject[]] Массив разобранных строк.
    #>
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Пропускаем пустые строки и строки с заголовком (первая строка CSV)
    $dataLines = $Lines | Where-Object { $_.Trim() -ne '' }

    if ($dataLines.Count -eq 0) {
        return $results.ToArray()
    }

    # Первая строка — заголовок CSV, пропускаем
    $dataLines = $dataLines | Select-Object -Skip 1

    foreach ($line in $dataLines) {
        # Парсим CSV-строку с учётом кавычек
        $fields = ConvertFrom-CsvLine -Line $line

        if ($fields.Count -lt 4) {
            Write-Verbose "Пропущена строка с недостаточным количеством полей: $line"
            continue
        }

        $obj = [PSCustomObject]@{
            N            = $fields[0]
            Section      = $fields[1]       # Раздел
            Problem      = $fields[2]       # Параметр (название)
            Status       = ''               # Нет оценки в скрипте сбора данных
            CurrentValue = $fields[3]       # Значение
            Detected     = ''               # Интерпретация — на бэкенде
            Impact       = ''               # Влияние — на бэкенде
        }

        $results.Add($obj)
    }

    return $results.ToArray()
}

function ConvertFrom-CsvLine {
    <#
    .SYNOPSIS
        Разбирает одну строку CSV с учётом экранирования кавычками.
    .PARAMETER Line
        Строка в формате CSV.
    .OUTPUTS
        [string[]] Массив полей.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $fields = [System.Collections.Generic.List[string]]::new()
    $currentField = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    $i = 0

    while ($i -lt $Line.Length) {
        $char = $Line[$i]

        if ($inQuotes) {
            if ($char -eq '"') {
                # Проверяем следующий символ — если тоже кавычка, это экранированная кавычка
                if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') {
                    [void]$currentField.Append('"')
                    $i += 2
                    continue
                }
                else {
                    # Закрывающая кавычка
                    $inQuotes = $false
                }
            }
            else {
                [void]$currentField.Append($char)
            }
        }
        else {
            if ($char -eq '"') {
                $inQuotes = $true
            }
            elseif ($char -eq ',') {
                $fields.Add($currentField.ToString())
                [void]$currentField.Clear()
            }
            else {
                [void]$currentField.Append($char)
            }
        }

        $i++
    }

    # Добавляем последнее поле
    $fields.Add($currentField.ToString())

    return $fields.ToArray()
}

function Invoke-SqlDiagnostic {
    <#
    .SYNOPSIS
        Запускает диагностический SQL-скрипт для PostgreSQL и возвращает результаты.
    .DESCRIPTION
        Выполняет скрипт Check-PostgreSQL-1C-Diagnostic.sql через psql и возвращает
        разобранные результаты в виде массива структурированных объектов.
        Если база данных не указана — автоматически определяет базу 1С.
        Для передачи пароля использует переменную окружения PGPASSWORD (очищается после).
    .PARAMETER Host
        Имя или IP-адрес сервера PostgreSQL. По умолчанию: localhost.
    .PARAMETER Port
        Порт PostgreSQL. По умолчанию: 5432.
    .PARAMETER Database
        Имя базы данных. Если не указано — выполняется автоопределение базы 1С.
    .PARAMETER Username
        Имя пользователя. По умолчанию: postgres.
    .PARAMETER Password
        Пароль пользователя. Если не указан — psql попытается использовать
        .pgpass или другие механизмы аутентификации.
    .PARAMETER PsqlPath
        Полный путь к psql.exe. Если не указан — выполняется автопоиск.
    .OUTPUTS
        [PSCustomObject[]] Массив объектов с полями:
            N            - номер проверки
            Section      - раздел (Раздел)
            Problem      - наименование проблемы (Проблема)
            Status       - статус (Состояние): 🟢 НОРМА / 🟡 ВАЖНО / 🔴 КРИТИЧНО
            CurrentValue - текущее значение параметра (Текущее значение)
            Detected     - подробное описание (Обнаружено)
            Impact       - влияние на работу 1С (Влияние на работу 1С)
    .EXAMPLE
        $results = Invoke-SqlDiagnostic -Database 'my1cdb' -Password 'secret'
        $results | Where-Object { $_.Status -match 'КРИТИЧНО' } | Format-Table
    .EXAMPLE
        # Автоопределение базы 1С
        $results = Invoke-SqlDiagnostic -Host '192.168.1.10' -Password 'secret'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [string]$Host = 'localhost',

        [Parameter()]
        [int]$Port = 5432,

        [Parameter()]
        [string]$Database,

        [Parameter()]
        [string]$Username = 'postgres',

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [string]$PsqlPath
    )

    # --- 1. Поиск psql ---
    if ([string]::IsNullOrEmpty($PsqlPath)) {
        Write-Verbose "Выполняется автопоиск psql..."
        $PsqlPath = Find-PsqlExecutable
        if ($null -eq $PsqlPath) {
            throw "Не удалось найти psql.exe. Укажите параметр -PsqlPath или установите PostgreSQL."
        }
        Write-Verbose "psql найден: $PsqlPath"
    }
    elseif (-not (Test-Path -Path $PsqlPath -PathType Leaf)) {
        throw "Указанный путь к psql не существует: $PsqlPath"
    }

    # --- 2. Определение пути к SQL-скрипту ---
    $moduleDir = $PSScriptRoot
    $sqlScriptPath = Join-Path -Path $moduleDir -ChildPath $script:SqlScriptRelativePath
    $sqlScriptPath = [System.IO.Path]::GetFullPath($sqlScriptPath)

    if (-not (Test-Path -Path $sqlScriptPath -PathType Leaf)) {
        throw "SQL-скрипт не найден: $sqlScriptPath"
    }
    Write-Verbose "SQL-скрипт: $sqlScriptPath"

    # --- 3. Установка PGPASSWORD (если передан пароль) ---
    $pgPasswordWasSet = $false
    $pgPasswordOldValue = $env:PGPASSWORD

    if (-not [string]::IsNullOrEmpty($Password)) {
        $env:PGPASSWORD = $Password
        $pgPasswordWasSet = $true
        Write-Verbose "PGPASSWORD установлен."
    }

    try {
        # --- 4. Автоопределение базы данных 1С ---
        if ([string]::IsNullOrEmpty($Database)) {
            Write-Verbose "База данных не указана. Выполняется автоопределение базы 1С..."
            $Database = Get-1CDatabase -PsqlPath $PsqlPath -Host $Host -Port $Port -Username $Username
            if ($null -eq $Database) {
                throw "Не удалось автоматически определить базу данных 1С. Укажите параметр -Database."
            }
            Write-Verbose "Используется база данных: $Database"
        }

        # --- 5. Запуск SQL-скрипта ---
        Write-Verbose "Подключение к $Host`:$Port, база: $Database, пользователь: $Username"

        $psqlArgs = @(
            '--host', $Host,
            '--port', $Port,
            '--username', $Username,
            '--csv',
            '--file', $sqlScriptPath,
            $Database
        )

        # Устанавливаем кодировку UTF-8 для psql и PowerShell
        # Без этого кириллица отображается как мусор на Windows
        $env:PGCLIENTENCODING = 'UTF8'
        $savedOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        Write-Verbose "Выполнение диагностического SQL-скрипта..."
        $rawOutput = & $PsqlPath @psqlArgs 2>&1

        # Восстанавливаем кодировку
        [Console]::OutputEncoding = $savedOutputEncoding
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            # Отделяем сообщения об ошибках от вывода данных
            $errorMessages = $rawOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            $errorText = ($errorMessages | ForEach-Object { $_.ToString() }) -join "`n"
            throw "psql завершился с кодом $exitCode.`n$errorText"
        }

        # --- 6. Парсинг вывода ---
        # Оставляем только строковые строки (убираем ErrorRecord если есть)
        $outputLines = $rawOutput |
            Where-Object { $_ -is [string] } |
            ForEach-Object { $_ }

        Write-Verbose "Получено строк вывода: $($outputLines.Count)"

        $results = ConvertFrom-PsqlOutput -Lines $outputLines

        Write-Verbose "Разобрано записей: $($results.Count)"
        return $results
    }
    finally {
        # --- 7. Очистка PGPASSWORD ---
        if ($pgPasswordWasSet) {
            if ($null -eq $pgPasswordOldValue) {
                Remove-Item -Path 'Env:PGPASSWORD' -ErrorAction SilentlyContinue
            }
            else {
                $env:PGPASSWORD = $pgPasswordOldValue
            }
            Write-Verbose "PGPASSWORD очищен."
        }
    }
}

Export-ModuleMember -Function 'Invoke-SqlDiagnostic', 'Find-1CDatabases'
