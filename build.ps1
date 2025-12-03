# Build script for Windows PowerShell
# Compiles Go binaries for AWS Lambda (Linux AMD64)

Write-Host "Building Go binaries for AWS Lambda..." -ForegroundColor Cyan

# Set environment for Linux cross-compilation
$env:GOOS = "linux"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"

# Build Ingest Lambda
Write-Host "Building ingest service..." -ForegroundColor Yellow
go build -tags lambda.norpc -ldflags="-s -w" -o bootstrap ./ingest/main.go
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build ingest service" -ForegroundColor Red
    exit 1
}
Compress-Archive -Path bootstrap -DestinationPath ingest.zip -Force
Remove-Item bootstrap

# Build Worker Lambda
Write-Host "Building worker service..." -ForegroundColor Yellow
go build -tags lambda.norpc -ldflags="-s -w" -o bootstrap ./worker/main.go
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build worker service" -ForegroundColor Red
    exit 1
}
Compress-Archive -Path bootstrap -DestinationPath worker.zip -Force
Remove-Item bootstrap

# Reset environment
$env:GOOS = ""
$env:GOARCH = ""

Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  - ingest.zip" -ForegroundColor White
Write-Host "  - worker.zip" -ForegroundColor White