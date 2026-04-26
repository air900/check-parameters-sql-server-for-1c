#Requires -Version 5.1
<#
.SYNOPSIS
    Модуль автоматического обнаружения экземпляров Microsoft SQL Server на Windows-сервере.

.DESCRIPTION
    Определяет установленные экземпляры MS SQL Server тремя способами (в порядке приоритета):
    1. Через службы Windows (MSSQLSERVER / MSSQL$<INSTANCE>)
    2. Через реестр (HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL)
    3. Через TCP-порт 1433 (резерв, для неподобранных экземпляров)

    Дополнительно: функция Get-MssqlOSContext возвращает OS-уровневые данные,
    специфичные для MSSQL-диагностики (cluster size томов БД, NTFS-сжатие на томах,
    факт совмещения 1С+SQL, AV-исключения для процесса sqlservr.exe). Эти данные
    собираются в формате коллектора (N/Section/Key/Label/Display/Value) и идут
    отдельной секцией в JSON, отправляемый на бэкенд.

    Используется диагностическим скриптом Invoke-1CDiagnostic.ps1 для серверов 1С:Предприятие.

.NOTES
    PowerShell 5.1 совместимо. Подводные камни:
    - Get-Service/Get-ItemProperty/Get-WmiObject — все доступны.
    - Get-MpPreference требует Windows 10 / Server 2016+ (Windows Defender).
    - Test-NetConnection медленный (несколько секунд на закрытом порту), используется
      только если служба не найдена.
#>

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

function New-MssqlInstance {
    <#
    .SYNOPSIS
        Создаёт унифицированный объект с описанием экземпляра MS SQL Server.
    #>
    [OutputType([PSCustomObject])]
    param (
        [string]$ServiceName  = $null,
        [string]$InstanceName = $null,
        [string]$Status       = 'Unknown',
        [int]   $Port         = 1433,
        [string]$Version      = $null,
        [string]$Edition      = $null,
        [string]$Path         = $null,
        [string]$DataDir      = $null
    )

    return [PSCustomObject]@{
        ServiceName  = $ServiceName
        InstanceName = $InstanceName
        Status       = $Status
        Port         = $Port
        Version      = $Version
        Edition      = $Edition
        Path         = $Path
        DataDir      = $DataDir
    }
}

function Get-InstanceNameFromService {
    <#
    .SYNOPSIS
        Извлекает имя экземпляра из имени службы.
        MSSQLSERVER       → 'MSSQLSERVER' (default instance)
        MSSQL$DEV         → 'DEV' (named instance)
    #>
    [OutputType([string])]
    param ([string]$ServiceName)

    if ($ServiceName -eq 'MSSQLSERVER') {
        return 'MSSQLSERVER'
    }
    if ($ServiceName -match '^MSSQL\$(.+)$') {
        return $Matches[1]
    }
    return $null
}

function Test-IsDatabaseEngineService {
    <#
    .SYNOPSIS
        True для служб Database Engine (MSSQLSERVER, MSSQL$NAME),
        False для агента, browser, full-text launcher и прочих сопутствующих служб.
    #>
    [OutputType([bool])]
    param ([string]$ServiceName)

    # Точно НЕ Database Engine:
    if ($ServiceName -match '(?i)(LAUNCHPAD|FDLAUNCHER|FDHOST|TELEMETRY|OLAPService|ServerOLAP|SQLBrowser|SQLWriter|MsDtsServer|ReportServer)') {
        return $false
    }
    # Агент имени экземпляра: SQLAgent$NAME или SQLSERVERAGENT — это агент, не engine
    if ($ServiceName -match '(?i)(SQLAGENT|SQLSERVERAGENT)') {
        return $false
    }
    # Database Engine — строго MSSQLSERVER или MSSQL$NAME
    return ($ServiceName -eq 'MSSQLSERVER' -or $ServiceName -match '^MSSQL\$')
}

