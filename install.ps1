#Requires -Version 5.1
# EFMS installer, windows
# usage: PowerShell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Say  ($t) { Write-Host "== $t" -ForegroundColor Cyan }
function Ok   ($t) { Write-Host "ok   $t" -ForegroundColor Green }
function Wn   ($t) { Write-Host "warn $t" -ForegroundColor Yellow }
function Er   ($t) { Write-Host "err  $t" -ForegroundColor Red }
function Hint ($t) { Write-Host "     $t" -ForegroundColor DarkGray }
function Die  ($t) { Er $t; exit 1 }

function Ask($q, $def = 'y') {
    $h = if ($def -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $r = Read-Host "$q $h"
    if (-not $r) { $r = $def }
    return $r -match '^[Yy]'
}

function NewHex {
    $b = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return -join ($b | ForEach-Object { $_.ToString('x2') })
}

function NewPw {
    $chars = [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $b = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return -join ($b | ForEach-Object { $chars[$_ % $chars.Length] })
}

function PortBusy($p) {
    try {
        $null = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop
        return $true
    } catch { return $false }
}

function ReadSecret($q) {
    $s = Read-Host -Prompt $q -AsSecureString
    return [System.Net.NetworkCredential]::new('', $s).Password
}

Say "docker"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Hint "install docker desktop from https://docs.docker.com/desktop/install/windows-install/"
    Die "docker not found"
}
$dv = (docker --version) -split ' '
Ok "docker $($dv[2].TrimEnd(','))"

$cv = $null
try { $cv = (docker compose version --short 2>$null) } catch {}
if (-not $cv) { Die "docker compose plugin missing, update docker desktop" }
Ok "compose $($cv.Trim())"

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Hint "open docker desktop from the start menu, wait for it to report running, then re-run."
    Die "docker daemon not running"
}
Ok "daemon up"

Say "config"

if (-not (Test-Path .env.example)) { Die ".env.example missing, run this from the EFMS-deploy directory" }

$writeEnv = $true
if (Test-Path .env) {
    if (Ask "existing .env found, keep it?" 'y') {
        $writeEnv = $false
        Ok "keeping existing .env"
    } else {
        Wn "existing .env will be overwritten"
    }
}

if ($writeEnv) {
    $dbUser = 'efms'
    $dbName = 'efms_db'

    if (Ask "generate a random jwt secret?" 'y') {
        $jwtSecret = NewHex
        Ok "generated (64 chars)"
    } else {
        while ($true) {
            $jwtSecret = ReadSecret "jwt secret (32+ chars)"
            if ($jwtSecret.Length -ge 32) { Ok "accepted ($($jwtSecret.Length) chars)"; break }
            Wn "need at least 32 chars"
        }
    }

    if (Ask "generate a random db password?" 'y') {
        $dbPass = NewPw
        Ok "generated (24 chars)"
    } else {
        while ($true) {
            $dbPass = ReadSecret "db password (8+ chars)"
            if ($dbPass.Length -ge 8) { Ok "accepted"; break }
            Wn "need at least 8 chars"
        }
    }

    $apiUrl = Read-Host "api url for the browser [http://localhost:8080]"
    if (-not $apiUrl) { $apiUrl = 'http://localhost:8080' }
    if ($apiUrl -notmatch '^https?://') {
        $apiUrl = "http://$apiUrl"
        Wn "no scheme given, using $apiUrl"
    }

    $fp = Read-Host "frontend port [3000]"
    if (-not $fp) { $fp = '3000' }
    $frontendPort = [int]$fp
    if (PortBusy $frontendPort) { Wn "port $frontendPort looks busy" }

    $bp = Read-Host "backend port [8080]"
    if (-not $bp) { $bp = '8080' }
    $backendPort = [int]$bp
    if (PortBusy $backendPort) { Wn "port $backendPort looks busy" }

    Copy-Item -Path .env.example -Destination .env -Force
    $envContent = Get-Content .env -Raw
    $envContent = $envContent -replace '(?m)^DB_USER=.*$', "DB_USER=$dbUser"
    $envContent = $envContent -replace '(?m)^DB_PASS=.*$', "DB_PASS=$dbPass"
    $envContent = $envContent -replace '(?m)^DB_NAME=.*$', "DB_NAME=$dbName"
    $envContent = $envContent -replace '(?m)^JWT_SECRET=.*$', "JWT_SECRET=$jwtSecret"
    $envContent = $envContent -replace '(?m)^API_URL=.*$', "API_URL=$apiUrl"
    $envContent = $envContent -replace '(?m)^FRONTEND_PORT=.*$', "FRONTEND_PORT=$frontendPort"
    $envContent = $envContent -replace '(?m)^BACKEND_PORT=.*$', "BACKEND_PORT=$backendPort"
    Set-Content -Path .env -Value $envContent -Encoding utf8
    Ok "wrote .env from .env.example"
}

