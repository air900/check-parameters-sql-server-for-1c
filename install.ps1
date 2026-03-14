# Bootstrap: irm https://raw.githubusercontent.com/air900/check-parameters-sql-server-for-1c/main/install.ps1 | iex
$ErrorActionPreference = "Stop"
$repoOwner = "air900"
$repoName  = "check-parameters-sql-server-for-1c"
$tempDir   = Join-Path ([System.IO.Path]::GetTempPath()) "1c-diagnostic-$([guid]::NewGuid().ToString('N').Substring(0,8))"
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "      DIAGNOSTIKA PostgreSQL FOR 1C:ENTERPRISE" -ForegroundColor Cyan
Write-Host "                      audit-reshenie.ru" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Loading..." -ForegroundColor White
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloadUrl = $null
    try {
        $releaseUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
        $headers = @{ "User-Agent" = "1C-Diagnostic-Installer" }
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if ($asset) {
            $downloadUrl = $asset.browser_download_url
            Write-Host "  Release: $($release.tag_name)" -ForegroundColor Green
        }
    }
    catch { }
    if (-not $downloadUrl) {
        $downloadUrl = "https://github.com/$repoOwner/$repoName/archive/refs/heads/main.zip"
        Write-Host "  Downloading from main branch..." -ForegroundColor Yellow
    }
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "1c-diagnostic.zip"
    Write-Host "  URL: $downloadUrl" -ForegroundColor Gray
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Write-Host "  Extracting..." -ForegroundColor Gray
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    $entryPoint = Get-ChildItem -Path $tempDir -Recurse -Filter "Invoke-1CDiagnostic.ps1" | Select-Object -First 1
    if (-not $entryPoint) { throw "Invoke-1CDiagnostic.ps1 not found in archive." }
    Write-Host "  OK! Starting diagnostic..." -ForegroundColor Green
    Write-Host ""
    & $entryPoint.FullName
}
catch {
    Write-Host ""
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host "  Manual download: https://github.com/$repoOwner/$repoName/releases" -ForegroundColor Yellow
    Write-Host ""
}
finally {
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
