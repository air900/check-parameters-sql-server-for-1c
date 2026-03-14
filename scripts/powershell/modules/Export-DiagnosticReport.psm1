# ==============================================================================
# Модуль: Export-DiagnosticReport
# ==============================================================================
#
# Версия:       1.0
# Дата:         2026-03-14
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Сохраняет результаты диагностики PostgreSQL в виде автономного HTML-файла
#   и открывает его в браузере.
#
# Использование:
#   Import-Module .\modules\Export-DiagnosticReport.psm1
#   $path = Export-DiagnosticReport -Results $diagnosticResults -ServerInfo $info
#
# ==============================================================================

#region Вспомогательные функции

# Возвращает CSS-класс строки по значению поля Status
function Get-HtmlStatusClass {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    if ($Status -match '🔴' -or $Status -match 'CRITICAL|КРИТИЧНО') {
        return 'critical'
    }
    elseif ($Status -match '🟡' -or $Status -match 'WARNING|ВАЖНО') {
        return 'warning'
    }
    elseif ($Status -match '🟢' -or $Status -match '^OK$|НОРМА') {
        return 'ok'
    }

    # ⚪ NOT CHECKED и прочие
    return 'not-checked'
}

# Определяет категорию статуса для подсчёта в сводке
# Возвращает: 'Critical', 'Warning', 'Ok', 'NotChecked' или $null
function Get-HtmlStatusCategory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    if ([string]::IsNullOrWhiteSpace($Status)) {
        return $null
    }

    if ($Status -match '🔴' -or $Status -match 'CRITICAL|КРИТИЧНО') {
        return 'Critical'
    }
    elseif ($Status -match '🟡' -or $Status -match 'WARNING|ВАЖНО') {
        return 'Warning'
    }
    elseif ($Status -match '🟢' -or $Status -match '^OK$|НОРМА') {
        return 'Ok'
    }
    elseif ($Status -match '⚪' -or $Status -match 'NOT CHECKED|НЕ ПРОВЕРЕНО') {
        return 'NotChecked'
    }

    return $null
}

# Экранирует спецсимволы HTML: <, >, &, "
function ConvertTo-HtmlEscaped {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    return $Text `
        -replace '&',  '&amp;'  `
        -replace '<',  '&lt;'   `
        -replace '>',  '&gt;'   `
        -replace '"',  '&quot;'
}

# Извлекает значение свойства из PSCustomObject, поддерживая
# оба варианта имён: английский (Section) и русский (Раздел).
function Get-RowProperty {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [Parameter(Mandatory = $true)]
        [string]$EnglishName,

        [Parameter(Mandatory = $true)]
        [string]$RussianName
    )

    if ($Row.PSObject.Properties[$EnglishName]) {
        return [string]$Row.$EnglishName
    }
    elseif ($Row.PSObject.Properties[$RussianName]) {
        return [string]$Row.$RussianName
    }

    return ''
}

# Формирует HTML-блок карточки сводки (CRITICAL / WARNING / OK / NOT CHECKED)
function Get-SummaryCardHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CssClass,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Emoji,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    return @"
        <div class="summary-card $CssClass">
            <div class="summary-count">$Count</div>
            <div class="summary-label">$Emoji $Label</div>
        </div>
"@
}

