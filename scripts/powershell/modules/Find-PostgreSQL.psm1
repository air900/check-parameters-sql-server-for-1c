#Requires -Version 5.1
<#
.SYNOPSIS
    Модуль автоматического обнаружения экземпляров PostgreSQL на Windows-сервере.

.DESCRIPTION
    Определяет установленные экземпляры PostgreSQL тремя способами (в порядке приоритета):
    1. Через службы Windows с именем "postgresql*"
    2. Через стандартные пути установки
    3. Через проверку доступности порта 5432 (TCP)

    Используется диагностическими скриптами для серверов 1С:Предприятие.
#>

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

function Get-PortFromConf {
    <#
    .SYNOPSIS
        Извлекает номер порта из файла postgresql.conf.
    #>
    [OutputType([int])]
    param (
        [Parameter(Mandatory)]
        [string]$ConfPath
    )

    if (-not (Test-Path -LiteralPath $ConfPath)) {
        return 5432  # порт по умолчанию
    }

    $line = Select-String -LiteralPath $ConfPath -Pattern '^\s*port\s*=\s*(\d+)' |
        Select-Object -First 1

    if ($line) {
        return [int]($line.Matches[0].Groups[1].Value)
    }

    return 5432
}

function Get-VersionFromPgConfig {
    <#
    .SYNOPSIS
        Определяет версию PostgreSQL через pg_config.exe.
    #>
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$PgConfigPath
    )

    if (-not (Test-Path -LiteralPath $PgConfigPath)) {
        return $null
    }

    try {
        $output = & $PgConfigPath --version 2>$null
        if ($output -match 'PostgreSQL\s+([\d.]+)') {
            return $Matches[1]
        }
    }
    catch {
        # pg_config недоступен или вернул ошибку — версия неизвестна
    }

    return $null
}

function Get-VersionFromPsql {
    <#
    .SYNOPSIS
        Определяет версию PostgreSQL через psql.exe (резервный способ).
    #>
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$PsqlPath
    )

    if (-not (Test-Path -LiteralPath $PsqlPath)) {
        return $null
    }

    try {
        $output = & $PsqlPath --version 2>$null
        if ($output -match '([\d]+\.[\d]+)') {
            return $Matches[1]
        }
    }
    catch {
        # psql недоступен — версия неизвестна
    }

    return $null
}

function Resolve-BinDir {
    <#
    .SYNOPSIS
        Определяет директорию bin PostgreSQL из пути исполняемого файла службы.
    .DESCRIPTION
        ImagePath службы обычно выглядит так:
        "C:\Program Files\PostgreSQL\14\bin\pg_ctl.exe" runservice -N "postgresql-x64-14"
        или просто:
        C:\Program Files\PostgreSQL\14\bin\postgres.exe
    #>
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    # Извлекаем путь к исполняемому файлу:
    # 1. Если путь в кавычках: "C:\path with spaces\pg_ctl.exe" args -> берём содержимое кавычек
    # 2. Если путь без кавычек: ищем первый .exe в строке, чтобы не обрезать по первому пробелу
    if ($ImagePath -match '^"([^"]+)"') {
        $exePath = $Matches[1]
    }
    elseif ($ImagePath -match '^(.+?\.exe)\b') {
        $exePath = $Matches[1]
    }
    else {
        $exePath = $ImagePath
    }

    return Split-Path -Parent $exePath
}

function Find-DataDirFromConf {
    <#
    .SYNOPSIS
        Ищет директорию данных PostgreSQL рядом с bin-директорией.
    #>
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$BinDir
    )

    # Стандартная структура: <base>\bin, <base>\data
    $baseDir = Split-Path -Parent $BinDir
    $dataDir = Join-Path $baseDir 'data'

    if (Test-Path -LiteralPath $dataDir) {
        return $dataDir
    }

    return $null
}

