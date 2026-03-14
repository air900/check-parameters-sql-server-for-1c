# ==============================================================================
# Модуль: Show-DiagnosticResults
# ==============================================================================
#
# Версия:       1.0
# Дата:         2026-03-14
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Отображение результатов диагностики в терминале с цветовой индикацией
#   статусов и группировкой по разделам.
#
# Использование:
#   Import-Module .\modules\Show-DiagnosticResults.psm1
#   $counts = Show-DiagnosticResults -Results $diagnosticResults
#
# ==============================================================================

#region Вспомогательные функции

# Определяет цвет вывода по значению поля Состояние
function Get-StatusColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    # Сопоставление по эмодзи-префиксу, чтобы поддерживать русский и английский текст
    if ($Status -match '🔴') {
        return 'Red'
    }
    elseif ($Status -match '🟡') {
        return 'Yellow'
    }
    elseif ($Status -match '🟢') {
        return 'Green'
    }
    elseif ($Status -match '⚪') {
        return 'DarkGray'
    }

    # Запасное сопоставление по ключевым словам (английские и русские варианты)
    switch -Regex ($Status.ToUpperInvariant()) {
        'CRITICAL|КРИТИЧНО' { return 'Red' }
        'WARNING|ВАЖНО'     { return 'Yellow' }
        '^OK$|НОРМА'        { return 'Green' }
        default             { return 'DarkGray' }
    }
}

# Определяет числовую серьёзность статуса для подсчёта итогов
# Возвращает: 'Critical', 'Warning', 'Ok' или $null (для строк без статуса)
function Get-StatusCategory {
    [CmdletBinding()]
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

    # Строки с ⚪ и прочие считаются не проверенными — не включаем в счётчики
    return $null
}

# Выводит горизонтальный разделитель указанной длины
function Write-Separator {
    [CmdletBinding()]
    param(
        [int]$Width = 72,
        [char]$Char = '-',
        [System.ConsoleColor]$Color = 'DarkGray'
    )

    Write-Host ($Char.ToString() * $Width) -ForegroundColor $Color
}

#endregion

#region Основная экспортируемая функция

<#
.SYNOPSIS
    Отображает результаты диагностики с цветовой индикацией и группировкой по разделам.

.DESCRIPTION
    Принимает массив объектов диагностики (PSCustomObject), выводит их в терминал
    с цветовыми статусами CRITICAL / WARNING / OK / NOT CHECKED, группирует по
    разделам и показывает итоговую сводку.

.PARAMETER Results
    Массив объектов PSCustomObject со свойствами:
        N            — порядковый номер
        Section      — название раздела (группировка)
        Problem      — название проблемы / параметра
        Status       — статус с эмодзи: 🔴 / 🟡 / 🟢 / ⚪
        CurrentValue — текущее значение параметра (может быть пустым)
        Detected     — описание обнаруженного состояния
        Impact       — влияние на работу (выводится только для CRITICAL и WARNING)

.OUTPUTS
    Hashtable с ключами: Critical, Warning, Ok — количество строк каждого статуса.

.EXAMPLE
    $rows = Invoke-Sqlcmd -ServerInstance $server -Query $sql
    $counts = Show-DiagnosticResults -Results $rows
    Write-Host "Критических: $($counts.Critical)"
