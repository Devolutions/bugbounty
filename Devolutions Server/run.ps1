$osType = docker info --format '{{.OSType}}'

if ($osType -ne "windows") {
    Write-Host "Error: Docker is not running in Windows Containers mode." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Docker is running in Windows Containers mode." -ForegroundColor Green
}

Write-Host "Starting docker compose..."
docker compose up -d

Write-Host "================================================"
Write-Host "| Devolutions Server is now up and running!    |"
Write-Host "| It can be accessed at https://localhost:5543 |"
Write-Host "================================================"