<#
.SYNOPSIS
    Bootstrap-скрипт диагностики PostgreSQL для 1С:Предприятие.
    Скачивает и запускает диагностику одной командой.

.DESCRIPTION
    Использование:
        irm https://raw.githubusercontent.com/air900/check-parameters-sql-server-for-1c/main/install.ps1 | iex

    Скрипт автоматически:
    1. Скачивает последний релиз с GitHub
    2. Распаковывает во временную папку
    3. Запускает диагностику
    4. Очищает временные файлы после завершения
#>

$ErrorActionPreference = "Stop"

# --- Настройки ---
$repoOwner = "air900"
$repoName  = "check-parameters-sql-server-for-1c"
$tempDir   = Join-Path ([System.IO.Path]::GetTempPath()) "1c-diagnostic-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "      ДИАГНОСТИКА PostgreSQL ДЛЯ 1С:ПРЕДПРИЯТИЕ" -ForegroundColor Cyan
Write-Host "                      audit-reshenie.ru" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Загрузка скрипта диагностики..." -ForegroundColor White

try {
    # --- 1. Определяем URL для скачивания ---
    # Пробуем получить последний релиз через GitHub API
    $downloadUrl = $null
    try {
        $releaseUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
        $headers = @{ "User-Agent" = "1C-Diagnostic-Installer" }
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -ErrorAction Stop

        # Ищем ZIP-архив в ассетах релиза
        $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if ($asset) {
            $downloadUrl = $asset.browser_download_url
            Write-Host "  Найден релиз: $($release.tag_name)" -ForegroundColor Green
        }
    }
    catch {
        Write-Verbose "Релиз не найден, используем архив ветки main"
    }

    # Если релиза нет — скачиваем архив main-ветки
    if (-not $downloadUrl) {
        $downloadUrl = "https://github.com/$repoOwner/$repoName/archive/refs/heads/main.zip"
        Write-Host "  Скачивание из ветки main..." -ForegroundColor Yellow
    }

    # --- 2. Скачиваем и распаковываем ---
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "1c-diagnostic.zip"

    # Принудительно TLS 1.2 (для старых Windows Server)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host "  Скачивание: $downloadUrl" -ForegroundColor Gray
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing

    Write-Host "  Распаковка..." -ForegroundColor Gray
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    # --- 3. Находим скрипт диагностики ---
    # После распаковки ZIP из GitHub, файлы лежат в подпапке <repo>-<branch>/
    $entryPoint = Get-ChildItem -Path $tempDir -Recurse -Filter "Invoke-1CDiagnostic.ps1" | Select-Object -First 1

    if (-not $entryPoint) {
        throw "Скрипт Invoke-1CDiagnostic.ps1 не найден в скачанном архиве."
    }

    Write-Host "  Готово! Запускаю диагностику..." -ForegroundColor Green
    Write-Host ""

    # --- 4. Запускаем диагностику ---
    & $entryPoint.FullName
}
catch {
    Write-Host ""
    Write-Host "  Ошибка при загрузке: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Попробуйте скачать вручную:" -ForegroundColor Yellow
    Write-Host "  https://github.com/$repoOwner/$repoName/releases" -ForegroundColor Yellow
    Write-Host ""
}
finally {
    # --- 5. Очистка временных файлов ---
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
