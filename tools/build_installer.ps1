# Builds dist\Stratlab-Setup-<version>.exe from installer\stratlab.iss with Inno Setup 6.
#   powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
# The version comes from version.json. Inno Setup (free): winget install JRSoftware.InnoSetup
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ver = (Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
if ($ver -notmatch '^\d+\.\d+\.\d+$') { throw "version.json has no x.y.z version ('$ver')" }
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue; if ($cmd) { $iscc = $cmd.Source } }
if (-not $iscc) { throw 'Inno Setup 6 not found. Install it (free) with:  winget install JRSoftware.InnoSetup' }
New-Item -ItemType Directory -Force (Join-Path $root 'dist') | Out-Null
& $iscc "/DAppVersion=$ver" (Join-Path $root 'installer\stratlab.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }
$out = Join-Path $root "dist\Stratlab-Setup-$ver.exe"
# the checksum the in-app updater verifies the download against: upload it to the release next to the exe
$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
"$hash  Stratlab-Setup-$ver.exe" | Set-Content "$out.sha256" -Encoding ASCII
Write-Host "built $out ($([Math]::Round((Get-Item $out).Length / 1MB, 1)) MB) and $out.sha256"
Write-Host "release: tag v$ver, attach both files"