#>
function Show-DiagnosticResults {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $false)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    # Счётчики по категориям статусов
    $counts = @{
        Critical = 0
        Warning  = 0
        Ok       = 0
    }

    if ($null -eq $Results -or $Results.Count -eq 0) {
        Write-Host 'Нет данных для отображения.' -ForegroundColor DarkGray
        return $counts
    }

    $currentSection = $null

    foreach ($row in $Results) {
        # Получаем значения свойств с защитой от $null (совместимо с PS 5.1)
        # Поддерживаем как английские имена свойств, так и русские (из результатов SQL)
        $section      = if ($row.PSObject.Properties['Section'])      { [string]$row.Section }
                        elseif ($row.PSObject.Properties['Раздел'])   { [string]$row.'Раздел' }
                        else { '' }

        $problem      = if ($row.PSObject.Properties['Problem'])      { [string]$row.Problem }
                        elseif ($row.PSObject.Properties['Проблема']) { [string]$row.'Проблема' }
                        else { '' }

        $status       = if ($row.PSObject.Properties['Status'])         { [string]$row.Status }
                        elseif ($row.PSObject.Properties['Состояние'])  { [string]$row.'Состояние' }
                        else { '' }

        $currentValue = if ($row.PSObject.Properties['CurrentValue'])          { [string]$row.CurrentValue }
                        elseif ($row.PSObject.Properties['Текущее значение'])  { [string]$row.'Текущее значение' }
                        else { '' }

        $detected     = if ($row.PSObject.Properties['Detected'])       { [string]$row.Detected }
                        elseif ($row.PSObject.Properties['Обнаружено']) { [string]$row.'Обнаружено' }
                        else { '' }

        $impact       = if ($row.PSObject.Properties['Impact'])                    { [string]$row.Impact }
                        elseif ($row.PSObject.Properties['Влияние на работу 1С']) { [string]$row.'Влияние на работу 1С' }
                        else { '' }

        # Выводим заголовок раздела при смене раздела
        if ($section -ne $currentSection) {
            if ($null -ne $currentSection) {
                Write-Host ''
            }
            Write-Separator -Width 72 -Char '=' -Color Cyan
            Write-Host $section -ForegroundColor Cyan
            Write-Separator -Width 72 -Char '=' -Color Cyan
            $currentSection = $section
        }

        # Строки без статуса — режим сбора данных (Параметр = Значение)
        if ([string]::IsNullOrWhiteSpace($status)) {
            if (-not [string]::IsNullOrWhiteSpace($problem)) {
                if (-not [string]::IsNullOrWhiteSpace($currentValue)) {
                    # Формат: Параметр .................. Значение
                    $label = "  $problem "
                    $dots = '.' * [Math]::Max(2, (50 - $label.Length))
                    Write-Host $label -ForegroundColor Gray -NoNewline
                    Write-Host $dots -ForegroundColor DarkGray -NoNewline
                    Write-Host " $currentValue" -ForegroundColor White
                }
                else {
                    Write-Host "  $problem" -ForegroundColor Gray
                }
                if (-not [string]::IsNullOrWhiteSpace($detected)) {
                    Write-Host "    $detected" -ForegroundColor DarkGray
                }
            }
            continue
        }

        $color    = Get-StatusColor -Status $status
        $category = Get-StatusCategory -Status $status

        # Обновляем счётчики
        if ($null -ne $category) {
            $counts[$category]++
        }

        # Строка: [Статус] Название проблемы
        $statusPad = $status.PadRight(20)
        Write-Host "  [$statusPad] $problem" -ForegroundColor $color

        # Текущее значение (если есть)
        if (-not [string]::IsNullOrWhiteSpace($currentValue)) {
            Write-Host "    Значение : $currentValue" -ForegroundColor DarkGray
        }

        # Описание обнаруженного
        if (-not [string]::IsNullOrWhiteSpace($detected)) {
            Write-Host "    Факт     : $detected" -ForegroundColor DarkGray
        }

        # Влияние — только для критических и важных
        if (-not [string]::IsNullOrWhiteSpace($impact) -and $category -in 'Critical', 'Warning') {
            Write-Host "    Влияние  : $impact" -ForegroundColor $color
        }
    }

    # Итоговая сводка
    Write-Host ''
    Write-Separator -Width 72 -Char '=' -Color White
    Write-Host 'ИТОГО:' -ForegroundColor White
    Write-Host "  Критических : $($counts.Critical)" -ForegroundColor $(if ($counts.Critical -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Важных      : $($counts.Warning)"  -ForegroundColor $(if ($counts.Warning  -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Норма       : $($counts.Ok)"        -ForegroundColor Green
    Write-Separator -Width 72 -Char '=' -Color White

    return $counts
}

#endregion

# Экспортируем только публичную функцию
Export-ModuleMember -Function Show-DiagnosticResults