function New-PgInstance {
    <#
    .SYNOPSIS
        Создаёт унифицированный объект с описанием экземпляра PostgreSQL.
    #>
    [OutputType([PSCustomObject])]
    param (
        [string]$ServiceName = $null,
        [string]$Status      = 'Unknown',
        [int]   $Port        = 5432,
        [string]$Version     = $null,
        [string]$Path        = $null,
        [string]$DataDir     = $null
    )

    return [PSCustomObject]@{
        ServiceName = $ServiceName
        Status      = $Status
        Port        = $Port
        Version     = $Version
        Path        = $Path
        DataDir     = $DataDir
    }
}

# ---------------------------------------------------------------------------
# Стратегия 1: Службы Windows
# ---------------------------------------------------------------------------

function Find-PostgreSQLByService {
    <#
    .SYNOPSIS
        Обнаруживает экземпляры PostgreSQL через службы Windows (postgresql*).
    #>
    [OutputType([PSCustomObject[]])]
    param()

    $found = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $services = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue
    }
    catch {
        return $found
    }

    foreach ($svc in $services) {
        $binDir  = $null
        $dataDir = $null
        $port    = 5432
        $version = $null

        # Получаем ImagePath из реестра службы
        $regPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
        $regEntry = Get-ItemProperty -LiteralPath $regPath -Name 'ImagePath' -ErrorAction SilentlyContinue

        if ($regEntry -and $regEntry.ImagePath) {
            $binDir = Resolve-BinDir -ImagePath $regEntry.ImagePath
        }

        if ($binDir) {
            # Версия через pg_config.exe
            $pgConfigPath = Join-Path $binDir 'pg_config.exe'
            $version      = Get-VersionFromPgConfig -PgConfigPath $pgConfigPath

            # Резервно — через psql.exe
            if (-not $version) {
                $psqlPath = Join-Path $binDir 'psql.exe'
                $version  = Get-VersionFromPsql -PsqlPath $psqlPath
            }

            # Директория данных
            $dataDir = Find-DataDirFromConf -BinDir $binDir

            # Порт из postgresql.conf
            if ($dataDir) {
                $confPath = Join-Path $dataDir 'postgresql.conf'
                $port     = Get-PortFromConf -ConfPath $confPath
            }
        }

        $found.Add(
            (New-PgInstance `
                -ServiceName $svc.Name `
                -Status      $svc.Status.ToString() `
                -Port        $port `
                -Version     $version `
                -Path        $binDir `
                -DataDir     $dataDir)
        )
    }

    return $found
}

# ---------------------------------------------------------------------------
# Стратегия 2: Стандартные пути установки
# ---------------------------------------------------------------------------

function Find-PostgreSQLByPath {
    <#
    .SYNOPSIS
        Обнаруживает PostgreSQL по стандартным путям установки на Windows.
    #>
    [OutputType([PSCustomObject[]])]
    param (
        # Пути уже найденных экземпляров (чтобы не дублировать)
        [string[]]$KnownPaths = @()
    )

    $found = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Стандартные директории установки PostgreSQL / PostgresPro на Windows
    $searchRoots = @(
        'C:\Program Files\PostgreSQL',
        'C:\Program Files\PostgresPro',
        'C:\Program Files (x86)\PostgreSQL'
    )

    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        # Внутри корня лежат подпапки по версиям: 14, 15, 16 и т.д.
        $versionDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue

        foreach ($vDir in $versionDirs) {
            $binDir  = Join-Path $vDir.FullName 'bin'
            $psqlExe = Join-Path $binDir 'psql.exe'

            if (-not (Test-Path -LiteralPath $psqlExe)) {
                continue
            }

            # Пропускаем уже найденные через службы
            $normalizedBin = $binDir.TrimEnd('\').ToLowerInvariant()
            $alreadyKnown  = $KnownPaths | Where-Object {
                $_.TrimEnd('\').ToLowerInvariant() -eq $normalizedBin
            }
            if ($alreadyKnown) {
                continue
            }

            $version = Get-VersionFromPgConfig -PgConfigPath (Join-Path $binDir 'pg_config.exe')
            if (-not $version) {
                $version = Get-VersionFromPsql -PsqlPath $psqlExe
            }

            $dataDir = Find-DataDirFromConf -BinDir $binDir
            $port    = 5432

            if ($dataDir) {
                $port = Get-PortFromConf -ConfPath (Join-Path $dataDir 'postgresql.conf')
            }

            $found.Add(
                (New-PgInstance `
                    -ServiceName $null `
                    -Status      'Unknown' `
                    -Port        $port `
                    -Version     $version `
                    -Path        $binDir `
                    -DataDir     $dataDir)
            )
        }
    }

    return $found
}

# ---------------------------------------------------------------------------
# Стратегия 3: Проверка порта (последний резерв)
# ---------------------------------------------------------------------------

function Find-PostgreSQLByPort {
    <#
    .SYNOPSIS
        Проверяет доступность стандартного порта PostgreSQL (5432) на localhost.
        Используется только если другие способы не нашли ни одного экземпляра.
    #>
    [OutputType([PSCustomObject[]])]
    param()

    $found = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $result = Test-NetConnection -ComputerName 'localhost' -Port 5432 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($result -and $result.TcpTestSucceeded) {
            $found.Add(
                (New-PgInstance `
                    -ServiceName $null `
                    -Status      'Running' `
                    -Port        5432 `
                    -Version     $null `
                    -Path        $null `
                    -DataDir     $null)
            )
        }
    }
    catch {
        # Test-NetConnection недоступен или завершился с ошибкой — порт не проверить
    }

    return $found
}

