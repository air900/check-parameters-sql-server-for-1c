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

function Read-FreshConsoleAnswer {
    param([string]$Question)

    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Write-Host 'Для подтверждения нужна интерактивная консоль PowerShell.' -ForegroundColor Yellow
        return $null
    }
    Write-Host $Question -NoNewline
    # Убираем нажатия, накопленные до вопроса, затем показываем приглашение к вводу.
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    Write-Host ': ' -NoNewline
    Microsoft.PowerShell.Utility\Read-Host -ErrorAction Stop
}

function Confirm-ConsoleAction {
    param([string]$Question)

    while ($true) {
        try { $answer = Read-FreshConsoleAnswer -Question $Question }
        catch {
            Write-Host 'Не удалось прочитать ответ из консоли.' -ForegroundColor Yellow
            return $false
        }
        if ($null -eq $answer) { return $false }
        $answer = $answer.Trim()
        if ($answer -in @('Да', 'Д', 'Yes', 'Y')) { return $true }
        if ($answer -in @('Нет', 'Н', 'No', 'N')) { return $false }
        Write-Host 'Введите Да или Нет и нажмите Enter.' -ForegroundColor Yellow
    }
}

# Показывает результаты анализа в терминале
function Show-Findings {
    param([array]$Findings, $BackendSummary)

    if (-not $Findings -or $Findings.Count -eq 0) {
        Write-Host '  В результатах анализа нет критических и важных отклонений.' -ForegroundColor Green
        return
    }

    $critCount = if ($BackendSummary.critical) { $BackendSummary.critical } else { 0 }
    $warnCount = if ($BackendSummary.warning) { $BackendSummary.warning } else { 0 }
    $okCount   = if ($BackendSummary.ok) { $BackendSummary.ok } else { 0 }

    Write-Host ''
    Write-Host '  Результат анализа' -ForegroundColor Cyan
    Write-Host "    Отклонения: критических $critCount, важных $warnCount. В норме: $okCount." -ForegroundColor White
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
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
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    Write-Host '  Вопросы по результатам' -ForegroundColor White
    Write-Host '    audit-reshenie.ru  |  info@audit-reshenie.ru' -ForegroundColor Cyan
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

.PARAMETER Dbms
    Имя СУБД — 'postgresql' или 'mssql'. Используется только при сборке fallback-payload
    (когда -Payload не передан). Если -Payload передан — поле берётся из него.

.PARAMETER ApiUrl
    URL сервиса анализа.
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

        [Parameter(Mandatory = $false)]
        [ValidateSet('postgresql', 'mssql')]
        [string]$Dbms,

        [Parameter()]
        [string]$ApiUrl = 'https://check-speed-sql-server-1c.audit-reshenie.ru:15443/api/v1/analyze'
    )

    $analysisHost = ([uri]$ApiUrl).Authority
    Write-Host ''
    Write-Host "  Сервис анализа — $analysisHost." -ForegroundColor White
    Write-Host '  В JSON входят параметры и сведения о сервере и базе.' -ForegroundColor White
    Write-Host '  В данных могут быть имена учётных записей, ролей и узлов' -ForegroundColor White
    Write-Host '  и фрагменты SQL из сеансов.' -ForegroundColor White
    Write-Host '  Если JSON сохранился, его можно открыть на рабочем столе до отправки.' -ForegroundColor White
    Write-Host '  Сервис проверит настройки и вернёт ссылку на отчёт.' -ForegroundColor White

    if (-not (Confirm-ConsoleAction 'Отправить собранные данные на анализ? [Да/Нет или Y/N]')) {
        Write-Host '  Собранные данные не отправлены.'
        return
    }

    # Формируем JSON из payload
    if (-not $Payload) {
        if (-not $Dbms) {
            throw "Send-DiagnosticData: при вызове без -Payload требуется -Dbms (postgresql|mssql)."
        }
        $Payload = @{
            version    = 'unknown'
            dbms       = $Dbms
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
    Write-Host '  Отправляем данные на анализ. Ответ может занять до 60 секунд.' -ForegroundColor Gray

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
            -TimeoutSec  60 -ErrorAction Stop

        # Декодируем ответ как UTF-8
        $responseText = [System.Text.Encoding]::UTF8.GetString($webResponse.RawContentStream.ToArray())
        $response = $responseText | ConvertFrom-Json

        if ($null -eq $response -or $null -eq $response.findings -or $null -eq $response.summary) {
            throw 'В ответе сервиса нет результатов проверки.'
        }
    }
    catch {
        Write-Host ''
        Write-Host "  Не удалось получить результат анализа. $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    Show-Findings -Findings $response.findings -BackendSummary $response.summary

    if ($response.report_url) {
        $reportUrl = $response.report_url
        Write-Host "  Отчёт об анализе: $reportUrl" -ForegroundColor Cyan
        try {
            $desktopPath = [Environment]::GetFolderPath('Desktop')
            $reportFile = Join-Path $desktopPath '1c-analysis-report.html' -ErrorAction Stop
            Invoke-WebRequest -Uri $reportUrl -OutFile $reportFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        }
        catch {
            Write-Host "  Не удалось сохранить копию отчёта. $_" -ForegroundColor Yellow
            return
        }

        Write-Host "  Копия отчёта сохранена в $reportFile" -ForegroundColor Green
        if (Confirm-ConsoleAction '  Открыть отчёт в браузере? (Да/Нет или Y/N)') {
            try {
                $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
                $chromePath86 = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
                $edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
                if (Test-Path $chromePath) {
                    Start-Process -FilePath $chromePath -ArgumentList ('"{0}"' -f $reportFile) -ErrorAction Stop
                }
                elseif (Test-Path $chromePath86) {
                    Start-Process -FilePath $chromePath86 -ArgumentList ('"{0}"' -f $reportFile) -ErrorAction Stop
                }
                elseif (Test-Path $edgePath) {
                    Start-Process -FilePath $edgePath -ArgumentList ('"{0}"' -f $reportFile) -ErrorAction Stop
                }
                else {
                    Start-Process -FilePath $reportFile -ErrorAction Stop
                }
            }
            catch {
                Write-Host "  Не удалось открыть сохранённую копию в браузере. $_" -ForegroundColor Yellow
            }
        }
    }
}

#endregion

Export-ModuleMember -Function Send-DiagnosticData
