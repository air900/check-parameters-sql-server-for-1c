#Requires -Version 5.1
<#
.SYNOPSIS
    Модуль сбора данных об операционной системе Windows для диагностики PostgreSQL 1С.

.DESCRIPTION
    Собирает фактические параметры ОС и оборудования: RAM, CPU, диски, сеть,
    план электропитания, файл подкачки, виртуализацию и версию ОС.

    Формат v2: каждая строка содержит Key (machine-readable), Value (числовое/boolean),
    Display (человекочитаемое), Section (machine-readable), Label (описание).

    Каждая секция завёрнута в try/catch для устойчивости к ошибкам доступа.
#>

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

function New-OsRow {
    <#
    .SYNOPSIS
        Создаёт строку результата в формате v2 (key/value/display).
    #>
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [int]$N,

        [Parameter(Mandatory)]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Display,

        [Parameter()]
        [string]$Value = ''
    )

    return [PSCustomObject]@{
        N            = $N
        Section      = $Section
        Key          = $Key
        Problem      = $Label       # Для совместимости с Show-DiagnosticResults
        CurrentValue = $Display     # Для совместимости с Show-DiagnosticResults
        Value        = $Value       # Машиночитаемое значение для rule engine
        Status       = ''
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
# Секция: os_ram — Оперативная память
# ---------------------------------------------------------------------------

function Get-RamRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_ram'

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

        if ($cs -and $os) {
            $totalBytes = $cs.TotalPhysicalMemory
            $freeBytes  = $os.FreePhysicalMemory * 1KB
            $usedBytes  = $totalBytes - $freeBytes
            $usedPct    = if ($totalBytes -gt 0) { [math]::Round($usedBytes / $totalBytes * 100, 1) } else { 0 }

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_ram_total'     -Label 'Общий объём RAM'    -Display (Format-Bytes -Bytes $totalBytes) -Value "$totalBytes"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_ram_available'  -Label 'Доступная RAM'      -Display (Format-Bytes -Bytes $freeBytes)  -Value "$freeBytes"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_ram_used_pct'   -Label 'Использование RAM'  -Display "$usedPct%"                      -Value "$usedPct"))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_ram_total' -Label 'Общий объём RAM' -Display 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_ram_total' -Label 'Общий объём RAM' -Display 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_cpu — Процессор
# ---------------------------------------------------------------------------

function Get-CpuRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_cpu'

    try {
        $cpus = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue

        if ($cpus) {
            $cpuArray     = @($cpus)
            $totalCores   = ($cpuArray | Measure-Object -Property NumberOfCores -Sum).Sum
            $totalLogical = ($cpuArray | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            $sockets      = $cpuArray.Count
            $cpuName      = $cpuArray[0].Name -replace '\s+', ' '
            $htEnabled    = $totalLogical -gt $totalCores

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_model'         -Label 'Модель процессора'        -Display $cpuName          -Value $cpuName))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_cores'         -Label 'Физических ядер'          -Display "$totalCores"     -Value "$totalCores"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_logical'       -Label 'Логических процессоров'   -Display "$totalLogical"   -Value "$totalLogical"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_sockets'       -Label 'Количество сокетов'       -Display "$sockets"        -Value "$sockets"))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_hyperthreading' -Label 'Hyperthreading'           -Display $(if ($htEnabled) { 'Включён' } else { 'Выключен' }) -Value $(if ($htEnabled) { 'true' } else { 'false' })))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_model' -Label 'Модель процессора' -Display 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_cpu_model' -Label 'Модель процессора' -Display 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_power — Энергосбережение
# ---------------------------------------------------------------------------

function Get-PowerPlanRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_power'

    try {
        # & powercfg + Out-String: захват в scalar (см. Find-MSSQL § 5).
        # `-match` на string[] фильтрует элементы и НЕ заполняет $Matches —
        # если опираться на $Matches[1], он окажется пустым.
        $rawOut   = & powercfg /getactivescheme 2>&1 | Out-String
        $planName = 'Не удалось определить'

        # Имя плана извлекаем из последних круглых скобок строки активной схемы:
        # "Power Scheme GUID: <uuid>  (High performance)"
        $nameMatch = [regex]::Match($rawOut, '\(([^)]+)\)\s*\r?\n?\s*$')
        if ($nameMatch.Success) {
            $planName = $nameMatch.Groups[1].Value.Trim()
        }

        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_power_plan' -Label 'Текущий план электропитания' -Display $planName -Value $planName))
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_power_plan' -Label 'Текущий план электропитания' -Display 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_disk — Дисковая подсистема
# ---------------------------------------------------------------------------

function Get-DiskRows {
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)] [ref]$Counter,
        [string]$DataDir = ''
    )

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_disk'

    # --- Физические диски ---
    try {
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue

        if ($physDisks) {
            $diskIdx = 0
            foreach ($disk in $physDisks) {
                $mediaType = switch ($disk.MediaType) {
                    'SSD'         { 'SSD' }
                    'HDD'         { 'HDD' }
                    'SCM'         { 'NVMe/SCM' }
                    'Unspecified' { 'Unknown' }
                    default       { $disk.MediaType }
                }

                if ($mediaType -in @('Unknown', 'SSD')) {
                    if ($disk.FriendlyName -match 'NVMe' -or $disk.BusType -eq 'NVMe') {
                        $mediaType = 'NVMe'
                    }
                }

                $sizeStr  = Format-Bytes -Bytes $disk.Size
                $diskInfo = "$($disk.FriendlyName) | $mediaType | $sizeStr"

                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key "os_disk_phys_$diskIdx" -Label "Физический диск $diskIdx" -Display $diskInfo -Value "$($disk.Size)"))
                $diskIdx++
            }
        }
        else {
            throw 'Get-PhysicalDisk вернул пустой результат'
        }
    }
    catch {
        try {
            $wmiDisks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue
            $diskIdx  = 0

            foreach ($disk in $wmiDisks) {
                $sizeStr  = if ($disk.Size) { Format-Bytes -Bytes ([long]$disk.Size) } else { 'Н/Д' }
                $diskInfo = "$($disk.Model) | $sizeStr"

                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key "os_disk_phys_$diskIdx" -Label "Физический диск $diskIdx" -Display $diskInfo -Value "$(if ($disk.Size) { $disk.Size } else { '' })"))
                $diskIdx++
            }
        }
        catch {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_disk_phys_0' -Label 'Физические диски' -Display 'Не удалось получить'))
        }
    }

    # --- Тома файловой системы ---
    try {
        $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue

        foreach ($vol in $volumes) {
            if ($DataDir -ne '') {
                $driveLetter = $DataDir.Substring(0, 2).ToUpperInvariant()
                if ($vol.DeviceID -ne $driveLetter) { continue }
            }

            $totalBytes = [long]$vol.Size
            $freeBytes  = [long]$vol.FreeSpace
            $freePct    = if ($totalBytes -gt 0) { [math]::Round($freeBytes / $totalBytes * 100, 1) } else { 0 }
            $volInfo    = "$(Format-Bytes -Bytes $totalBytes) всего, $(Format-Bytes -Bytes $freeBytes) свободно ($freePct%)"
            $volKey     = 'os_disk_vol_' + ($vol.DeviceID -replace ':', '').ToLower()

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key $volKey -Label "Том $($vol.DeviceID)" -Display $volInfo -Value "$freeBytes"))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_disk_vol_c' -Label 'Тома файловой системы' -Display 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_swap — Файл подкачки
# ---------------------------------------------------------------------------

