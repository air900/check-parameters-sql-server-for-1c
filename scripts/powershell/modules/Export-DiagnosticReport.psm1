# ==============================================================================
# Модуль: Export-DiagnosticReport
# ==============================================================================
#
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Сохранение собранных параметров СУБД в автономный HTML-файл.
#   Отчёт содержит информацию о сервере и таблицы параметров по разделам.
#
# Использование:
#   Import-Module .\modules\Export-DiagnosticReport.psm1
#   $path = Export-DiagnosticReport -Results $results -ServerInfo $serverInfo
#
# ==============================================================================

#region Вспомогательные функции

# Экранирует спецсимволы HTML
function ConvertTo-HtmlEscaped {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()][AllowNull()]
        [string]$Text = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# Извлекает свойство объекта по английскому или русскому имени
function Get-RowProperty {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,
        [string]$EnglishName,
        [string]$RussianName
    )

    if ($Row.PSObject.Properties[$EnglishName]) { return [string]$Row.$EnglishName }
    if ($Row.PSObject.Properties[$RussianName]) { return [string]$Row.$RussianName }
    if ($EnglishName -eq 'Problem' -and $Row.PSObject.Properties['Label']) { return [string]$Row.Label }
    if ($EnglishName -eq 'CurrentValue' -and $Row.PSObject.Properties['Display']) { return [string]$Row.Display }
    return ''
}

$script:ReportSizeUnits = @{
    'B' = 'Б'; 'Б' = 'Б'; 'byte' = 'Б'; 'bytes' = 'Б'
    'KB' = 'Кб'; 'KiB' = 'Кб'; 'КБ' = 'Кб'; 'КиБ' = 'Кб'
    'MB' = 'Мб'; 'MiB' = 'Мб'; 'МБ' = 'Мб'; 'МиБ' = 'Мб'
    'GB' = 'Гб'; 'GiB' = 'Гб'; 'ГБ' = 'Гб'; 'ГиБ' = 'Гб'
    'TB' = 'Тб'; 'TiB' = 'Тб'; 'ТБ' = 'Тб'; 'ТиБ' = 'Тб'
}

# Известные числовые параметры размеров в общей таблице pg_settings.
$script:PgSizeSettings = @(
    'autovacuum_work_mem', 'backend_flush_after', 'bgwriter_flush_after', 'checkpoint_flush_after',
    'commit_timestamp_buffers', 'gin_pending_list_limit', 'huge_page_size', 'io_combine_limit',
    'log_rotation_size', 'logical_decoding_work_mem', 'max_slot_wal_keep_size', 'max_stack_depth',
    'min_dynamic_shared_memory', 'min_parallel_index_scan_size', 'min_parallel_table_scan_size',
    'multixact_member_buffers', 'multixact_offset_buffers', 'notify_buffers', 'segment_size',
    'serializable_buffers', 'shared_memory_size', 'subtransaction_buffers', 'temp_file_limit',
    'transaction_buffers', 'vacuum_buffer_usage_limit', 'wal_keep_size', 'wal_skip_threshold',
    'wal_writer_flush_after'
)