$envMap = @{}
if (Test-Path .env) {
    Get-Content .env | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') { $envMap[$matches[1]] = $matches[2] }
    }
}
$apiUrl       = if ($envMap.API_URL)       { $envMap.API_URL }       else { 'http://localhost:8080' }
$frontendPort = if ($envMap.FRONTEND_PORT) { $envMap.FRONTEND_PORT } else { '3000' }
$backendPort  = if ($envMap.BACKEND_PORT)  { $envMap.BACKEND_PORT }  else { '8080' }
$dbUser       = if ($envMap.DB_USER)       { $envMap.DB_USER }       else { 'efms' }
$dbName       = if ($envMap.DB_NAME)       { $envMap.DB_NAME }       else { 'efms_db' }
$backendTag   = if ($envMap.BACKEND_TAG)   { $envMap.BACKEND_TAG }   else { 'latest' }
$frontendTag  = if ($envMap.FRONTEND_TAG)  { $envMap.FRONTEND_TAG }  else { 'latest' }
$backendImage = if ($envMap.BACKEND_IMAGE) { $envMap.BACKEND_IMAGE } else { 'yonyc/efms-backend' }
$frontendImage= if ($envMap.FRONTEND_IMAGE){ $envMap.FRONTEND_IMAGE }else { 'yonyc/efms-frontend' }

Say "summary"
Write-Host "frontend   http://localhost:$frontendPort"
Write-Host "backend    $apiUrl"
Write-Host "database   $dbName as $dbUser, host port 5432"
Write-Host "images     ${backendImage}:${backendTag}"
Write-Host "           ${frontendImage}:${frontendTag}"
Write-Host "           postgis/postgis:15-3.3"
Write-Host ""

if (-not (Ask "go?" 'y')) {
    Hint "ok, run 'docker compose up -d' yourself when ready."
    exit 0
}

Say "pull"
docker compose pull
if ($LASTEXITCODE -ne 0) { Die "pull failed" }

Say "up"
docker compose up -d
if ($LASTEXITCODE -ne 0) { Die "compose up failed, check 'docker compose logs'" }

Say "waiting for backend to be ready..."
for ($i = 0; $i -lt 60; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$backendPort/actuator/health" -UseBasicParsing -ErrorAction Stop
        if ($resp.Content -match '"status"\s*:\s*"UP"') { break }
    } catch {}
    Start-Sleep -Seconds 2
}

Say "waiting for frontend to be ready..."
for ($i = 0; $i -lt 30; $i++) {
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:$frontendPort" -UseBasicParsing -ErrorAction Stop
        break
    } catch {
        Start-Sleep -Seconds 2
    }
}

Say "done"
docker compose ps
Write-Host ""
Write-Host "open http://localhost:$frontendPort"
Write-Host ""
Write-Host "logs:   docker compose logs -f"
Write-Host "stop:   docker compose down"
Write-Host "update: docker compose pull && docker compose up -d"
Write-Host "wipe:   docker compose down -v"