function Get-PagefileRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_swap'

    try {
        $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue

        if ($pf) {
            $pfIdx = 0
            foreach ($p in $pf) {
                $totalMB = $p.AllocatedBaseSize
                $usedMB  = $p.CurrentUsage
                $usedPct = if ($totalMB -gt 0) { [math]::Round($usedMB / $totalMB * 100, 1) } else { 0 }

                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key "os_swap_size_$pfIdx"  -Label "Размер файла подкачки ($($p.Name))" -Display "$totalMB MB" -Value "$($totalMB * 1MB)"))
                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key "os_swap_used_$pfIdx"  -Label "Использование ($($p.Name))"         -Display "$usedMB MB ($usedPct%)" -Value "$($usedMB * 1MB)"))
                $pfIdx++
            }
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_swap_size_0' -Label 'Файл подкачки' -Display 'Не настроен'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_swap_size_0' -Label 'Файл подкачки' -Display 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_virt — Виртуализация
# ---------------------------------------------------------------------------

function Get-VirtualizationRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_virt'

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue

        if ($cs) {
            $manufacturer = $cs.Manufacturer
            $model        = $cs.Model

            # Определяем тип — machine-readable
            $vmType = 'physical'
            $vmDisplay = 'Физический сервер'

            if ($manufacturer -match 'VMware')          { $vmType = 'vmware';     $vmDisplay = 'Виртуальная машина (VMware)' }
            elseif ($manufacturer -match 'Microsoft')   {
                if ($model -match 'Virtual')            { $vmType = 'hyperv';     $vmDisplay = 'Виртуальная машина (Hyper-V)' }
            }
            elseif ($model -match 'VirtualBox')         { $vmType = 'virtualbox'; $vmDisplay = 'Виртуальная машина (VirtualBox)' }
            elseif ($manufacturer -match 'Xen')         { $vmType = 'xen';        $vmDisplay = 'Виртуальная машина (Xen)' }
            elseif ($manufacturer -match 'QEMU|KVM')    { $vmType = 'kvm';        $vmDisplay = 'Виртуальная машина (KVM/QEMU)' }

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_virt_type'   -Label 'Тип машины'          -Display $vmDisplay                    -Value $vmType))
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_virt_vendor' -Label 'Производитель/Модель' -Display "$manufacturer / $model"      -Value $manufacturer))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_virt_type' -Label 'Тип машины' -Display 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_virt_type' -Label 'Тип машины' -Display 'Не удалось получить'))
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_net — Сетевые адаптеры
# ---------------------------------------------------------------------------

function Get-NetworkRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_net'

    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

        if ($adapters) {
            $nicIdx = 0
            foreach ($nic in $adapters) {
                $speedDisplay = if ($nic.LinkSpeed -gt 0) {
                    $speedMbps = [math]::Round($nic.LinkSpeed / 1MB, 0)
                    if ($speedMbps -ge 1000) { '{0} Гбит/с' -f ($speedMbps / 1000) } else { "$speedMbps Мбит/с" }
                } else { 'Н/Д' }

                $adapterInfo = "$($nic.InterfaceDescription) | $speedDisplay"
                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key "os_net_adapter_$nicIdx" -Label "Адаптер: $($nic.Name)" -Display $adapterInfo -Value "$($nic.LinkSpeed)"))
                $nicIdx++
            }
        }
        else { throw 'Нет активных адаптеров' }
    }
    catch {
        try {
            $wmiNics = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.NetEnabled -eq $true }
            $nicIdx  = 0
            foreach ($nic in $wmiNics) {
                $speedStr    = if ($nic.Speed) { Format-Bytes -Bytes ([long]$nic.Speed) } else { 'Н/Д' }
                $adapterInfo = "$($nic.Name) | $speedStr"
                $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key "os_net_adapter_$nicIdx" -Label "Адаптер: $($nic.NetConnectionID)" -Display $adapterInfo -Value "$(if ($nic.Speed) { $nic.Speed } else { '' })"))
                $nicIdx++
            }
        }
        catch {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_net_adapter_0' -Label 'Сетевые адаптеры' -Display 'Не удалось получить'))
        }
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Секция: os_info — Операционная система
# ---------------------------------------------------------------------------

