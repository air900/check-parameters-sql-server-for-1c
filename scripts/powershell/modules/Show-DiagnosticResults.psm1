# ==============================================================================
# Модуль: Show-DiagnosticResults
# ==============================================================================
#
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Отображение собранных параметров в терминале с группировкой по разделам.
#
# Использование:
#   Import-Module .\modules\Show-DiagnosticResults.psm1
#   $counts = Show-DiagnosticResults -Results $diagnosticResults
#
# ==============================================================================

#region Вспомогательные функции

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
    Отображает собранные параметры с группировкой по разделам.

.DESCRIPTION
    Принимает массив объектов сбора данных (PSCustomObject), выводит их в терминал
    с группировкой по разделам в формате "Параметр ........ Значение".

.PARAMETER Results
    Массив объектов PSCustomObject со свойствами:
        Section      — название раздела (группировка)
        Problem      — название параметра / метки
        CurrentValue — текущее значение параметра

.OUTPUTS
    Hashtable с ключом: Total — общее количество параметров.

.EXAMPLE
    $rows = Invoke-SqlDiagnostic -PgHost localhost
    $counts = Show-DiagnosticResults -Results $rows
    Write-Host "Параметров собрано: $($counts.Total)"
#>
function Show-DiagnosticResults {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $false)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $counts = @{ Total = 0 }

    if ($null -eq $Results -or $Results.Count -eq 0) {
        Write-Host 'Нет данных для отображения.' -ForegroundColor DarkGray
        return $counts
    }

    $currentSection = $null

    foreach ($row in $Results) {
        # Получаем значения свойств (совместимо с PS 5.1)
        $section      = if ($row.PSObject.Properties['Section'])      { [string]$row.Section }
                        elseif ($row.PSObject.Properties['Раздел'])   { [string]$row.'Раздел' }
                        else { '' }

        $problem      = if ($row.PSObject.Properties['Problem'])      { [string]$row.Problem }
                        elseif ($row.PSObject.Properties['Label'])    { [string]$row.Label }
                        elseif ($row.PSObject.Properties['Проблема']) { [string]$row.'Проблема' }
                        else { '' }

        $currentValue = if ($row.PSObject.Properties['CurrentValue'])         { [string]$row.CurrentValue }
                        elseif ($row.PSObject.Properties['Display'])          { [string]$row.Display }
                        elseif ($row.PSObject.Properties['Текущее значение']) { [string]$row.'Текущее значение' }
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

        if (-not [string]::IsNullOrWhiteSpace($problem)) {
            $counts.Total++

            if (-not [string]::IsNullOrWhiteSpace($currentValue)) {
                # Формат: Параметр .................. Значение
                $label = "  $problem "
                $dots = '.' * [Math]::Max(2, (50 - $label.Length))
                Write-Host $label -ForegroundColor White -NoNewline
                Write-Host $dots -ForegroundColor DarkGray -NoNewline
                Write-Host " $currentValue" -ForegroundColor Green
            }
            else {
                Write-Host "  $problem" -ForegroundColor White
            }
        }
    }

    # Итоговая сводка
    Write-Host ''
    Write-Separator -Width 72 -Char '=' -Color White
    Write-Host "СОБРАНО ПАРАМЕТРОВ: $($counts.Total)" -ForegroundColor White
    Write-Separator -Width 72 -Char '=' -Color White

    return $counts
}

#endregion

# Экспортируем только публичную функцию
Export-ModuleMember -Function Show-DiagnosticResults