function Get-RegistryInstanceKey {
    <#
    .SYNOPSIS
        По имени экземпляра возвращает имя ключа реестра вида MSSQL15.MSSQLSERVER.
        Корень: HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL
        Свойство: <InstanceName>, значение: имя ключа реестра.
    #>
    [OutputType([string])]
    param ([string]$InstanceName)

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    try {
        $entry = Get-ItemProperty -LiteralPath $regPath -Name $InstanceName -ErrorAction Stop
        return $entry.$InstanceName
    }
    catch {
        return $null
    }
}

function Get-InstanceDetailsFromRegistry {
    <#
    .SYNOPSIS
        Возвращает PSCustomObject с {Version, Edition, BinDir, DataDir, TcpPort}
        для указанного registry-key экземпляра (например, MSSQL15.MSSQLSERVER).
    #>
    [OutputType([PSCustomObject])]
    param ([string]$RegistryInstanceKey)

    $details = [PSCustomObject]@{
        Version  = $null
        Edition  = $null
        BinDir   = $null
        DataDir  = $null
        TcpPort  = $null
    }

    if (-not $RegistryInstanceKey) { return $details }

    $setupPath  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$RegistryInstanceKey\Setup"
    $serverPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$RegistryInstanceKey\MSSQLServer"
    $tcpAllPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$RegistryInstanceKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"

    try {
        $setup = Get-ItemProperty -LiteralPath $setupPath -ErrorAction SilentlyContinue
        if ($setup) {
            if ($setup.PSObject.Properties.Name -contains 'Version')      { $details.Version = $setup.Version }
            if ($setup.PSObject.Properties.Name -contains 'Edition')      { $details.Edition = $setup.Edition }
            if ($setup.PSObject.Properties.Name -contains 'SQLBinRoot')   { $details.BinDir  = $setup.SQLBinRoot }
            if ($setup.PSObject.Properties.Name -contains 'SQLDataRoot')  { $details.DataDir = $setup.SQLDataRoot }
        }
    }
    catch { }

    # Если SQLDataRoot пуст — берём DefaultData из MSSQLServer
    if (-not $details.DataDir) {
        try {
            $mss = Get-ItemProperty -LiteralPath $serverPath -ErrorAction SilentlyContinue
            if ($mss -and $mss.PSObject.Properties.Name -contains 'DefaultData') {
                $details.DataDir = $mss.DefaultData
            }
        }
        catch { }
    }

    # Порт из IPAll: фиксированный TcpPort или динамический TcpDynamicPorts
    try {
        $tcp = Get-ItemProperty -LiteralPath $tcpAllPath -ErrorAction SilentlyContinue
        if ($tcp) {
            if ($tcp.PSObject.Properties.Name -contains 'TcpPort' -and $tcp.TcpPort) {
                # Строка вида "1433" или пустая
                $portStr = "$($tcp.TcpPort)".Trim()
                if ($portStr -and ($portStr -as [int])) { $details.TcpPort = [int]$portStr }
            }
            if (-not $details.TcpPort -and $tcp.PSObject.Properties.Name -contains 'TcpDynamicPorts' -and $tcp.TcpDynamicPorts) {
                $portStr = "$($tcp.TcpDynamicPorts)".Trim()
                if ($portStr -and ($portStr -as [int])) { $details.TcpPort = [int]$portStr }
            }
        }
    }
    catch { }

    return $details
}

function Get-EditionDescription {
    <#
    .SYNOPSIS
        Преобразует строку Edition реестра в читаемое название.
    #>
    [OutputType([string])]
    param ([string]$Edition)

    if (-not $Edition) { return $null }
    # В реестре Edition уже строка типа "Standard Edition (64-bit)" / "Enterprise Edition: Core-based Licensing"
    return $Edition
}

# ---------------------------------------------------------------------------
# Стратегия 1: Службы Windows
# ---------------------------------------------------------------------------

