# ==============================================================================
# Модуль: Send-DiagnosticData
# ==============================================================================
#
# Совместимость: PowerShell 5.1+
#
# Назначение:
#   Отправляет собранные данные на сервис анализа и отображает результат.
#
# ==============================================================================

#region Вспомогательные функции

function Write-BoxLine {
    param([string]$Line, [System.ConsoleColor]$Color = 'DarkGray')
    Write-Host $Line -ForegroundColor $Color
}

function Format-BoxRow {
    [OutputType([string])]
    param([string]$Text = '', [int]$InnerWidth = 60)
    if ($Text.Length -gt $InnerWidth) { $Text = $Text.Substring(0, $InnerWidth) }
    $padding = $InnerWidth - $Text.Length
    return [string]::Format('{0}  {1}{2}  {3}', [char]0x2551, $Text, (' ' * $padding), [char]0x2551)
}

function Show-AnalysisOffer {
    param([hashtable]$Summary)

    $tl = [char]0x2554; $tr = [char]0x2557
    $bl = [char]0x255A; $br = [char]0x255D
    $hz = [char]0x2550; $dl = [char]0x2560; $dr = [char]0x2563
    $iw = 60; $tw = $iw + 4
    $hLine = $hz.ToString() * $tw

    Write-Host ''
    Write-BoxLine "${tl}${hLine}${tr}"
    Write-BoxLine (Format-BoxRow '' $iw)
    Write-Host (Format-BoxRow '  АНАЛИЗ КОНФИГУРАЦИИ' $iw) -ForegroundColor Green
    Write-BoxLine (Format-BoxRow '' $iw)
    Write-BoxLine "${dl}${hLine}${dr}"
    Write-BoxLine (Format-BoxRow '' $iw)
    Write-Host (Format-BoxRow '  Что вы получите:' $iw) -ForegroundColor White
    Write-BoxLine (Format-BoxRow '' $iw)
    Write-Host (Format-BoxRow '  * Оценку текущих настроек сервера' $iw) -ForegroundColor White
    Write-Host (Format-BoxRow '  * Выявление ошибок конфигурации,' $iw) -ForegroundColor White
    Write-Host (Format-BoxRow '    влияющих на производительность 1С' $iw) -ForegroundColor White
    Write-Host (Format-BoxRow '  * Приоритеты: что критично,' $iw) -ForegroundColor White
    Write-Host (Format-BoxRow '    что желательно, что в норме' $iw) -ForegroundColor White
    Write-BoxLine (Format-BoxRow '' $iw)
    Write-BoxLine "${bl}${hLine}${br}"
    Write-Host ''
}

# Отображает findings от бэкенда в терминале
function Show-Findings {
    param([array]$Findings, $BackendSummary)

    if (-not $Findings -or $Findings.Count -eq 0) {
        Write-Host '  Проблем не обнаружено.' -ForegroundColor Green
        return
    }

    $critCount = if ($BackendSummary.critical) { $BackendSummary.critical } else { 0 }
    $warnCount = if ($BackendSummary.warning) { $BackendSummary.warning } else { 0 }
    $okCount   = if ($BackendSummary.ok) { $BackendSummary.ok } else { 0 }

    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor White
    Write-Host "  РЕЗУЛЬТАТ АНАЛИЗА" -ForegroundColor Cyan
    Write-Host "    Критичных: $critCount  |  Важных: $warnCount  |  В норме: $okCount" -ForegroundColor White
    Write-Host '  ================================================================' -ForegroundColor White
    Write-Host ''

    $currentSection = $null

    foreach ($f in $Findings) {
        $section = $f.section
        if ($section -ne $currentSection) {
            if ($null -ne $currentSection) { Write-Host '' }
            Write-Host "  --- $section ---" -ForegroundColor Cyan
            $currentSection = $section
        }

        $sev = $f.severity
        $color = switch ($sev) {
            'CRITICAL' { 'Red' }
            'WARNING'  { 'Yellow' }
            default    { 'Gray' }
        }
        $badge = switch ($sev) {
            'CRITICAL' { '[!]' }
            'WARNING'  { '[*]' }
            default    { '[i]' }
        }

        Write-Host "  $badge $($f.problem)" -ForegroundColor $color
        if ($f.detected) {
            Write-Host "      $($f.detected)" -ForegroundColor DarkGray
        }
        if ($f.impact -and $sev -in 'CRITICAL', 'WARNING') {
            Write-Host "      $($f.impact)" -ForegroundColor $color
        }
    }

    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor White
    Write-Host '  Для исправления обнаруженных проблем:' -ForegroundColor White
    Write-Host '    audit-reshenie.ru  |  info@audit-reshenie.ru' -ForegroundColor Cyan
    Write-Host '  ================================================================' -ForegroundColor White
}

