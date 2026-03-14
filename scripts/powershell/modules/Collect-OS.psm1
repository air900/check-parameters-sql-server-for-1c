#Requires -Version 5.1
<#
.SYNOPSIS
    Модуль сбора данных об операционной системе Windows для диагностики PostgreSQL 1С.

.DESCRIPTION
    Собирает фактические параметры ОС и оборудования: RAM, CPU, диски, сеть,
    план электропитания, файл подкачки, виртуализацию и версию ОС.

    Данные предназначены для диагностики серверов 1С:Предприятие под управлением
    PostgreSQL на Windows. Никакой интерпретации и пороговых значений — только факты.

    Каждая секция завёрнута в try/catch для устойчивости к ошибкам доступа.
#>

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

function New-OsRow {
    <#
    .SYNOPSIS
        Создаёт строку результата в формате, совместимом с Invoke-SqlDiagnostic.
    #>
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [int]$N,

        [Parameter(Mandatory)]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Problem,

        [Parameter(Mandatory)]
        [string]$CurrentValue
    )

    return [PSCustomObject]@{
        N            = $N
        Section      = $Section
        Problem      = $Problem
        Status       = ''
        CurrentValue = $CurrentValue
        Detected     = ''
        Impact       = ''
    }
}

function Format-Bytes {
    <#
    .SYNOPSIS
        Форматирует количество байт в читаемую строку (GB или MB).
    #>
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return '{0:N1} GB' -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return '{0:N0} MB' -f ($Bytes / 1MB)
    }
    else {
        return '{0:N0} KB' -f ($Bytes / 1KB)
    }
}

# ---------------------------------------------------------------------------
# Секция: ОПЕРАТИВНАЯ ПАМЯТЬ
# ---------------------------------------------------------------------------

function Get-RamRows {
    <#
    .SYNOPSIS
        Собирает данные об оперативной памяти сервера.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ОПЕРАТИВНАЯ ПАМЯТЬ'

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

        if ($cs -and $os) {
            $totalBytes     = $cs.TotalPhysicalMemory
            $freeBytes      = $os.FreePhysicalMemory * 1KB  # значение в КБ
            $usedBytes      = $totalBytes - $freeBytes
            $usedPct        = if ($totalBytes -gt 0) { [math]::Round($usedBytes / $totalBytes * 100, 1) } else { 0 }

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Общий объём RAM'    -CurrentValue (Format-Bytes -Bytes $totalBytes)))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Доступная RAM'      -CurrentValue (Format-Bytes -Bytes $freeBytes)))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Использование RAM'  -CurrentValue "$usedPct%"))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Объём RAM' -CurrentValue 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Объём RAM' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: ПРОЦЕССОР
# ---------------------------------------------------------------------------

