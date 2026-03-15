# ==============================================================================
# Модуль: Send-DiagnosticData
# ==============================================================================
#
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Предлагает пользователю отправить собранные данные на углублённый анализ.
#   Всегда показывает рекламный блок и запрашивает согласие.
#   Фактическая отправка данных — заглушка до готовности бэкенда.
#
# Использование:
#   Import-Module .\modules\Send-DiagnosticData.psm1
#   Send-DiagnosticData -Results $results -Summary $summary
#
# ==============================================================================

#region Вспомогательные функции

# Выводит горизонтальную линию рамки заданной ширины
function Write-BoxLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line,
        [System.ConsoleColor]$Color = 'DarkGray'
    )

    Write-Host $Line -ForegroundColor $Color
}

# Формирует строку рамки с выровненным по ширине содержимым
# Пример: "║  Текст                              ║"
function Format-BoxRow {
    [OutputType([string])]
    param(
        [string]$Text = '',
        [int]$InnerWidth = 60
    )

    # Обрезаем, если текст длиннее допустимого
    if ($Text.Length -gt $InnerWidth) {
        $Text = $Text.Substring(0, $InnerWidth)
    }

    $padding = $InnerWidth - $Text.Length
    return [string]::Format('{0}  {1}{2}  {3}', [char]0x2551, $Text, (' ' * $padding), [char]0x2551)
}

# Выводит стилизованный рекламный блок с предложением углублённого анализа
function Show-AnalysisOffer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )

    # Символы рамки (Unicode box-drawing)
    $topLeft     = [char]0x2554   # ╔
    $topRight    = [char]0x2557   # ╗
    $bottomLeft  = [char]0x255A   # ╚
    $bottomRight = [char]0x255D   # ╝
    $horizontal  = [char]0x2550   # ═
    $divLeft     = [char]0x2560   # ╠
    $divRight    = [char]0x2563   # ╣

    $innerWidth  = 60
    $totalWidth  = $innerWidth + 4   # 2 символа рамки + 2 пробела с каждой стороны

    $hLine       = $horizontal.ToString() * $totalWidth

    Write-Host ''
    Write-BoxLine "${topLeft}${hLine}${topRight}"
    Write-BoxLine (Format-BoxRow '' $innerWidth)
    Write-Host (Format-BoxRow '  АНАЛИЗ КОНФИГУРАЦИИ' $innerWidth) -ForegroundColor Green
    Write-BoxLine (Format-BoxRow '' $innerWidth)
    Write-BoxLine "${divLeft}${hLine}${divRight}"
    Write-BoxLine (Format-BoxRow '' $innerWidth)
    Write-Host (Format-BoxRow '  Что вы получите:' $innerWidth) -ForegroundColor White
    Write-BoxLine (Format-BoxRow '' $innerWidth)
    Write-Host (Format-BoxRow '  * Оценку текущих настроек сервера' $innerWidth) -ForegroundColor White
    Write-Host (Format-BoxRow '  * Выявление ошибок конфигурации,' $innerWidth) -ForegroundColor White
    Write-Host (Format-BoxRow '    влияющих на производительность 1С' $innerWidth) -ForegroundColor White
    Write-Host (Format-BoxRow '  * Приоритеты: что критично,' $innerWidth) -ForegroundColor White
    Write-Host (Format-BoxRow '    что желательно, что в норме' $innerWidth) -ForegroundColor White
    Write-BoxLine (Format-BoxRow '' $innerWidth)
    Write-BoxLine "${bottomLeft}${hLine}${bottomRight}"
    Write-Host ''
}

#endregion

#region Основная экспортируемая функция

<#
.SYNOPSIS
    Предлагает отправить результаты диагностики на углублённый анализ.

.DESCRIPTION
    Выводит стилизованный рекламный блок и запрашивает согласие пользователя
    на отправку данных. Всегда предлагает анализ — модуль работает в режиме
    сбора данных. Фактическая отправка не реализована — заглушка до готовности
    бэкенда.

.PARAMETER Results
    Массив объектов PSCustomObject — результаты диагностических проверок.

.PARAMETER Summary
    Hashtable с ключом Total — общее количество собранных параметров.

.PARAMETER ApiUrl
    URL бэкенда для отправки данных. Используется только в TODO-коде.
    По умолчанию: https://check-speed-sql-server-1c.audit-reshenie.ru:15443/api/v1/analyze

.EXAMPLE
    $summary = @{ Total = $results.Count }
    Send-DiagnosticData -Results $results -Summary $summary

.EXAMPLE
    Send-DiagnosticData -Results $results -Summary $summary -ApiUrl 'https://example.com/api/analyze'
#>
function Send-DiagnosticData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        [hashtable]$Summary,

        [Parameter()]
        [string]$ApiUrl = 'https://check-speed-sql-server-1c.audit-reshenie.ru:15443/api/v1/analyze'
    )

    # Показываем рекламный блок с описанием углублённого анализа
    Show-AnalysisOffer -Summary $Summary

    # Запрашиваем согласие пользователя
    $answer = Read-Host 'Отправить данные на углублённый анализ? (Y/N)'

    if ($answer -notmatch '^[YyДд]') {
        Write-Host ''
        Write-Host 'Вы всегда можете запустить диагностику повторно.' -ForegroundColor DarkGray
        return
    }

    # --- Сервис ещё не готов ---
    # TODO: Удалить это сообщение после запуска бэкенда и раскомментировать код ниже
    Write-Host ''
    Write-Host 'Сервис углублённого анализа будет доступен в ближайшее время.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Следите за обновлениями:' -ForegroundColor Cyan
    Write-Host '  https://github.com/air900/check-parameters-sql-server-for-1c' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Контакты:' -ForegroundColor Gray
    Write-Host '  audit-reshenie.ru  |  info@audit-reshenie.ru' -ForegroundColor Gray
    Write-Host ''

    # ==========================================================================
    # TODO: Реализовать после запуска бэкенда
    # ==========================================================================
    #
    # # Запрашиваем email для получения отчёта
    # $email = Read-Host 'Введите email для получения отчёта'
    # if ([string]::IsNullOrWhiteSpace($email)) {
    #     Write-Warning 'Email не указан. Отправка отменена.'
    #     return
    # }
    #
    # # Формируем тело запроса
    # $payload = @{
    #     email    = $email
    #     results  = $Results
    #     summary  = $Summary
    #     sentAt   = (Get-Date -Format 'o')
    # }
    #
    # $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
    #
    # # Отправляем данные на бэкенд
    # try {
    #     $response = Invoke-RestMethod `
    #         -Uri     $ApiUrl `
    #         -Method  Post `
    #         -Body    $jsonBody `
    #         -ContentType 'application/json; charset=utf-8' `
    #         -TimeoutSec 30
    #
    #     Write-Host "Данные успешно отправлены. Отчёт будет выслан на $email." -ForegroundColor Green
    #     Write-Verbose "Ответ сервера: $($response | ConvertTo-Json -Depth 5)"
    # }
    # catch {
    #     Write-Warning "Не удалось отправить данные: $_"
    #     Write-Host "Обратитесь напрямую: info@audit-reshenie.ru" -ForegroundColor Gray
    # }
    # ==========================================================================
}

#endregion

# Экспортируем только публичную функцию
Export-ModuleMember -Function Send-DiagnosticData