#endregion

#region Основная функция

<#
.SYNOPSIS
    Отправляет данные на сервис анализа и показывает результат.

.PARAMETER Results
    Массив PSCustomObject — собранные параметры.

.PARAMETER Summary
    Hashtable с ключом Total.

.PARAMETER Payload
    Hashtable — готовый payload для отправки на API (version, dbms, server, parameters).

.PARAMETER ApiUrl
    URL API для отправки. По умолчанию: proxy URL.
#>
function Send-DiagnosticData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        [hashtable]$Summary,

        [Parameter(Mandatory = $false)]
        [hashtable]$Payload,

        [Parameter()]
        [string]$ApiUrl = 'https://check-speed-sql-server-1c.audit-reshenie.ru:15443/api/v1/analyze'
    )

    # Показываем рекламный блок
    Show-AnalysisOffer -Summary $Summary

    # Запрашиваем согласие
    $answer = Read-Host 'Отправить данные на углублённый анализ? (Y/N)'

    if ($answer -notmatch '^[YyДд]') {
        Write-Host ''
        Write-Host 'Вы всегда можете запустить диагностику повторно.' -ForegroundColor DarkGray
        return
    }

    # Формируем JSON из payload
    if (-not $Payload) {
        # Fallback: формируем payload из Results
        $Payload = @{
            version    = 'unknown'
            dbms       = 'postgresql'
            timestamp  = (Get-Date -Format 'o')
            server     = @{}
            parameters = @($Results | ForEach-Object {
                @{
                    key     = $_.Key
                    value   = $_.Value
                    display = $_.CurrentValue
                    section = $_.Section
                    label   = $_.Problem
                }
            })
        }
    }

    $jsonBody = $Payload | ConvertTo-Json -Depth 10 -Compress

    Write-Host ''
    Write-Host '  Отправка данных на анализ...' -ForegroundColor Gray

    try {
        # Для PS 5.1 нужно явно указать TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Используем Invoke-WebRequest + ручной UTF-8 decode (PS 5.1 ломает кириллицу в Invoke-RestMethod)
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

        $webResponse = Invoke-WebRequest `
            -Uri         $ApiUrl `
            -Method      Post `
            -Body        $utf8Bytes `
            -ContentType 'application/json; charset=utf-8' `
            -UseBasicParsing `
            -TimeoutSec  60

        # Декодируем ответ как UTF-8
        $responseText = [System.Text.Encoding]::UTF8.GetString($webResponse.RawContentStream.ToArray())
        $response = $responseText | ConvertFrom-Json

        # Показываем результат анализа
        Show-Findings -Findings $response.findings -BackendSummary $response.summary

        # Скачиваем HTML-отчёт от бэкенда и сохраняем локально
        if ($response.report_url) {
            try {
                $reportUrl = $response.report_url
                $desktopPath = [Environment]::GetFolderPath('Desktop')
                $reportFile = Join-Path $desktopPath '1c-analysis-report.html'
                Invoke-WebRequest -Uri $reportUrl -OutFile $reportFile -UseBasicParsing -TimeoutSec 30
                Write-Host ''
                Write-Host "  Отчёт сохранён: $reportFile" -ForegroundColor Green
                Write-Host '  [*] Для корректного отображения откройте в Chrome, Edge или Firefox' -ForegroundColor Yellow
                $openReport = Read-Host '  Открыть отчёт в браузере? (Y/N)'
                if ($openReport -match '^[YyДд]') {
                    # Пробуем открыть в Chrome, затем Edge, затем дефолтный браузер
                    $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
                    $chromePath86 = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
                    $edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
                    if (Test-Path $chromePath) {
                        Start-Process -FilePath $chromePath -ArgumentList $reportFile
                    }
                    elseif (Test-Path $chromePath86) {
                        Start-Process -FilePath $chromePath86 -ArgumentList $reportFile
                    }
                    elseif (Test-Path $edgePath) {
                        Start-Process -FilePath $edgePath -ArgumentList $reportFile
                    }
                    else {
                        Start-Process -FilePath $reportFile
                    }
                }
                Write-Host "  Постоянная ссылка: $reportUrl" -ForegroundColor Cyan
            }
            catch {
                Write-Host "  Не удалось скачать отчёт: $_" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host ''
        Write-Host '  Не удалось отправить данные на анализ.' -ForegroundColor Red
        Write-Host "  Ошибка: $_" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Попробуйте позже или обратитесь:' -ForegroundColor Yellow
        Write-Host '    audit-reshenie.ru  |  info@audit-reshenie.ru' -ForegroundColor Cyan
    }
}

#endregion

Export-ModuleMember -Function Send-DiagnosticData
