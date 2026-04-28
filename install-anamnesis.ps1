<#
.SYNOPSIS
  Установщик Anamnesis Kit — длительное наблюдение за расчётом.

.DESCRIPTION
  Скачивает последний релизный архив с GitHub Releases (один общий zip),
  выдёргивает из него только scripts/anamnesis/* и project.json,
  раскладывает в $RootPath с плоской структурой (setup, watcher, upload, README.md, project.json).
  Создаёт data\snapshots, data\xe, data\archives для runtime-артефактов.
  PowerShell 5.1 совместимо.

.PARAMETER RootPath
  Куда установить (default: C:\Anamnesis).

.PARAMETER Version
  Конкретная версия (default — latest).

.EXAMPLE
  irm https://raw.githubusercontent.com/air900/check-parameters-sql-server-for-1c/main/install-anamnesis.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$RootPath = 'C:\Anamnesis',
    [string]$Version = 'latest'
)

$ErrorActionPreference = 'Stop'

# PS 5.1 по умолчанию использует TLS 1.0; GitHub требует TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'air900/check-parameters-sql-server-for-1c'

# 1. Найти релиз и любой *.zip ассет (имя архива не фиксируем)
if ($Version -eq 'latest') {
    $releaseApi = "https://api.github.com/repos/$repo/releases/latest"
} else {
    $releaseApi = "https://api.github.com/repos/$repo/releases/tags/$Version"
}

Write-Output "Запрашиваю $releaseApi ..."
$release = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'install-anamnesis' }
$asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
if (-not $asset) {
    throw "В релизе $($release.tag_name) не найден ни один zip-ассет"
}

$tag = $release.tag_name

# 2. Скачать в темп
$tempZip = Join-Path $env:TEMP "anamnesis-kit-$tag.zip"
$tempExtract = Join-Path $env:TEMP "anamnesis-kit-extract-$tag"
Write-Output "Скачиваю $($asset.browser_download_url)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip -UseBasicParsing

# 3. Распаковать в темп-папку
if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

# 4. Найти scripts/anamnesis (структура zip:
#    либо плоско: scripts/anamnesis/...
#    либо с префиксом: <repo-name>-<branch>/scripts/anamnesis/... — на случай fallback на main archive)
$anamnesisSrc = Get-ChildItem -Path $tempExtract -Recurse -Directory -Filter 'anamnesis' |
    Where-Object { (Split-Path $_.Parent.FullName -Leaf) -eq 'scripts' } |
    Select-Object -First 1
if (-not $anamnesisSrc) {
    throw "Не найдена папка scripts/anamnesis в архиве $tempZip"
}

# 5. Создать $RootPath и скопировать содержимое scripts/anamnesis (плоско, без префикса 'anamnesis')
if (-not (Test-Path $RootPath)) {
    New-Item -ItemType Directory -Force -Path $RootPath | Out-Null
}
Get-ChildItem -Path $anamnesisSrc.FullName | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $RootPath -Recurse -Force
}

# 6. Скопировать project.json (для api_url + version) — он лежит на 2 уровня выше anamnesis
$repoRoot = Split-Path (Split-Path $anamnesisSrc.FullName -Parent) -Parent
$projectJson = Join-Path $repoRoot 'project.json'
if (Test-Path $projectJson) {
    Copy-Item $projectJson -Destination $RootPath -Force
}

# 7. Создать data\ subdirs для runtime
$dataDir = Join-Path $RootPath 'data'
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'snapshots') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'xe') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'archives') | Out-Null

# 8. Очистка темпа
Remove-Item -Recurse -Force $tempExtract -ErrorAction SilentlyContinue
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "=== Anamnesis Kit $tag установлен в $RootPath ==="

# Запустить интерактивное меню
$runScript = Join-Path $RootPath 'Run-Anamnesis.ps1'
if (Test-Path $runScript) {
    Write-Output ""
    Write-Output "Запускаю интерактивное меню..."
    Start-Sleep -Seconds 1
    & $runScript -RootPath $RootPath
} else {
    Write-Output ""
    Write-Output "Запустить меню вручную:"
    Write-Output "  $runScript"
    Write-Output ""
    Write-Output "(Файл Run-Anamnesis.ps1 не найден в архиве — установлена старая версия kit'а?)"
}