function Format-ReportSizeValue {
    param([string]$Text, [string]$Label, [string]$Section, [string]$Database, [switch]$KnownSize)

    $number = '[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?|[0-9]{1,3}(?:\.[0-9]{3})+(?:,[0-9]+)?|[0-9]+(?:[ \u00a0\u202f][0-9]{3})*(?:[.,][0-9]+)?)'
    $unit = '(?:bytes?|[KMGT]i?B|[КМГТ]и?Б|B|Б)'
    $size = "$number\s*$unit"
    $prefix = ''
    $suffix = ''

    if ($Section -in @('all_settings', 'Текущие настройки PostgreSQL')) {
        if ($Label -cnotin $script:PgSizeSettings -or $Text -notmatch "\A$size\z") {
            return $Text
        }
        $KnownSize = $true
    }

    # В этих строках форматируем только часть, которая содержит измерение.
    if ($Label -eq 'База данных') {
        if (-not $Database -or -not $Text.StartsWith("$Database (", [StringComparison]::Ordinal) -or
            -not $Text.EndsWith(')', [StringComparison]::Ordinal)) {
            return $Text
        }
        $prefix = "$Database ("
        $suffix = ')'
    }
    elseif ($Label -match '^(БД$|Имя |Название |Экземпляр|Каталог|Папка|Путь|Пользователь|Логин|Роль)' -or
        $Label -in @('Сервер', 'Хост', 'Таблица', 'Индекс', 'Файл') -or
        $Section -in @('os_net', 'Сетевые интерфейсы')) {
        return $Text
    }
    elseif ($Section -in @('os_disk', 'Диски') -and $Text -match "\A(?<prefix>.+ \| )$size\z") {
        $prefix = $Matches.prefix
    }
    elseif ($Text -match "\A(?<prefix>recovery=\w+ / shrink=\w+ / size=)$size(?<suffix> \([^)]+\) / .+)\z") {
        $prefix = $Matches.prefix
        $suffix = $Matches.suffix
    }
    elseif ($Text -match "\A$size(?<suffix> / мусор: .+)\z" -and
        $Section -in @('bloat', 'Неиспользуемое место в таблицах и индексах')) {
        $suffix = $Matches.suffix
    }
    elseif ($Text -match (
        "\A(?<prefix>[0-9]+ таблиц / (?:[0-9]+ строк / |макс )|(?:включено|выключено) / размер |" +
        "(?:READ_WRITE|READ_ONLY|OFF|ERROR)(?: \([^)]+\))? / (?:capture=\w+ / max |режим сбора запросов \w+ / лимит )|" +
        "Фрагментация $number% / размер )$size\z"
    )) {
        $prefix = $Matches.prefix
    }

    $measurement = $Text.Substring($prefix.Length, $Text.Length - $prefix.Length - $suffix.Length)
    if ($measurement -match "\A$size(?: \((?:$size|$number%)\))?\z") {
        # Обозначение единицы само по себе не отличает размер от имени объекта.
        if (-not ($KnownSize -or $prefix -or $suffix -or $Label -eq 'Физическая память (RAM)' -or
            $Section -in @(
                'memory', 'Память', 'Память и кэш', 'os_ram', 'Оперативная память Windows',
                'wal', 'Журнал транзакций (WAL)', 'metrics', 'Накопленные показатели PostgreSQL',
                'tempdb', 'Временная база tempdb', 'temp_tables', 'Временные таблицы',
                'recovery', 'Восстановление баз данных', 'monitoring', 'Настройки мониторинга',
                'os_disk', 'Диски', 'os_mssql', 'Среда SQL Server', 'os_swap', 'Файл подкачки Windows'
            ))) {
            return $Text
        }
    }
    elseif ($measurement -notmatch "\A$size \(data: $size, idx: $size\)\z" -and
        $measurement -notmatch "\A$size всего, $size свободно \($number%\)\z" -and
        $measurement -notmatch "\A(?:ROWS|LOG) / $size / growth (?:$size|$number%)\z") {
        return $Text
    }

    # Если крупная единица округлилась до нуля, показываем значение из скобок.
    if ($measurement -match "\A0(?:[.,]0+)?\s*(?<large>$unit) \((?<precise>$number\s*(?<small>$unit))\)\z") {
        $units = @('Б', 'Кб', 'Мб', 'Гб', 'Тб')
        $large = $script:ReportSizeUnits[$Matches.large]
        $small = $script:ReportSizeUnits[$Matches.small]
        if ([array]::IndexOf($units, $large) -gt [array]::IndexOf($units, $small)) {
            $measurement = $Matches.precise
        }
    }
    $localized = [regex]::Replace($measurement, "(?<amount>$number)\s*(?<unit>$unit)", {
        param($item)
        '{0} {1}' -f $item.Groups['amount'].Value, $script:ReportSizeUnits[$item.Groups['unit'].Value]
    }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return "$prefix$localized$suffix"
}

# Формирует HTML-блок с информацией о сервере
function Get-ServerInfoHtml {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$ServerInfo
    )

    if ($null -eq $ServerInfo -or $ServerInfo.Count -eq 0) { return '' }

    $labelMap = [ordered]@{
        'pg_version'    = 'Версия PostgreSQL'
        'mssql_version' = 'Версия SQL Server'
        'mssql_edition' = 'Редакция SQL Server'
        'os'         = 'Операционная система'
        'ram'        = 'Оперативная память'
        'cpu_cores'  = 'Логических процессоров'
        'hostname'   = 'Имя сервера'
        'database'   = 'База данных'
    }

    $rows = [System.Text.StringBuilder]::new()

    if ($ServerInfo.ContainsKey('mssql_instance')) {
        $labelMap['mssql_instance'] = 'Экземпляр SQL Server'
        $labelMap['port'] = 'TCP-порт'
    }
    foreach ($key in $labelMap.Keys) {
        if ($key -eq 'port' -and $ServerInfo[$key] -like 'instance:*') { continue }
        if ($ServerInfo.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($ServerInfo[$key])) {
            $label = ConvertTo-HtmlEscaped -Text $labelMap[$key]
            $display = [string]$ServerInfo[$key]
            if ($key -eq 'ram') { $display = Format-ReportSizeValue -Text $display -KnownSize }
            $value = ConvertTo-HtmlEscaped -Text $display
            [void]$rows.AppendLine("            <tr><td class=""info-label"">$label</td><td>$value</td></tr>")
        }
    }

    # Дополнительные ключи (не из стандартного списка)
    foreach ($key in $ServerInfo.Keys) {
        if (-not $labelMap.Contains($key) -and -not [string]::IsNullOrWhiteSpace($ServerInfo[$key])) {
            $label = ConvertTo-HtmlEscaped -Text $key
            $value = ConvertTo-HtmlEscaped -Text ([string]$ServerInfo[$key])
            [void]$rows.AppendLine("            <tr><td class=""info-label"">$label</td><td>$value</td></tr>")
        }
    }

    if ($rows.Length -eq 0) { return '' }

    return @"
    <div class="server-info">
        <table class="info-table">
$($rows.ToString().TrimEnd())
        </table>
    </div>
"@
}

