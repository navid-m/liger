# Setup script for Liger VS Code Extension
# Run this to install dependencies and build the extension

Write-Host "Setting up Liger VS Code Extension..." -ForegroundColor Green

if (!(Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Node.js is not installed. Install Node.js first." -ForegroundColor Red
    exit 1
}

Write-Host "Node.js version: $(node --version)" -ForegroundColor Cyan

Write-Host "`nInstalling dependencies..." -ForegroundColor Green
npm install

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to install dependencies" -ForegroundColor Red
    exit 1
}

Write-Host "`nCompiling TypeScript..." -ForegroundColor Green
npm run compile

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to compile TypeScript" -ForegroundColor Red
    exit 1
}

Write-Host "`nPackaging extension..." -ForegroundColor Green
npm run package

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to package extension" -ForegroundColor Red
    exit 1
}

Write-Host "`n✓ Extension built successfully!" -ForegroundColor Green
Write-Host "`nTo install the extension, run:" -ForegroundColor Cyan
Write-Host "  code --install-extension liger-crystal-0.1.0.vsix" -ForegroundColor Yellow
