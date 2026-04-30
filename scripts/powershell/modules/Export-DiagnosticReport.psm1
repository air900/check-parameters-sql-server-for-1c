# ==============================================================================
# Модуль: Export-DiagnosticReport
# ==============================================================================
#
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Сохранение собранных параметров PostgreSQL в автономный HTML-файл.
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
    # Поддержка v2 формата
    if ($EnglishName -eq 'Problem' -and $Row.PSObject.Properties['Label']) { return [string]$Row.Label }
    if ($EnglishName -eq 'CurrentValue' -and $Row.PSObject.Properties['Display']) { return [string]$Row.Display }
    return ''
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
        'pg_version' = 'Версия PostgreSQL'
        'os'         = 'Операционная система'
        'ram'        = 'Оперативная память'
        'cpu_cores'  = 'Процессорных ядер'
        'hostname'   = 'Имя сервера'
        'database'   = 'База данных'
    }

    $rows = [System.Text.StringBuilder]::new()

    foreach ($key in $labelMap.Keys) {
        if ($ServerInfo.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($ServerInfo[$key])) {
            $label = ConvertTo-HtmlEscaped -Text $labelMap[$key]
            $value = ConvertTo-HtmlEscaped -Text ([string]$ServerInfo[$key])
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
    Сохраняет собранные параметры PostgreSQL в автономный HTML-файл.

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
    Путь для сохранения HTML. По умолчанию: Рабочий стол\1c-postgresql-diagnostic.html

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

    # --- 1. Путь сохранения ---
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $OutputPath  = Join-Path -Path $desktopPath -ChildPath '1c-postgresql-diagnostic.html'
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
            $valueHtml   = ConvertTo-HtmlEscaped -Text $currentValue

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
    <title>Диагностика PostgreSQL для 1С:Предприятие</title>
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
        <div class="report-title">Диагностика PostgreSQL для 1С:Предприятие</div>
        <div class="report-subtitle">Дата формирования: $reportDate</div>
    </header>

$serverInfoHtml

    <div class="data-summary">Собрано параметров: <strong>$($Results.Count)</strong></div>

    <section class="results-section">
$($allSectionsHtml.ToString().TrimEnd())
    </section>

    <footer class="report-footer">
        <p>Для углублённого анализа и рекомендаций по настройке: <a href="https://audit-reshenie.ru" target="_blank">audit-reshenie.ru</a> | <a href="mailto:info@audit-reshenie.ru">info@audit-reshenie.ru</a></p>
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
