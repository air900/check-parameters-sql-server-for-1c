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
        - N=700-710: АГРЕГАТНЫЕ ключи (для оценки правилами с min/max/boolean эвалюаторами)
            * mssql_collocated_with_1c_server      bool (rphost/ragent/rmngr running)
            * ntfs_min_block_size_data_bytes       int (минимум по томам с DataDir)
            * ntfs_compression_data_count          int (число томов с включённым сжатием)
            * av_mssql_process_excluded            bool (sqlservr.exe в исключениях Defender)
            * av_mssql_extensions_excluded         bool (минимум mdf+ldf в исключениях)
            * os_power_plan_is_high_perf           bool (по GUID — кросс-локаль)
            * os_context_collection_failures       int (число sub-проверок, которые не удалось выполнить)
            * os_session_is_elevated               bool (PowerShell запущен от имени администратора)
            * os_context_needs_elevation           bool (есть отказы И сессия не админ — actionable WARNING)
            * os_context_third_party_av_likely     bool (admin есть, но Defender absent — INFO о Kaspersky/ESET)
            * os_context_partial_unknown           bool (admin есть, но что-то иное чем Defender отказало — WARNING)
        - N=720+: ПЕРЕЧНЕВЫЕ строки на каждый том (информационные, для отчёта)

        ВАЖНО: проверка memory ballooning гипервизора — невозможна из ОС-контекста
        напрямую. Ограничиваемся detection факта виртуализации (это собирает Collect-OS).

        Silent-failure protection: каждая sub-проверка обернута в try/catch и помечает
        себя строкой-причиной в $subFailReason (not_elevated / component_absent /
        wmi_blocked / parse_error). Defender component_absent — типично для серверов
        в РФ с Kaspersky/ESET. На failure-пути функция всё равно эмитит строку с
        Display='не удалось определить — недостаточно прав / WMI заблокирован /
        нет компонента' и Value='unknown' — чтобы отчёт не был silent-clean.

        Mutex по приоритету (bd iqw): эмитим до трёх actionable-флагов так, что
        одновременно фиксируется максимум один источник проблемы. needs_elevation >
        third_party_av_likely > partial_unknown. YAML вешает по одному правилу на
        каждый флаг с конкретным actionable-текстом — больше нет ситуации «вы уже
        админ, запустите от админа».

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

    # Стандартный текст для случая, когда sub-проверка не отработала
    $unknownDisplay = 'не удалось определить — недостаточно прав / WMI заблокирован / нет компонента'

    # Elevation-check (bd iqw): без admin-прав WMI и Defender отказывают; с admin
    # отказы означают другую причину (компонент отсутствует, GPO, и т.п.).
    $isElevated = $false
    try {
        $identity   = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal  = [Security.Principal.WindowsPrincipal]::new($identity)
        $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $isElevated = $false
    }

    # Per-sub-check причина отказа: $null = успех, иначе строка-классификатор.
    # Категории: 'not_elevated' (нужны admin-права), 'component_absent' (нет cmdlet/cmd
    # на этой системе — обычно сторонний AV вместо Defender), 'wmi_blocked' (admin есть,
    # но WMI/служба отказывает — обычно GPO), 'parse_error' (ответ есть, но не парсится).
    $subFailReason = @{
        'process_detection' = $null   # Get-Process 1C-процессов
        'win32_volume'      = $null   # Get-WmiObject Win32_Volume (block size)
        'win32_logicaldisk' = $null   # Get-WmiObject Win32_LogicalDisk (compression)
        'defender'          = $null   # Get-MpPreference (AV exclusions)
        'powercfg'          = $null   # powercfg /getactivescheme
    }

    # Хелпер: классификация причины WMI-исключения по тексту сообщения.
    function script:Get-WmiFailReason {
        param([string]$ExceptionMessage, [bool]$Elevated)
        if (-not $Elevated) { return 'not_elevated' }
        # На admin-сессии ловим типичные тексты Access denied / GPO-блокировки.
        if ($ExceptionMessage -match '(?i)access\s*(is\s*)?denied|0x80070005|HRESULT\s*0x80070005') {
            return 'wmi_blocked'
        }
        return 'wmi_blocked'
    }

    # ---------------------------------------------------------------------
    # АГРЕГАТНАЯ ЧАСТЬ (N=700-706) — для YAML-правил Tier D
    # ---------------------------------------------------------------------

    # 1. Совмещение 1С + SQL на одной машине (rphost/ragent/rmngr) — N=700
    $coLocated      = $null
    try {
        $procs = Get-Process -Name 'rphost', 'ragent', 'rmngr' -ErrorAction SilentlyContinue
        # Get-Process с -ErrorAction SilentlyContinue вернёт $null если ни одного нет —
        # это валидный «нет совмещения», а не ошибка. Ошибкой считаем только исключение.
        $coLocated = ($null -ne $procs -and @($procs).Count -gt 0)
    }
    catch {
        # Get-Process работает для любого пользователя — отказ обычно означает
        # сильно ограниченную сессию или проблемы с PowerShell host.
        $subFailReason['process_detection'] = if (-not $isElevated) { 'not_elevated' } else { 'wmi_blocked' }
    }

    if ($subFailReason['process_detection']) {
        $rows.Add((New-MssqlOsRow `
            -N 700 -Section $sect -Key 'mssql_collocated_with_1c_server' `
            -Label   'Сервер 1С и MS SQL на одной машине' `
            -Display $unknownDisplay `
            -Value   'unknown'))
    } else {
        $rows.Add((New-MssqlOsRow `
            -N 700 -Section $sect -Key 'mssql_collocated_with_1c_server' `
            -Label   'Сервер 1С и MS SQL на одной машине' `
            -Display $(if ($coLocated) { 'да (обнаружены процессы 1С: rphost/ragent/rmngr)' } else { 'нет' }) `
            -Value   $(if ($coLocated) { 'true' } else { 'false' })))
    }

    # Сбор уникальных drive-letter'ов для томов с DataDir
    $dataDrives = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($inst in $Instances) {
        if (-not $inst.DataDir) { continue }
        $qualifier = (Split-Path -Path $inst.DataDir -Qualifier -ErrorAction SilentlyContinue)
        if ($qualifier) { [void]$dataDrives.Add($qualifier.TrimEnd(':')) }
    }

    # 2. Минимальный NTFS block size по томам данных (Win32_Volume) — N=701
    # 3. Количество томов с включённым NTFS-сжатием (Win32_LogicalDisk) — N=702
    # Sub-проверка считается failed, если хотя бы по одному тому WMI-вызов кинул
    # исключение (типичные причины: не-admin сессия, WMI-сервис заблокирован GPO).
    # Если томов с DataDir нет вообще — failure не выставляем (нечего проверять).
    $minBlock          = $null
    $compressedCnt     = 0
    $volQuerySucceeded = $false
    $ldQuerySucceeded  = $false
    foreach ($drive in $dataDrives) {
        try {
            $vol = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter='$drive`:'" -ErrorAction Stop |
                   Select-Object -First 1
            $volQuerySucceeded = $true
            if ($vol -and $vol.BlockSize) {
                $bs = [int]$vol.BlockSize
                if ($null -eq $minBlock -or $bs -lt $minBlock) { $minBlock = $bs }
            }
        } catch {
            $subFailReason['win32_volume'] = Get-WmiFailReason -ExceptionMessage $_.Exception.Message -Elevated $isElevated
        }
        try {
            $ld = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$drive`:'" -ErrorAction Stop |
                  Select-Object -First 1
            $ldQuerySucceeded = $true
            if ($ld -and $ld.Compressed) { $compressedCnt++ }
        } catch {
            $subFailReason['win32_logicaldisk'] = Get-WmiFailReason -ExceptionMessage $_.Exception.Message -Elevated $isElevated
        }
    }
    # Если томов нет — обе WMI-sub-проверки считаем «не failed» (нечего было проверять).
    # Но если тома были, и ни одного успешного запроса — это явный failure.
    if ($dataDrives.Count -gt 0 -and -not $volQuerySucceeded -and -not $subFailReason['win32_volume']) {
        $subFailReason['win32_volume'] = if (-not $isElevated) { 'not_elevated' } else { 'wmi_blocked' }
    }
    if ($dataDrives.Count -gt 0 -and -not $ldQuerySucceeded -and -not $subFailReason['win32_logicaldisk']) {
        $subFailReason['win32_logicaldisk'] = if (-not $isElevated) { 'not_elevated' } else { 'wmi_blocked' }
    }

    if ($subFailReason['win32_volume']) {
        $rows.Add((New-MssqlOsRow `
            -N 701 -Section $sect -Key 'ntfs_min_block_size_data_bytes' `
            -Label   'Минимальный размер блока NTFS на томах БД (рек. 65536 = 64 KB)' `
            -Display $unknownDisplay `
            -Value   'unknown'))
    } else {
        $rows.Add((New-MssqlOsRow `
            -N 701 -Section $sect -Key 'ntfs_min_block_size_data_bytes' `
            -Label   'Минимальный размер блока NTFS на томах БД (рек. 65536 = 64 KB)' `
            -Display $(if ($minBlock) { "$minBlock bytes ($([math]::Round($minBlock/1024)) KB)" } elseif ($dataDrives.Count -eq 0) { 'нет известных томов БД' } else { 'не удалось определить' }) `
            -Value   $(if ($minBlock) { $minBlock.ToString() } else { '0' })))
    }

    if ($subFailReason['win32_logicaldisk']) {
        $rows.Add((New-MssqlOsRow `
            -N 702 -Section $sect -Key 'ntfs_compression_data_count' `
            -Label   'Томов БД с включённым NTFS-сжатием (антипаттерн)' `
            -Display $unknownDisplay `
            -Value   'unknown'))
    } else {
        $rows.Add((New-MssqlOsRow `
            -N 702 -Section $sect -Key 'ntfs_compression_data_count' `
            -Label   'Томов БД с включённым NTFS-сжатием (антипаттерн)' `
            -Display "$compressedCnt из $($dataDrives.Count)" `
            -Value   $compressedCnt.ToString()))
    }

    # 4. AV-исключения (Windows Defender) — два булевых агрегата (N=703, N=704)
    # Различаем причины failure: cmdlet отсутствует (component_absent — типично для
    # серверов с Kaspersky/ESET вместо Defender), нет admin (not_elevated), или
    # admin есть, но cmdlet падает (wmi_blocked — обычно Defender service остановлен).
    $sqlservrExcluded = $null
    $sqlExtsExcluded  = $null
    $mpCmdAvailable   = $null -ne (Get-Command -Name Get-MpPreference -ErrorAction SilentlyContinue)
    if (-not $mpCmdAvailable) {
        $subFailReason['defender'] = 'component_absent'
    } else {
        try {
            $mp = Get-MpPreference -ErrorAction Stop
            if ($mp) {
                $procExcl = @($mp.ExclusionProcess) | Where-Object { $_ -match '(?i)sqlservr\.exe' }
                $sqlservrExcluded = ($procExcl.Count -gt 0)
                $extExcl = @($mp.ExclusionExtension) | Where-Object { $_ -match '(?i)^\.?(mdf|ldf|ndf)$' }
                $sqlExtsExcluded = ($extExcl.Count -ge 2)
            } else {
                $subFailReason['defender'] = 'component_absent'
            }
        } catch {
            $subFailReason['defender'] = if (-not $isElevated) { 'not_elevated' } else { 'wmi_blocked' }
        }
    }

    if ($subFailReason['defender']) {
        $rows.Add((New-MssqlOsRow `
            -N 703 -Section $sect -Key 'av_mssql_process_excluded' `
            -Label   'Процесс sqlservr.exe в исключениях Windows Defender' `
            -Display $unknownDisplay `
            -Value   'unknown'))
        $rows.Add((New-MssqlOsRow `
            -N 704 -Section $sect -Key 'av_mssql_extensions_excluded' `
            -Label   'Расширения файлов БД (mdf/ldf/ndf) в исключениях Windows Defender' `
            -Display $unknownDisplay `
            -Value   'unknown'))
    } else {
        $rows.Add((New-MssqlOsRow `
            -N 703 -Section $sect -Key 'av_mssql_process_excluded' `
            -Label   'Процесс sqlservr.exe в исключениях Windows Defender' `
            -Display $(if ($sqlservrExcluded) { 'добавлен' } else { 'не добавлен' }) `
            -Value   $(if ($sqlservrExcluded) { 'true' } else { 'false' })))
        $rows.Add((New-MssqlOsRow `
            -N 704 -Section $sect -Key 'av_mssql_extensions_excluded' `
            -Label   'Расширения файлов БД (mdf/ldf/ndf) в исключениях Windows Defender' `
            -Display $(if ($sqlExtsExcluded) { 'добавлены' } else { 'не добавлены' }) `
            -Value   $(if ($sqlExtsExcluded) { 'true' } else { 'false' })))
    }

    # 5. План электропитания High Performance (по GUID — кросс-локаль) — N=705
    # Различаем: powercfg.exe вообще не найден (component_absent — Server Core),
    # exit-код != 0 без stdout (parse_error), exit==0 но GUID не парсится (parse_error).
    #
    # Парсинг: powercfg /getactivescheme возвращает string[] (массив строк). На таком
    # типе оператор `-match` работает как фильтр и НЕ заполняет $Matches — поэтому
    # используем [regex]::Match по joined-строке. По существу нам важен ТОЛЬКО UUID
    # активной схемы, а не локализованный префикс ("Power Scheme GUID:" / "Параметр
    # электропитания текущей схемы:" / etc.). Regex по самому формату UUID — наиболее
    # cross-locale устойчивый: powercfg /getactivescheme печатает ровно один UUID.
    $highPerfGuids = @(
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c',  # High Performance
        'e9a42b02-d5df-448d-aa00-03f14749eb61'   # Ultimate Performance (Win 10/Server 2019+)
    )
    $uuidPattern      = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $isHighPerf       = $null
    $pcfgCmdAvailable = $null -ne (Get-Command -Name powercfg -ErrorAction SilentlyContinue)
    if (-not $pcfgCmdAvailable) {
        $subFailReason['powercfg'] = 'component_absent'
    } else {
        try {
            # & powercfg + Out-String: захват всего вывода как scalar string,
            # независимо от того, как PS трактует stdout (string[] vs string).
            $rawOut = & powercfg /getactivescheme 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rawOut)) {
                $subFailReason['powercfg'] = 'parse_error'
            } else {
                $guidMatch = [regex]::Match($rawOut, $uuidPattern)
                if ($guidMatch.Success) {
                    $activeGuid = $guidMatch.Groups[1].Value.ToLower()
                    $isHighPerf = ($highPerfGuids -contains $activeGuid)
                } else {
                    $subFailReason['powercfg'] = 'parse_error'
                }
            }
        } catch {
            $subFailReason['powercfg'] = 'component_absent'
        }
    }

    if ($subFailReason['powercfg']) {
        $rows.Add((New-MssqlOsRow `
            -N 705 -Section $sect -Key 'os_power_plan_is_high_perf' `
            -Label   'План электропитания — High/Ultimate Performance' `
            -Display $unknownDisplay `
            -Value   'unknown'))
    } else {
        $rows.Add((New-MssqlOsRow `
            -N 705 -Section $sect -Key 'os_power_plan_is_high_perf' `
            -Label   'План электропитания — High/Ultimate Performance' `
            -Display $(if ($isHighPerf) { 'да' } else { 'нет (Balanced или другой)' }) `
            -Value   $(if ($isHighPerf) { 'true' } else { 'false' })))
    }

    # 6. Аггрегаты по результатам sub-проверок (N=706..710).
    # bd iqw: вместо одного счётчика и одного generic-сообщения "запустите от админа",
    # эмитим (a) детальный per-cause Display, (b) флаг is_elevated, (c) три булевых
    # actionable-флага, на которые YAML вешает по одному правилу с конкретным текстом.
    # Приоритет (mutex): needs_elevation > third_party_av_likely > partial_unknown.
    $reasonRu = @{
        'not_elevated'     = 'нужны права администратора'
        'component_absent' = 'компонент не установлен (вероятно сторонний AV или Server Core)'
        'wmi_blocked'      = 'WMI/служба заблокированы (GPO или служба остановлена)'
        'parse_error'      = 'не удалось распарсить вывод'
    }
    $failedEntries = @($subFailReason.GetEnumerator() | Where-Object { $null -ne $_.Value })
    $failedCount   = $failedEntries.Count
    $totalSub      = $subFailReason.Count
    if ($failedCount -eq 0) {
        $failDisplay = "0 из ${totalSub} — все OS-проверки успешно выполнены"
    } else {
        $detailParts = $failedEntries | ForEach-Object {
            $causeRu = if ($reasonRu.ContainsKey($_.Value)) { $reasonRu[$_.Value] } else { $_.Value }
            "$($_.Key): $causeRu"
        }
        $failDisplay = "$failedCount из ${totalSub} не выполнены — $([string]::Join('; ', $detailParts))"
    }
    $rows.Add((New-MssqlOsRow `
        -N 706 -Section $sect -Key 'os_context_collection_failures' `
        -Label   'Число sub-проверок OS-контекста, которые не удалось выполнить' `
        -Display $failDisplay `
        -Value   $failedCount.ToString()))

    # N=707: флаг elevation (info-only, для диагностики).
    $rows.Add((New-MssqlOsRow `
        -N 707 -Section $sect -Key 'os_session_is_elevated' `
        -Label   'Сессия PowerShell запущена от имени администратора' `
        -Display $(if ($isElevated) { 'да' } else { 'нет' }) `
        -Value   $(if ($isElevated) { 'true' } else { 'false' })))

    # Pre-computed actionable flags (N=708..710). Mutex по приоритету причин.
    $needsElevation        = ($failedCount -gt 0 -and -not $isElevated)
    $thirdPartyAvLikely    = $false
    $partialUnknown        = $false
    if ($isElevated -and $failedCount -gt 0) {
        $defenderAbsent     = ($subFailReason['defender'] -eq 'component_absent')
        $thirdPartyAvLikely = $defenderAbsent
        # partial_unknown — есть failure, но это НЕ только defender component_absent.
        $nonDefenderFails = @($failedEntries | Where-Object { $_.Key -ne 'defender' -or $_.Value -ne 'component_absent' })
        $partialUnknown = ($nonDefenderFails.Count -gt 0)
    }

    $rows.Add((New-MssqlOsRow `
        -N 708 -Section $sect -Key 'os_context_needs_elevation' `
        -Label   'OS-контекст требует перезапуска от имени администратора' `
        -Display $(if ($needsElevation) { 'да — есть отказы и сессия не админ' } else { 'нет' }) `
        -Value   $(if ($needsElevation) { 'true' } else { 'false' })))

    $rows.Add((New-MssqlOsRow `
        -N 709 -Section $sect -Key 'os_context_third_party_av_likely' `
        -Label   'Вероятно используется сторонний антивирус (Defender отсутствует)' `
        -Display $(if ($thirdPartyAvLikely) { 'да — Get-MpPreference недоступен на admin-сессии' } else { 'нет' }) `
        -Value   $(if ($thirdPartyAvLikely) { 'true' } else { 'false' })))

    $rows.Add((New-MssqlOsRow `
        -N 710 -Section $sect -Key 'os_context_partial_unknown' `
        -Label   'Часть OS-проверок отказала по причинам кроме Defender' `
        -Display $(if ($partialUnknown) { 'да — см. detail в os_context_collection_failures' } else { 'нет' }) `
        -Value   $(if ($partialUnknown) { 'true' } else { 'false' })))

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