# ---------------------------------------------------------------------------
# Публичная функция
# ---------------------------------------------------------------------------

function Find-PostgreSQL {
    <#
    .SYNOPSIS
        Обнаруживает установленные экземпляры PostgreSQL на локальном Windows-сервере.

    .DESCRIPTION
        Последовательно применяет три стратегии обнаружения:
        1. Службы Windows (postgresql*) — наиболее надёжный способ
        2. Стандартные пути установки — находит неработающие или не зарегистрированные как служба установки
        3. TCP-соединение на порт 5432 — последний резерв

        Возвращает массив объектов с полями:
          ServiceName — имя службы Windows (или $null)
          Status      — состояние службы (Running / Stopped / Unknown)
          Port        — порт PostgreSQL
          Version     — версия PostgreSQL (или $null, если не удалось определить)
          Path        — директория bin (или $null)
          DataDir     — директория данных PGDATA (или $null)

    .OUTPUTS
        PSCustomObject[]

    .EXAMPLE
        $instances = Find-PostgreSQL
        foreach ($pg in $instances) {
            Write-Host "Экземпляр: $($pg.ServiceName), версия: $($pg.Version), порт: $($pg.Port)"
        }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    $allInstances = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Стратегия 1: службы Windows ---
    Write-Verbose 'Find-PostgreSQL: поиск через службы Windows (postgresql*)...'
    $byService = Find-PostgreSQLByService
    foreach ($inst in $byService) {
        $allInstances.Add($inst)
    }

    # --- Стратегия 2: стандартные пути установки ---
    Write-Verbose 'Find-PostgreSQL: поиск по стандартным путям установки...'
    $knownPaths = @($allInstances | Where-Object { $_.Path } | ForEach-Object { $_.Path })
    $byPath     = Find-PostgreSQLByPath -KnownPaths $knownPaths
    foreach ($inst in $byPath) {
        $allInstances.Add($inst)
    }

    # --- Стратегия 3: проверка порта (только если ничего не найдено) ---
    if ($allInstances.Count -eq 0) {
        Write-Verbose 'Find-PostgreSQL: экземпляры не найдены, проверка порта 5432...'
        $byPort = Find-PostgreSQLByPort
        foreach ($inst in $byPort) {
            $allInstances.Add($inst)
        }
    }

    if ($allInstances.Count -eq 0) {
        Write-Verbose 'Find-PostgreSQL: экземпляры PostgreSQL не обнаружены.'
    }
    else {
        Write-Verbose "Find-PostgreSQL: найдено экземпляров: $($allInstances.Count)."
    }

    return $allInstances.ToArray()
}

# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

Export-ModuleMember -Function Find-PostgreSQL