function Find-MSSQLByService {
    <#
    .SYNOPSIS
        Обнаруживает экземпляры MS SQL Server через службы Windows (MSSQLSERVER, MSSQL$<INSTANCE>).
    #>
    [OutputType([PSCustomObject[]])]
    param()

    $found = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $services = Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue
    }
    catch {
        return $found
    }

    foreach ($svc in $services) {
        if (-not (Test-IsDatabaseEngineService -ServiceName $svc.Name)) { continue }

        $instanceName = Get-InstanceNameFromService -ServiceName $svc.Name
        if (-not $instanceName) { continue }

        # Реестр: имя ключа MSSQLxx.<InstanceName>
        $regKey  = Get-RegistryInstanceKey -InstanceName $instanceName
        $details = Get-InstanceDetailsFromRegistry -RegistryInstanceKey $regKey

        $port = if ($details.TcpPort) { $details.TcpPort } else { 1433 }

        $found.Add(
            (New-MssqlInstance `
                -ServiceName  $svc.Name `
                -InstanceName $instanceName `
                -Status       $svc.Status.ToString() `
                -Port         $port `
                -Version      $details.Version `
                -Edition      (Get-EditionDescription -Edition $details.Edition) `
                -Path         $details.BinDir `
                -DataDir      $details.DataDir)
        )
    }

    return $found
}

# ---------------------------------------------------------------------------
# Стратегия 2: Реестр
# ---------------------------------------------------------------------------

function Find-MSSQLByRegistry {
    <#
    .SYNOPSIS
        Обнаруживает MS SQL Server через `Instance Names\SQL` в реестре.
        Полезно, когда служба переименована или установка повреждена, но реестр сохранил информацию.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [string[]]$KnownInstances = @()
    )

    $found  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $regRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'

    if (-not (Test-Path $regRoot)) { return $found }

    try {
        $regProps = Get-ItemProperty -LiteralPath $regRoot -ErrorAction SilentlyContinue
    }
    catch {
        return $found
    }

    if (-not $regProps) { return $found }

    foreach ($prop in $regProps.PSObject.Properties) {
        if ($prop.Name -like 'PS*') { continue } # PSPath, PSChildName, и т.д.

        $instanceName = $prop.Name
        if ($KnownInstances -contains $instanceName) { continue }

        $regKey  = $prop.Value
        $details = Get-InstanceDetailsFromRegistry -RegistryInstanceKey $regKey

        $port = if ($details.TcpPort) { $details.TcpPort } else { 1433 }

        # Реестр найден, но службы могло уже не быть — статус Unknown
        $found.Add(
            (New-MssqlInstance `
                -ServiceName  $null `
                -InstanceName $instanceName `
                -Status       'Unknown' `
                -Port         $port `
                -Version      $details.Version `
                -Edition      (Get-EditionDescription -Edition $details.Edition) `
                -Path         $details.BinDir `
                -DataDir      $details.DataDir)
        )
    }

    return $found
}

# ---------------------------------------------------------------------------
# Стратегия 3: Проверка порта
# ---------------------------------------------------------------------------

function Find-MSSQLByPort {
    <#
    .SYNOPSIS
        Проверяет доступность стандартного порта 1433 на localhost.
        Используется как последний резерв, если ни службы, ни реестр не дали результата.
    #>
    [OutputType([PSCustomObject[]])]
    param ([int]$Port = 1433)

    $found = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $test = Test-NetConnection -ComputerName 'localhost' -Port $Port -InformationLevel 'Quiet' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($test) {
            $found.Add(
                (New-MssqlInstance `
                    -ServiceName  $null `
                    -InstanceName 'unknown (port-only)' `
                    -Status       'Listening' `
                    -Port         $Port)
            )
        }
    }
    catch { }

    return $found
}

# ---------------------------------------------------------------------------
# Главная функция
# ---------------------------------------------------------------------------