#endregion

#region Основная экспортируемая функция

<#
.SYNOPSIS
    Сохраняет собранные параметры СУБД в автономный HTML-файл.

.DESCRIPTION
    Принимает массив объектов с данными и хештаблицу с информацией о сервере,
    генерирует HTML-отчёт с таблицами параметров по разделам. Отчёт не зависит
    от внешних ресурсов (все стили встроены).

.PARAMETER Results
    Массив PSCustomObject со свойствами:
        Section / Раздел     — название раздела
        Problem / Label      — название параметра
        CurrentValue / Display — текущее значение

.PARAMETER ServerInfo
    Хештаблица с информацией о сервере (pg_version, os, ram, cpu_cores и др.)

.PARAMETER OutputPath
    Путь для сохранения HTML. По умолчанию имя файла на рабочем столе включает тип СУБД.

.OUTPUTS
    [string] Полный путь к сохранённому файлу.

.EXAMPLE
    $path = Export-DiagnosticReport -Results $results -ServerInfo $serverInfo
#>
function Export-DiagnosticReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory = $false)]
        [hashtable]$ServerInfo,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    $isMssql = $ServerInfo -and $ServerInfo.ContainsKey('mssql_instance')
    $engineName = if ($isMssql) { 'MS SQL Server' } else { 'PostgreSQL' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $fileName = if ($isMssql) { '1c-mssql-diagnostic.html' } else { '1c-postgresql-diagnostic.html' }
        $OutputPath = Join-Path -Path $desktopPath -ChildPath $fileName
    }

    # --- 2. Группировка по разделам ---
    $sections = [System.Collections.Specialized.OrderedDictionary]::new()

    foreach ($row in $Results) {
        $section = Get-RowProperty -Row $row -EnglishName 'Section' -RussianName 'Раздел'
        if ([string]::IsNullOrWhiteSpace($section)) { $section = 'Прочее' }

        if (-not $sections.Contains($section)) {
            $sections[$section] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$sections[$section].Add($row)
    }

    $reportDate = (Get-Date).ToString('dd.MM.yyyy HH:mm')
    $serverInfoHtml = Get-ServerInfoHtml -ServerInfo $ServerInfo
    $databaseName = if ($ServerInfo) { [string]$ServerInfo['database'] }

    # --- 3. Сборка таблиц по секциям ---
    $allSectionsHtml = [System.Text.StringBuilder]::new()

    foreach ($sectionName in $sections.Keys) {
        $sectionNameHtml = ConvertTo-HtmlEscaped -Text $sectionName

        [void]$allSectionsHtml.AppendLine("        <div class=""section-group"">")
        [void]$allSectionsHtml.AppendLine("            <h2 class=""section-title"">$sectionNameHtml</h2>")
        [void]$allSectionsHtml.AppendLine("            <table class=""params-table"">")

        foreach ($row in $sections[$sectionName]) {
            $problem      = Get-RowProperty -Row $row -EnglishName 'Problem'      -RussianName 'Проблема'
            $currentValue = Get-RowProperty -Row $row -EnglishName 'CurrentValue' -RussianName 'Текущее значение'

            if ([string]::IsNullOrWhiteSpace($problem) -and [string]::IsNullOrWhiteSpace($currentValue)) {
                continue
            }

            $problemHtml = ConvertTo-HtmlEscaped -Text $problem
            $valueDisplay = Format-ReportSizeValue -Text $currentValue -Label $problem -Section $sectionName -Database $databaseName
            $valueHtml = ConvertTo-HtmlEscaped -Text $valueDisplay

            [void]$allSectionsHtml.AppendLine("                <tr><td class=""param-name"">$problemHtml</td><td class=""param-value"">$valueHtml</td></tr>")
        }

        [void]$allSectionsHtml.AppendLine("            </table>")
        [void]$allSectionsHtml.AppendLine("        </div>")
    }

    # --- 4. Итоговый HTML ---
    $html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Сводка сбора данных $engineName для 1С:Предприятия</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; font-size: 14px; color: #2c3e50; background: #f4f6f9; line-height: 1.5; }
        .report-header { background: linear-gradient(135deg, #1a73e8 0%, #0d47a1 100%); color: #fff; padding: 32px 40px 24px; }
        .report-title { font-size: 26px; font-weight: 600; margin-bottom: 4px; }
        .report-subtitle { font-size: 13px; opacity: 0.85; }
        .server-info { background: #fff; border-bottom: 1px solid #e0e0e0; padding: 16px 40px; }
        .info-table { border-collapse: collapse; width: auto; }
        .info-table td { padding: 3px 16px 3px 0; font-size: 13px; }
        .info-label { color: #666; white-space: nowrap; }
        .data-summary { font-size: 1.1em; color: #555; padding: 16px 40px; }
        .results-section { padding: 8px 40px 32px; }
        .section-group { margin-top: 20px; }
        .section-title { font-size: 1em; color: #2980b9; border-bottom: 2px solid #2980b9; padding: 8px 0 4px 0; margin: 0; }
        .params-table { width: 100%; border-collapse: collapse; margin: 0 0 8px 0; }
        .params-table tr:nth-child(even) { background: #f8f9fa; }
        .params-table td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 0.9em; }
        .param-name { color: #555; width: 45%; }
        .param-value { color: #2c3e50; font-weight: 600; font-family: 'Consolas', 'Courier New', monospace; }
        .report-footer { background: #2c3e50; color: #ecf0f1; text-align: center; padding: 20px 40px; font-size: 13px; }
        .report-footer a { color: #3498db; text-decoration: none; }
        .report-footer a:hover { text-decoration: underline; }
        @media print { body { background: #fff; } .report-header { background: #1a73e8 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; } }
    </style>
</head>
<body>

    <header class="report-header">
        <h1 class="report-title">Сводка сбора данных $engineName для 1С:Предприятия</h1>
        <div class="report-subtitle">Сформировано $reportDate</div>
    </header>

$serverInfoHtml

    <div class="data-summary">
        <p>Для оценки настроек отправьте собранные данные на анализ из консоли диагностики.</p>
        <p>Собрано записей: <strong>$($Results.Count)</strong></p>
    </div>

    <section class="results-section">
$($allSectionsHtml.ToString().TrimEnd())
    </section>

    <footer class="report-footer">
        <p>Вопросы по сбору данных — <a href="https://audit-reshenie.ru" target="_blank">audit-reshenie.ru</a> | <a href="mailto:info@audit-reshenie.ru">info@audit-reshenie.ru</a></p>
    </footer>

</body>
</html>
"@

    # --- 5. Сохранение ---
    $outputDir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -Path $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8Bom)

    Write-Verbose "HTML-отчёт сохранён: $OutputPath"
    return $OutputPath
}

#endregion

Export-ModuleMember -Function Export-DiagnosticReport
