# Check Docker OSType
try {
    $osType = docker info --format '{{.OSType}}' 2>$null
} catch {
    Write-Host "Error: Failed to get Docker information. Is Docker running?" -ForegroundColor Red
    exit 1
}

if ($osType -ne "windows") {
    Write-Host "Error: Docker is not running in Windows Containers mode." -ForegroundColor Red
    exit 1
} else {
    Write-Host "✓ Docker is running in Windows Containers mode." -ForegroundColor Green
}

# Check Windows version
$releaseId = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction SilentlyContinue

if ($releaseId.DisplayVersion -ne "24H2") {
    Write-Host "⚠ Warning: Detected Windows version '$($releaseId.DisplayVersion)'. Supported version is 24H2." -ForegroundColor Yellow
} else {
    Write-Host "✓ Windows version is supported (24H2)." -ForegroundColor Green
}

# Start Docker Compose
Write-Host "`nStarting Docker Compose..." -ForegroundColor Cyan

try {
    docker compose up -d
    Write-Host "================================================"
    Write-Host "| Devolutions Server is now up and running!    |"
    Write-Host "| It can be accessed at https://localhost:5543 |"
    Write-Host "================================================"
} catch {
    Write-Host "Error: Failed to start Docker Compose." -ForegroundColor Red
    exit 1
}