function Find-MSSQL {
    <#
    .SYNOPSIS
        Обнаруживает установленные экземпляры MS SQL Server на локальном Windows-сервере.

    .DESCRIPTION
        Последовательно применяет три стратегии обнаружения:
        1. Службы Windows (MSSQLSERVER / MSSQL$<INSTANCE>) — наиболее надёжный способ.
        2. Реестр `Instance Names\SQL` — находит экземпляры без активной службы.
        3. TCP-соединение на порт 1433 — последний резерв.

        Возвращает массив объектов с полями:
          ServiceName  — имя службы Windows (или $null)
          InstanceName — имя экземпляра (MSSQLSERVER / DEV / ...)
          Status       — состояние службы (Running / Stopped / Unknown / Listening)
          Port         — TCP-порт MS SQL Server
          Version      — Product Version (например 15.0.4123.1) или $null
          Edition      — Edition Name (например "Enterprise Edition: Core-based Licensing")
          Path         — SQLBinRoot (директория Binn) или $null
          DataDir      — SQLDataRoot или DefaultData

    .OUTPUTS
        PSCustomObject[]

    .EXAMPLE
        $instances = Find-MSSQL
        foreach ($inst in $instances) {
            Write-Host "Экземпляр: $($inst.InstanceName), версия: $($inst.Version), порт: $($inst.Port), статус: $($inst.Status)"
        }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    $allInstances = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Verbose 'Find-MSSQL: поиск через службы Windows (MSSQL*)...'
    $byService = Find-MSSQLByService
    foreach ($inst in $byService) { $allInstances.Add($inst) }

    Write-Verbose 'Find-MSSQL: поиск через реестр Instance Names\SQL...'
    $knownInstances = @($allInstances | Where-Object { $_.InstanceName } | ForEach-Object { $_.InstanceName })
    $byRegistry = Find-MSSQLByRegistry -KnownInstances $knownInstances
    foreach ($inst in $byRegistry) { $allInstances.Add($inst) }

    if ($allInstances.Count -eq 0) {
        Write-Verbose 'Find-MSSQL: экземпляры не найдены, проверка порта 1433...'
        $byPort = Find-MSSQLByPort -Port 1433
        foreach ($inst in $byPort) { $allInstances.Add($inst) }
    }

    if ($allInstances.Count -eq 0) {
        Write-Verbose 'Find-MSSQL: экземпляры MS SQL Server не обнаружены.'
    }
    else {
        Write-Verbose "Find-MSSQL: найдено экземпляров: $($allInstances.Count)."
    }

    return $allInstances.ToArray()
}

# ---------------------------------------------------------------------------
# OS-context для Tier D (PowerShell-readable параметры для YAML-движка)
# ---------------------------------------------------------------------------

function New-MssqlOsRow {
    <#
    .SYNOPSIS
        Создаёт строку collector-формата (N/Section/Key/Label/Display/Value).
        Симметрично New-OsRow в Collect-OS.psm1, но с секцией os_mssql.
    #>
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)] [int]    $N,
        [Parameter(Mandatory)] [string] $Section,
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Label,
        [string] $Display = '',
        [string] $Value   = ''
    )

    return [PSCustomObject]@{
        N       = $N
        Section = $Section
        Key     = $Key
        Label   = $Label
        Display = $Display
        Value   = $Value
    }
}