function Get-CpuRows {
    <#
    .SYNOPSIS
        Собирает данные о процессорах сервера.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ПРОЦЕССОР'

    try {
        $cpus = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue

        if ($cpus) {
            # Win32_Processor возвращает один объект на сокет
            $cpuArray = @($cpus)

            $totalCores   = ($cpuArray | Measure-Object -Property NumberOfCores -Sum).Sum
            $totalLogical = ($cpuArray | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            $sockets      = $cpuArray.Count
            $cpuName      = $cpuArray[0].Name -replace '\s+', ' '
            $htEnabled    = if ($totalLogical -gt $totalCores) { 'Включён' } else { 'Выключен' }

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Модель процессора'        -CurrentValue $cpuName))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Физических ядер'          -CurrentValue "$totalCores"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Логических процессоров'   -CurrentValue "$totalLogical"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Количество сокетов'       -CurrentValue "$sockets"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Hyperthreading'            -CurrentValue $htEnabled))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Данные процессора' -CurrentValue 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Данные процессора' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: ЭНЕРГОСБЕРЕЖЕНИЕ
# ---------------------------------------------------------------------------

function Get-PowerPlanRows {
    <#
    .SYNOPSIS
        Определяет активный план электропитания через powercfg.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ЭНЕРГОСБЕРЕЖЕНИЕ'

    try {
        # powercfg /getactivescheme возвращает строку вида:
        # Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)
        $output    = powercfg /getactivescheme 2>$null
        $planName  = 'Не удалось определить'

        if ($output -match '\((.+?)\)\s*$') {
            $planName = $Matches[1].Trim()
        }
        elseif ($output -match 'GUID:\s*[\w-]+\s+(.+)$') {
            $planName = $Matches[1].Trim()
        }

        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Текущий план электропитания' -CurrentValue $planName))
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Текущий план электропитания' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: ДИСКОВАЯ ПОДСИСТЕМА
# ---------------------------------------------------------------------------

function Get-DiskRows {
    <#
    .SYNOPSIS
        Собирает данные о физических дисках и томах файловой системы.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter,

        # Директория данных PostgreSQL (для фильтрации томов); может быть пустой
        [string]$DataDir = ''
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ДИСКОВАЯ ПОДСИСТЕМА'

    # --- Физические диски ---
    try {
        # Пробуем Get-PhysicalDisk (требует Storage Module / Windows 8+)
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue

        if ($physDisks) {
            foreach ($disk in $physDisks) {
                $mediaType = switch ($disk.MediaType) {
                    'SSD'         { 'SSD' }
                    'HDD'         { 'HDD' }
                    'SCM'         { 'NVMe/SCM' }
                    'Unspecified' { 'Не определён' }
                    default       { $disk.MediaType }
                }

                # Дополнительно проверяем NVMe по модели/шине
                if ($mediaType -eq 'Не определён' -or $mediaType -eq 'SSD') {
                    if ($disk.FriendlyName -match 'NVMe' -or $disk.BusType -eq 'NVMe') {
                        $mediaType = 'NVMe'
                    }
                }

                $sizeStr  = Format-Bytes -Bytes $disk.Size
                $diskInfo = "$($disk.FriendlyName) | $mediaType | $sizeStr"

                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Физический диск' -CurrentValue $diskInfo))
            }
        }
        else {
            # Резерв: Win32_DiskDrive
            throw 'Get-PhysicalDisk вернул пустой результат'
        }
    }
    catch {
        try {
            $wmiDisks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue

            foreach ($disk in $wmiDisks) {
                $sizeStr  = if ($disk.Size) { Format-Bytes -Bytes ([long]$disk.Size) } else { 'Н/Д' }
                $diskInfo = "$($disk.Model) | $sizeStr"

                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Физический диск' -CurrentValue $diskInfo))
            }
        }
        catch {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Физические диски' -CurrentValue 'Не удалось получить'))
        }
    }

    # --- Тома файловой системы ---
    try {
        $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue

        foreach ($vol in $volumes) {
            # Если известна директория данных PG — показываем только нужный том
            if ($DataDir -ne '') {
                $driveLetter = $DataDir.Substring(0, 2).ToUpperInvariant()
                if ($vol.DeviceID -ne $driveLetter) {
                    continue
                }
            }

            $totalBytes = [long]$vol.Size
            $freeBytes  = [long]$vol.FreeSpace
            $freePct    = if ($totalBytes -gt 0) { [math]::Round($freeBytes / $totalBytes * 100, 1) } else { 0 }
            $volInfo    = "$(Format-Bytes -Bytes $totalBytes) всего, $(Format-Bytes -Bytes $freeBytes) свободно ($freePct%)"

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem "Том $($vol.DeviceID)" -CurrentValue $volInfo))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Тома файловой системы' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: ФАЙЛ ПОДКАЧКИ (SWAP)
# ---------------------------------------------------------------------------

function Get-PagefileRows {
    <#
    .SYNOPSIS
        Собирает данные о файле подкачки Windows.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ФАЙЛ ПОДКАЧКИ (SWAP)'

    try {
        $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue

        if ($pf) {
            foreach ($p in $pf) {
                $totalMB   = $p.AllocatedBaseSize
                $usedMB    = $p.CurrentUsage
                $usedPct   = if ($totalMB -gt 0) { [math]::Round($usedMB / $totalMB * 100, 1) } else { 0 }

                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem "Размер файла подкачки ($($p.Name))" -CurrentValue "$totalMB MB"))
                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem "Использование ($($p.Name))"         -CurrentValue "$usedMB MB ($usedPct%)"))
            }
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Файл подкачки' -CurrentValue 'Не настроен или не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Файл подкачки' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: ВИРТУАЛИЗАЦИЯ
# ---------------------------------------------------------------------------

function Get-VirtualizationRows {
    <#
    .SYNOPSIS
        Определяет тип машины: физическая или виртуальная (Hyper-V, VMware и др.).
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ВИРТУАЛИЗАЦИЯ'

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue

        if ($cs) {
            $manufacturer = $cs.Manufacturer
            $model        = $cs.Model

            # Определяем тип машины по производителю и модели
            $machineType = 'Физический сервер'

            if ($manufacturer -match 'VMware')          { $machineType = 'Виртуальная машина (VMware)' }
            elseif ($manufacturer -match 'Microsoft')   {
                if ($model -match 'Virtual')            { $machineType = 'Виртуальная машина (Hyper-V)' }
            }
            elseif ($model -match 'VirtualBox')         { $machineType = 'Виртуальная машина (VirtualBox)' }
            elseif ($manufacturer -match 'Xen')         { $machineType = 'Виртуальная машина (Xen)' }
            elseif ($manufacturer -match 'QEMU|KVM')    { $machineType = 'Виртуальная машина (KVM/QEMU)' }

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Тип машины'         -CurrentValue $machineType))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Производитель/Модель' -CurrentValue "$manufacturer / $model"))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Тип машины' -CurrentValue 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Тип машины' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: СЕТЕВЫЕ АДАПТЕРЫ
# ---------------------------------------------------------------------------

function Get-NetworkRows {
    <#
    .SYNOPSIS
        Собирает данные об активных сетевых адаптерах.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'СЕТЕВЫЕ АДАПТЕРЫ'

    try {
        # Get-NetAdapter доступен в Windows 8+ / Server 2012+
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' }

        if ($adapters) {
            foreach ($nic in $adapters) {
                $speedStr = if ($nic.LinkSpeed -gt 0) {
                    $speedMbps = [math]::Round($nic.LinkSpeed / 1MB, 0)
                    if ($speedMbps -ge 1000) { '{0} Гбит/с' -f ($speedMbps / 1000) }
                    else                     { "$speedMbps Мбит/с" }
                }
                else {
                    'Н/Д'
                }

                $adapterInfo = "$($nic.InterfaceDescription) | $speedStr | $($nic.Status)"
                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem "Адаптер: $($nic.Name)" -CurrentValue $adapterInfo))
            }
        }
        else {
            throw 'Get-NetAdapter вернул пустой результат или нет активных адаптеров'
        }
    }
    catch {
        # Резерв: Win32_NetworkAdapter
        try {
            $wmiNics = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.NetEnabled -eq $true }

            foreach ($nic in $wmiNics) {
                $speedStr    = if ($nic.Speed) { Format-Bytes -Bytes ([long]$nic.Speed) } else { 'Н/Д' }
                $adapterInfo = "$($nic.Name) | $speedStr"
                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem "Адаптер: $($nic.NetConnectionID)" -CurrentValue $adapterInfo))
            }
        }
        catch {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Сетевые адаптеры' -CurrentValue 'Не удалось получить'))
        }
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: ОПЕРАЦИОННАЯ СИСТЕМА
# ---------------------------------------------------------------------------

function Get-OsInfoRows {
    <#
    .SYNOPSIS
        Собирает версию ОС и время работы системы (uptime).
    #>
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [ref]$Counter
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'ОПЕРАЦИОННАЯ СИСТЕМА'

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

        if ($os) {
            $osVersion = "$($os.Caption) (сборка $($os.BuildNumber))"
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Версия ОС' -CurrentValue $osVersion))

            # Uptime: разница между текущим временем и LastBootUpTime
            $uptime   = (Get-Date) - $os.LastBootUpTime
            $days     = [math]::Floor($uptime.TotalDays)
            $hours    = $uptime.Hours
            $minutes  = $uptime.Minutes
            $uptimeStr = "$days д. $hours ч. $minutes мин."

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Время работы (uptime)' -CurrentValue $uptimeStr))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Версия ОС' -CurrentValue 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Problem 'Версия ОС' -CurrentValue 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Публичная функция
# ---------------------------------------------------------------------------

function Collect-OSData {
    <#
    .SYNOPSIS
        Собирает данные об ОС и оборудовании для диагностики PostgreSQL 1С.

    .DESCRIPTION
        Возвращает массив объектов PSCustomObject с полями:
          N            — порядковый номер (начиная с 200)
          Section      — раздел (русское название)
          Problem      — имя параметра (русское, человекочитаемое)
          Status       — пустая строка (интерпретация не производится)
          CurrentValue — фактическое значение
          Detected     — пустая строка
          Impact       — пустая строка

        Каждая секция завёрнута в try/catch. Ошибки не прерывают выполнение —
        вместо значения будет "Не удалось получить".

    .PARAMETER DataDir
        Директория данных PostgreSQL (PGDATA). Если указана — в секции дисков
        показывается только том, на котором расположена директория данных.
        Если не указана — показываются все тома.

    .OUTPUTS
        PSCustomObject[]

    .EXAMPLE
        $osData = Collect-OSData
        $osData | Format-Table -AutoSize

    .EXAMPLE
        $osData = Collect-OSData -DataDir 'D:\PostgreSQL\data'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter()]
        [string]$DataDir = ''
    )

    Write-Verbose 'Collect-OSData: сбор данных об операционной системе...'

    $allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Счётчик N начинается с 200, чтобы не пересекаться с результатами SQL-диагностики
    $counter = [ref]200

    # --- Оперативная память ---
    Write-Verbose 'Collect-OSData: сбор данных RAM...'
    foreach ($row in (Get-RamRows -Counter $counter)) {
        $allRows.Add($row)
    }

    # --- Процессор ---
    Write-Verbose 'Collect-OSData: сбор данных CPU...'
    foreach ($row in (Get-CpuRows -Counter $counter)) {
        $allRows.Add($row)
    }

    # --- Энергосбережение ---
    Write-Verbose 'Collect-OSData: сбор плана электропитания...'
    foreach ($row in (Get-PowerPlanRows -Counter $counter)) {
        $allRows.Add($row)
    }

    # --- Дисковая подсистема ---
    Write-Verbose 'Collect-OSData: сбор данных о дисках...'
    foreach ($row in (Get-DiskRows -Counter $counter -DataDir $DataDir)) {
        $allRows.Add($row)
    }

    # --- Файл подкачки ---
    Write-Verbose 'Collect-OSData: сбор данных о файле подкачки...'
    foreach ($row in (Get-PagefileRows -Counter $counter)) {
        $allRows.Add($row)
    }

    # --- Виртуализация ---
    Write-Verbose 'Collect-OSData: определение типа виртуализации...'
    foreach ($row in (Get-VirtualizationRows -Counter $counter)) {
        $allRows.Add($row)
    }

    # --- Сетевые адаптеры ---
    Write-Verbose 'Collect-OSData: сбор данных о сетевых адаптерах...'
    foreach ($row in (Get-NetworkRows -Counter $counter)) {
        $allRows.Add($row)
    }

    # --- Операционная система ---
    Write-Verbose 'Collect-OSData: сбор информации об ОС...'
    foreach ($row in (Get-OsInfoRows -Counter $counter)) {
        $allRows.Add($row)
    }

    Write-Verbose "Collect-OSData: собрано строк: $($allRows.Count)."

    return $allRows.ToArray()
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function Collect-OSData