function Get-OsInfoRows {
    [OutputType([PSCustomObject[]])]
    param ([Parameter(Mandatory)] [ref]$Counter)

    $rows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $section = 'os_info'

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

        if ($os) {
            $osVersion = "$($os.Caption) (сборка $($os.BuildNumber))"
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_version' -Label 'Версия ОС' -Display $osVersion -Value $os.BuildNumber))

            $uptime    = (Get-Date) - $os.LastBootUpTime
            $uptimeSec = [math]::Floor($uptime.TotalSeconds)
            $days      = [math]::Floor($uptime.TotalDays)
            $hours     = $uptime.Hours
            $minutes   = $uptime.Minutes

            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_uptime' -Label 'Время работы (uptime)' -Display "$days д. $hours ч. $minutes мин." -Value "$uptimeSec"))
        }
        else {
            $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_version' -Label 'Версия ОС' -Display 'Не удалось получить'))
        }
    }
    catch {
        $rows.Add((New-OsRow -N ($Counter.Value++) -Section $section -Key 'os_version' -Label 'Версия ОС' -Display 'Не удалось получить'))
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
        Формат v2: каждая строка содержит Key (machine-readable), Value (числовое/boolean),
        Display (человекочитаемое), Section (machine-readable), Label (описание).

        Секции:
          os_ram   — оперативная память (total, available, used_pct)
          os_cpu   — процессор (model, cores, logical, sockets, hyperthreading)
          os_power — план электропитания
          os_disk  — физические диски и тома
          os_swap  — файл подкачки
          os_virt  — виртуализация (type, vendor)
          os_net   — сетевые адаптеры
          os_info  — версия ОС, uptime

    .PARAMETER DataDir
        Директория данных PostgreSQL (PGDATA). Если указана — в секции дисков
        показывается только том, на котором расположена директория данных.

    .OUTPUTS
        PSCustomObject[]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter()]
        [string]$DataDir = ''
    )

    $allRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $counter = [ref]200

    foreach ($row in (Get-RamRows            -Counter $counter))                   { $allRows.Add($row) }
    foreach ($row in (Get-CpuRows            -Counter $counter))                   { $allRows.Add($row) }
    foreach ($row in (Get-PowerPlanRows       -Counter $counter))                   { $allRows.Add($row) }
    foreach ($row in (Get-DiskRows           -Counter $counter -DataDir $DataDir))  { $allRows.Add($row) }
    foreach ($row in (Get-PagefileRows        -Counter $counter))                   { $allRows.Add($row) }
    foreach ($row in (Get-VirtualizationRows  -Counter $counter))                   { $allRows.Add($row) }
    foreach ($row in (Get-NetworkRows         -Counter $counter))                   { $allRows.Add($row) }
    foreach ($row in (Get-OsInfoRows          -Counter $counter))                   { $allRows.Add($row) }

    return $allRows.ToArray()
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function Collect-OSData