function Get-MssqlOSContext {
    <#
    .SYNOPSIS
        Собирает OS-уровневые данные, специфичные для диагностики MS SQL Server.

    .DESCRIPTION
        Возвращает массив строк collector-формата (N/Section/Key/Label/Display/Value),
        которые после Send-DiagnosticData попадают в JSON и оцениваются YAML-правилами
        Tier D (mssql.yaml § 15).

        Структура вывода:
        - N=700-709: АГРЕГАТНЫЕ ключи (для оценки правилами с min/max/boolean эвалюаторами)
            * mssql_collocated_with_1c_server      bool (rphost/ragent/rmngr running)
            * ntfs_min_block_size_data_bytes       int (минимум по томам с DataDir)
            * ntfs_compression_data_count          int (число томов с включённым сжатием)
            * av_mssql_process_excluded            bool (sqlservr.exe в исключениях Defender)
            * av_mssql_extensions_excluded         bool (минимум mdf+ldf в исключениях)
            * os_power_plan_is_high_perf           bool (по GUID — кросс-локаль)
        - N=720+: ПЕРЕЧНЕВЫЕ строки на каждый том (информационные, для отчёта)

        ВАЖНО: проверка memory ballooning гипервизора — невозможна из ОС-контекста
        напрямую. Ограничиваемся detection факта виртуализации (это собирает Collect-OS).

    .PARAMETER Instances
        Массив объектов от Find-MSSQL. Используется для определения томов с DataDir.

    .PARAMETER StartingN
        Начальный N для агрегатов (default 700). Per-drive строки идут с StartingN+20.

    .OUTPUTS
        PSCustomObject[]

    .EXAMPLE
        $instances = Find-MSSQL
        $osRows    = Get-MssqlOSContext -Instances $instances
        # $osRows объединяется с SQL-collector-данными в общем JSON для бэкенда
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [PSCustomObject[]]$Instances = @(),
        [int]$StartingN = 700
    )

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $sect = 'os_mssql'

    # ---------------------------------------------------------------------
    # АГРЕГАТНАЯ ЧАСТЬ (N=700-709) — для YAML-правил Tier D
    # ---------------------------------------------------------------------

    # 1. Совмещение 1С + SQL на одной машине (rphost/ragent/rmngr)
    $coLocated = $false
    try {
        $procs = Get-Process -Name 'rphost', 'ragent', 'rmngr' -ErrorAction SilentlyContinue
        if ($procs) { $coLocated = ($procs.Count -gt 0) }
    }
    catch { }

    $rows.Add((New-MssqlOsRow `
        -N 700 -Section $sect -Key 'mssql_collocated_with_1c_server' `
        -Label   'Сервер 1С и MS SQL на одной машине' `
        -Display $(if ($coLocated) { 'да (обнаружены процессы 1С: rphost/ragent/rmngr)' } else { 'нет' }) `
        -Value   $(if ($coLocated) { 'true' } else { 'false' })))

    # Сбор уникальных drive-letter'ов для томов с DataDir
    $dataDrives = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($inst in $Instances) {
        if (-not $inst.DataDir) { continue }
        $qualifier = (Split-Path -Path $inst.DataDir -Qualifier -ErrorAction SilentlyContinue)
        if ($qualifier) { [void]$dataDrives.Add($qualifier.TrimEnd(':')) }
    }

    # 2. Минимальный NTFS block size по томам данных
    # 3. Количество томов с включённым NTFS-сжатием
    $minBlock      = $null
    $compressedCnt = 0
    foreach ($drive in $dataDrives) {
        try {
            $vol = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter='$drive`:'" -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($vol -and $vol.BlockSize) {
                $bs = [int]$vol.BlockSize
                if ($null -eq $minBlock -or $bs -lt $minBlock) { $minBlock = $bs }
            }
        } catch { }
        try {
            $ld = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$drive`:'" -ErrorAction SilentlyContinue |
                  Select-Object -First 1
            if ($ld -and $ld.Compressed) { $compressedCnt++ }
        } catch { }
    }

    $rows.Add((New-MssqlOsRow `
        -N 701 -Section $sect -Key 'ntfs_min_block_size_data_bytes' `
        -Label   'Минимальный размер блока NTFS на томах БД (рек. 65536 = 64 KB)' `
        -Display $(if ($minBlock) { "$minBlock bytes ($([math]::Round($minBlock/1024)) KB)" } elseif ($dataDrives.Count -eq 0) { 'нет известных томов БД' } else { 'не удалось определить' }) `
        -Value   $(if ($minBlock) { $minBlock.ToString() } else { '0' })))

    $rows.Add((New-MssqlOsRow `
        -N 702 -Section $sect -Key 'ntfs_compression_data_count' `
        -Label   'Томов БД с включённым NTFS-сжатием (антипаттерн)' `
        -Display "$compressedCnt из $($dataDrives.Count)" `
        -Value   $compressedCnt.ToString()))

    # 4. AV-исключения (Windows Defender) — два булевых агрегата
    $sqlservrExcluded = $null
    $sqlExtsExcluded  = $null
    try {
        $mp = Get-MpPreference -ErrorAction SilentlyContinue
        if ($mp) {
            $procExcl = @($mp.ExclusionProcess) | Where-Object { $_ -match '(?i)sqlservr\.exe' }
            $sqlservrExcluded = ($procExcl.Count -gt 0)
            $extExcl = @($mp.ExclusionExtension) | Where-Object { $_ -match '(?i)^\.?(mdf|ldf|ndf)$' }
            $sqlExtsExcluded = ($extExcl.Count -ge 2)
        }
    } catch { }

    $rows.Add((New-MssqlOsRow `
        -N 703 -Section $sect -Key 'av_mssql_process_excluded' `
        -Label   'Процесс sqlservr.exe в исключениях Windows Defender' `
        -Display $(if ($null -ne $sqlservrExcluded) { $(if ($sqlservrExcluded) { 'добавлен' } else { 'не добавлен' }) } else { 'не удалось определить' }) `
        -Value   $(if ($null -ne $sqlservrExcluded) { $(if ($sqlservrExcluded) { 'true' } else { 'false' }) } else { 'unknown' })))

    $rows.Add((New-MssqlOsRow `
        -N 704 -Section $sect -Key 'av_mssql_extensions_excluded' `
        -Label   'Расширения файлов БД (mdf/ldf/ndf) в исключениях Windows Defender' `
        -Display $(if ($null -ne $sqlExtsExcluded) { $(if ($sqlExtsExcluded) { 'добавлены' } else { 'не добавлены' }) } else { 'не удалось определить' }) `
        -Value   $(if ($null -ne $sqlExtsExcluded) { $(if ($sqlExtsExcluded) { 'true' } else { 'false' }) } else { 'unknown' })))

    # 5. План электропитания High Performance (по GUID — кросс-локаль)
    $highPerfGuids = @(
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c',  # High Performance
        'e9a42b02-d5df-448d-aa00-03f14749eb61'   # Ultimate Performance (Win 10/Server 2019+)
    )
    $isHighPerf = $false
    try {
        $output = powercfg /getactivescheme 2>$null
        if ($output -match 'GUID:\s*([0-9a-fA-F-]+)') {
            $activeGuid = $Matches[1].ToLower()
            $isHighPerf = ($highPerfGuids -contains $activeGuid)
        }
    } catch { }

    $rows.Add((New-MssqlOsRow `
        -N 705 -Section $sect -Key 'os_power_plan_is_high_perf' `
        -Label   'План электропитания — High/Ultimate Performance' `
        -Display $(if ($isHighPerf) { 'да' } else { 'нет (Balanced или другой)' }) `
        -Value   $(if ($isHighPerf) { 'true' } else { 'false' })))

    # ---------------------------------------------------------------------
    # ПЕРЕЧНЕВАЯ ЧАСТЬ (N=720+) — для отображения в отчёте, не для правил
    # ---------------------------------------------------------------------
    $n = $StartingN + 20
    foreach ($drive in $dataDrives) {
        $bs        = $null
        $compr     = $null
        try {
            $vol = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter='$drive`:'" -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($vol -and $vol.BlockSize) { $bs = [int]$vol.BlockSize }
        } catch { }
        try {
            $ld = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$drive`:'" -ErrorAction SilentlyContinue |
                  Select-Object -First 1
            if ($ld) { $compr = [bool]$ld.Compressed }
        } catch { }

        $rows.Add((New-MssqlOsRow `
            -N $n -Section $sect -Key "_ntfs_block_$($drive.ToLower())" `
            -Label   "Том $drive`: размер блока NTFS" `
            -Display $(if ($bs) { "$bs bytes ($([math]::Round($bs/1024)) KB)" } else { 'не удалось определить' }) `
            -Value   $(if ($bs) { $bs.ToString() } else { '0' })))
        $n++

        $rows.Add((New-MssqlOsRow `
            -N $n -Section $sect -Key "_ntfs_compression_$($drive.ToLower())" `
            -Label   "Том $drive`: NTFS-сжатие" `
            -Display $(if ($null -ne $compr) { $(if ($compr) { 'включено' } else { 'выключено' }) } else { 'не удалось определить' }) `
            -Value   $(if ($null -ne $compr) { $(if ($compr) { 'true' } else { 'false' }) } else { 'unknown' })))
        $n++
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function Find-MSSQL, Get-MssqlOSContext