# Формирует HTML-блок одного результата диагностики
function Get-FindingHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusClass,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Status = '',

        [Parameter(Mandatory = $true)]
        [string]$Problem,

        [Parameter(Mandatory = $false)]
        [string]$CurrentValue,

        [Parameter(Mandatory = $false)]
        [string]$Detected,

        [Parameter(Mandatory = $false)]
        [string]$Impact
    )

    $statusHtml       = ConvertTo-HtmlEscaped -Text $Status
    $problemHtml      = ConvertTo-HtmlEscaped -Text $Problem
    $currentValueHtml = ConvertTo-HtmlEscaped -Text $CurrentValue
    $detectedHtml     = ConvertTo-HtmlEscaped -Text $Detected
    $impactHtml       = ConvertTo-HtmlEscaped -Text $Impact

    # Дополнительные поля — только если не пустые
    $currentValueBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($currentValueHtml)) {
        $currentValueBlock = @"
            <div class="finding-meta">
                <span class="meta-label">Текущее значение:</span>
                <span class="meta-value">$currentValueHtml</span>
            </div>
"@
    }

    $detectedBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($detectedHtml)) {
        $detectedBlock = @"
            <div class="finding-meta">
                <span class="meta-label">Обнаружено:</span>
                <span class="meta-value">$detectedHtml</span>
            </div>
"@
    }

    # Влияние — только для CRITICAL и WARNING
    $impactBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($impactHtml) -and $StatusClass -in 'critical', 'warning') {
        $impactBlock = @"
            <div class="finding-impact $StatusClass-impact">
                <span class="meta-label">Влияние на 1С:</span>
                <span class="meta-value">$impactHtml</span>
            </div>
"@
    }

    return @"
        <div class="finding $StatusClass">
            <div class="finding-header">
                <span class="finding-status">$statusHtml</span>
                <span class="finding-title">$problemHtml</span>
            </div>
            $currentValueBlock
            $detectedBlock
            $impactBlock
        </div>
"@
}

# Формирует строки HTML с информацией о сервере из хештаблицы ServerInfo
function Get-ServerInfoHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$ServerInfo
    )

    if ($null -eq $ServerInfo -or $ServerInfo.Count -eq 0) {
        return ''
    }

    # Сопоставление ключей хештаблицы с русскоязычными метками
    $labelMap = [ordered]@{
        'pg_version' = 'Версия PostgreSQL'
        'os'         = 'Операционная система'
        'ram'        = 'Оперативная память'
        'cpu_cores'  = 'Процессорных ядер'
    }

    $rows = [System.Text.StringBuilder]::new()

    foreach ($key in $labelMap.Keys) {
        if ($ServerInfo.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($ServerInfo[$key])) {
            $label = ConvertTo-HtmlEscaped -Text $labelMap[$key]
            $value = ConvertTo-HtmlEscaped -Text ([string]$ServerInfo[$key])
            [void]$rows.AppendLine("            <tr><td class=""info-label"">$label</td><td>$value</td></tr>")
        }
    }

    # Добавляем неизвестные ключи (не из стандартного списка)
    foreach ($key in $ServerInfo.Keys) {
        if (-not $labelMap.Contains($key) -and -not [string]::IsNullOrWhiteSpace($ServerInfo[$key])) {
            $label = ConvertTo-HtmlEscaped -Text $key
            $value = ConvertTo-HtmlEscaped -Text ([string]$ServerInfo[$key])
            [void]$rows.AppendLine("            <tr><td class=""info-label"">$label</td><td>$value</td></tr>")
        }
    }

    if ($rows.Length -eq 0) {
        return ''
    }

    return @"
    <div class="server-info">
        <table class="info-table">
$($rows.ToString().TrimEnd())
        </table>
    </div>
"@
}

# Возвращает встроенный CSS для HTML-отчёта
function Get-ReportCss {
    [OutputType([string])]
    param()

    return @'
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            font-size: 14px;
            color: #2c3e50;
            background-color: #f4f6f9;
            line-height: 1.5;
        }

        /* ---- Шапка ---- */
        .report-header {
            background: linear-gradient(135deg, #1a73e8 0%, #0d47a1 100%);
            color: #ffffff;
            padding: 32px 40px 24px;
        }

        .report-title {
            font-size: 26px;
            font-weight: 600;
            margin-bottom: 4px;
        }

        .report-subtitle {
            font-size: 13px;
            opacity: 0.85;
        }

        /* ---- Информация о сервере ---- */
        .server-info {
            background: #ffffff;
            border-bottom: 1px solid #e0e0e0;
            padding: 16px 40px;
        }

        .info-table {
            border-collapse: collapse;
            width: auto;
        }

        .info-table td {
            padding: 3px 16px 3px 0;
            font-size: 13px;
        }

        .info-label {
            color: #666;
            white-space: nowrap;
        }

        /* ---- Карточки сводки ---- */
        .summary-section {
            padding: 24px 40px 8px;
        }

        .summary-cards {
            display: flex;
            flex-wrap: wrap;
            gap: 16px;
        }

        .summary-card {
            border-radius: 10px;
            padding: 18px 28px;
            min-width: 140px;
            text-align: center;
            color: #ffffff;
        }

        .summary-count {
            font-size: 36px;
            font-weight: 700;
            line-height: 1.1;
        }

        .summary-label {
            font-size: 13px;
            margin-top: 4px;
            opacity: 0.95;
        }

        .summary-card.critical  { background: #c0392b; }
        .summary-card.warning   { background: #e67e22; }
        .summary-card.info      { background: #2980b9; }
        .summary-card.ok        { background: #27ae60; }

        /* ---- Секции результатов ---- */
        .results-section {
            padding: 8px 40px 32px;
        }

        .section-group {
            margin-top: 24px;
        }

        .section-title {
            font-size: 16px;
            font-weight: 600;
            color: #1a73e8;
            padding: 8px 0 8px 0;
            border-bottom: 2px solid #1a73e8;
            margin-bottom: 12px;
        }

        /* ---- Карточка результата ---- */
        .finding {
            background: #ffffff;
            border-radius: 6px;
            border-left: 5px solid #bdc3c7;
            padding: 12px 16px;
            margin-bottom: 8px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.06);
        }

        .finding.critical   { border-left-color: #c0392b; }
        .finding.warning    { border-left-color: #e67e22; }
        .finding.ok         { border-left-color: #27ae60; }
        .finding.not-checked { border-left-color: #95a5a6; }

        .finding-header {
            display: flex;
            align-items: baseline;
            gap: 10px;
            margin-bottom: 4px;
        }

        .finding-status {
            font-size: 12px;
            font-weight: 600;
            white-space: nowrap;
            min-width: 140px;
        }

        .finding.critical   .finding-status { color: #c0392b; }
        .finding.warning    .finding-status { color: #e67e22; }
        .finding.ok         .finding-status { color: #27ae60; }
        .finding.not-checked .finding-status { color: #95a5a6; }

        .finding-title {
            font-weight: 500;
            color: #2c3e50;
        }

        .finding-meta {
            display: flex;
            gap: 6px;
            margin-top: 4px;
            font-size: 12.5px;
        }

        .meta-label {
            color: #888;
            white-space: nowrap;
        }

        .meta-value {
            color: #444;
        }

        .finding-impact {
            margin-top: 6px;
            padding: 6px 10px;
            border-radius: 4px;
            font-size: 12.5px;
            display: flex;
            gap: 6px;
        }

        .critical-impact { background: #fdecea; }
        .warning-impact  { background: #fef3e2; }

        /* ---- Подвал ---- */
        .report-footer {
            background: #2c3e50;
            color: #ecf0f1;
            text-align: center;
            padding: 20px 40px;
            font-size: 13px;
        }

        .report-footer a {
            color: #3498db;
            text-decoration: none;
        }

        .report-footer a:hover {
            text-decoration: underline;
        }

        /* ---- Печать ---- */
        @media print {
            body { background: #ffffff; }

            .report-header {
                background: #1a73e8 !important;
                -webkit-print-color-adjust: exact;
                print-color-adjust: exact;
            }

            .summary-card {
                -webkit-print-color-adjust: exact;
                print-color-adjust: exact;
            }

            .finding {
                page-break-inside: avoid;
                box-shadow: none;
            }
        }
'@
}

#endregion

#region Основная экспортируемая функция

<#
.SYNOPSIS
    Сохраняет результаты диагностики PostgreSQL в автономный HTML-файл.

.DESCRIPTION
    Принимает массив объектов диагностики и хештаблицу с информацией о сервере,
    генерирует профессиональный HTML-отчёт с группировкой по разделам, цветовой
    индикацией серьёзности и сводной статистикой. Отчёт не зависит от внешних
    ресурсов (все стили встроены).

.PARAMETER Results
    Массив PSCustomObject со свойствами (английские или русские имена):
        N / (нет рус.)          — порядковый номер
        Section / Раздел        — название раздела (группировка)
        Problem / Проблема      — название проверки / проблемы
        Status / Состояние      — статус: 🔴 CRITICAL / 🟡 WARNING / 🟢 OK / ⚪ NOT CHECKED
        CurrentValue / Текущее значение — текущее значение параметра
        Detected / Обнаружено   — подробное описание обнаруженного
        Impact / Влияние на работу 1С — влияние на работу системы

.PARAMETER ServerInfo
    Хештаблица с информацией о сервере. Поддерживаемые ключи:
        pg_version — версия PostgreSQL
        os         — операционная система
        ram        — объём оперативной памяти
        cpu_cores  — количество процессорных ядер
    Любые другие ключи также будут отображены.

.PARAMETER OutputPath
    Полный путь для сохранения HTML-файла.
    По умолчанию: Рабочий стол пользователя\1c-postgresql-diagnostic.html

.OUTPUTS
    [string] Полный путь к сохранённому HTML-файлу.

.EXAMPLE
    $results = Invoke-SqlDiagnostic -Database 'my1cdb' -Password 'secret'
    $path = Export-DiagnosticReport -Results $results
    Write-Host "Отчёт сохранён: $path"

.EXAMPLE
    $serverInfo = @{ pg_version = '14.5'; os = 'Windows Server 2019'; ram = '32 ГБ'; cpu_cores = 8 }
    $path = Export-DiagnosticReport -Results $results -ServerInfo $serverInfo -OutputPath 'C:\Reports\report.html'
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

    # --- 1. Определяем путь сохранения ---
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $OutputPath  = Join-Path -Path $desktopPath -ChildPath '1c-postgresql-diagnostic.html'
    }

    # --- 2. Подсчёт статусов ---
    $counts = @{
        Critical   = 0
        Warning    = 0
        Ok         = 0
        NotChecked = 0
    }

    foreach ($row in $Results) {
        $status   = Get-RowProperty -Row $row -EnglishName 'Status' -RussianName 'Состояние'
        $category = Get-HtmlStatusCategory -Status $status
        if ($null -ne $category) {
            $counts[$category]++
        }
    }

    # --- 3. Группировка результатов по разделам ---
    # Используем OrderedDictionary для сохранения порядка разделов
    $sections = [System.Collections.Specialized.OrderedDictionary]::new()

    foreach ($row in $Results) {
        $section = Get-RowProperty -Row $row -EnglishName 'Section' -RussianName 'Раздел'

        if ([string]::IsNullOrWhiteSpace($section)) {
            $section = 'Прочее'
        }

        if (-not $sections.Contains($section)) {
            $sections[$section] = [System.Collections.Generic.List[object]]::new()
        }

        [void]$sections[$section].Add($row)
    }

    # --- 4. Сборка HTML ---

    # Дата и время формирования отчёта
    $reportDate = (Get-Date).ToString('dd.MM.yyyy HH:mm')

    # Блок информации о сервере
    $serverInfoHtml = Get-ServerInfoHtml -ServerInfo $ServerInfo

    # Карточки сводки
    $summaryCardsHtml = @(
        Get-SummaryCardHtml -CssClass 'critical'  -Label 'CRITICAL'     -Emoji '🔴' -Count $counts.Critical
        Get-SummaryCardHtml -CssClass 'warning'   -Label 'WARNING'      -Emoji '🟡' -Count $counts.Warning
        Get-SummaryCardHtml -CssClass 'ok'        -Label 'OK'           -Emoji '🟢' -Count $counts.Ok
        Get-SummaryCardHtml -CssClass 'info'      -Label 'NOT CHECKED'  -Emoji '⚪' -Count $counts.NotChecked
    ) -join "`n"

    # Блоки разделов с результатами
    $allSectionsHtml = [System.Text.StringBuilder]::new()

    foreach ($sectionName in $sections.Keys) {
        $sectionNameHtml = ConvertTo-HtmlEscaped -Text $sectionName
        [void]$allSectionsHtml.AppendLine("        <div class=""section-group"">")
        [void]$allSectionsHtml.AppendLine("            <div class=""section-title"">$sectionNameHtml</div>")

        foreach ($row in $sections[$sectionName]) {
            $status       = Get-RowProperty -Row $row -EnglishName 'Status'       -RussianName 'Состояние'
            $problem      = Get-RowProperty -Row $row -EnglishName 'Problem'      -RussianName 'Проблема'
            $currentValue = Get-RowProperty -Row $row -EnglishName 'CurrentValue' -RussianName 'Текущее значение'
            $detected     = Get-RowProperty -Row $row -EnglishName 'Detected'     -RussianName 'Обнаружено'
            $impact       = Get-RowProperty -Row $row -EnglishName 'Impact'       -RussianName 'Влияние на работу 1С'

            # Пропускаем пустые строки
            if ([string]::IsNullOrWhiteSpace($problem) -and [string]::IsNullOrWhiteSpace($currentValue)) {
                continue
            }

            # Режим сбора данных (Status пустой) — показываем значение вместо статуса
            $displayStatus = if (-not [string]::IsNullOrWhiteSpace($status)) { $status }
                             elseif (-not [string]::IsNullOrWhiteSpace($currentValue)) { $currentValue }
                             else { '' }

            $statusClass = if ([string]::IsNullOrWhiteSpace($status)) { 'info' } else { Get-HtmlStatusClass -Status $status }

            $findingHtml = Get-FindingHtml `
                -StatusClass  $statusClass  `
                -Status       $displayStatus `
                -Problem      $problem      `
                -CurrentValue $currentValue `
                -Detected     $detected     `
                -Impact       $impact

            [void]$allSectionsHtml.AppendLine($findingHtml)
        }

        [void]$allSectionsHtml.AppendLine("        </div>")
    }

    # --- 5. Итоговый HTML-документ ---
    $css = Get-ReportCss

    $html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Диагностика PostgreSQL для 1С:Предприятие</title>
    <style>
$css
    </style>
</head>
<body>

    <header class="report-header">
        <div class="report-title">Диагностика PostgreSQL для 1С:Предприятие</div>
        <div class="report-subtitle">Дата формирования: $reportDate</div>
    </header>

$serverInfoHtml

    <section class="summary-section">
        <div class="summary-cards">
$summaryCardsHtml
        </div>
    </section>

    <section class="results-section">
$($allSectionsHtml.ToString().TrimEnd())
    </section>

    <footer class="report-footer">
        <p>Отчёт сгенерирован сервисом диагностики <a href="https://audit-reshenie.ru" target="_blank">audit-reshenie.ru</a></p>
        <p>По вопросам оптимизации обращайтесь: <a href="mailto:info@audit-reshenie.ru">info@audit-reshenie.ru</a></p>
    </footer>

</body>
</html>
"@

    # --- 6. Сохранение файла ---
    # Убеждаемся, что директория существует
    $outputDir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -Path $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    # Сохраняем в UTF-8 с BOM для корректного отображения кириллицы в браузере
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8Bom)

    Write-Verbose "HTML-отчёт сохранён: $OutputPath"

    # --- 7. Открываем отчёт в браузере ---
    try {
        Start-Process -FilePath $OutputPath
    }
    catch {
        Write-Warning "Не удалось автоматически открыть отчёт в браузере: $_"
    }

    return $OutputPath
}

#endregion

# Экспортируем только публичную функцию
Export-ModuleMember -Function Export-DiagnosticReport
