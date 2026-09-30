# Builds dist\Stratlab-<version>.zip: the app without any of your strats, plus Install.bat. Needs nothing
# installed (no Inno Setup). Whoever gets it unzips it anywhere and runs Install.bat once.
#   powershell -ExecutionPolicy Bypass -File tools\build_portable.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ver = (Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
$stage = Join-Path $root 'dist\stage'; $app = Join-Path $stage 'Stratlab'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $app, "$app\data", "$app\assets", "$app\tools", "$app\web" | Out-Null

# the same file set the installer ships: app, official art, game data; never the user's library or pictures
foreach ($f in 'editor.ps1', 'overlay.ps1', 'launch.vbs', 'launch-bg.vbs', 'overlay.vbs', 'import.vbs', 'Start Overlay.bat', 'version.json', 'README.md') { Copy-Item (Join-Path $root $f) $app }
Copy-Item (Join-Path $root 'web\*') "$app\web" -Recurse
foreach ($d in 'icons', 'maps', 'roles') { Copy-Item (Join-Path $root "assets\$d") "$app\assets\$d" -Recurse }
Copy-Item (Join-Path $root 'assets\app.ico'), (Join-Path $root 'assets\app-icon.png') "$app\assets"
Copy-Item (Join-Path $root 'data\game.json') "$app\data"
Copy-Item (Join-Path $root 'installer\lineups.empty.json') "$app\data\lineups.json"
Copy-Item (Join-Path $root 'installer\packs.empty.json') "$app\data\packs.json"
Copy-Item (Join-Path $root 'installer\config.default.json') "$app\config.json"
foreach ($t in 'install_shortcut.ps1', 'stop.ps1', 'get_official_art.ps1') { Copy-Item (Join-Path $root "tools\$t") "$app\tools" }
@"
@echo off
rem Sets Stratlab up from this folder: shortcuts, start at login, .stratlab file type. Run it once.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install_shortcut.ps1"
if errorlevel 1 ( echo Setup hit a problem. & pause & exit /b 1 )
start "" wscript.exe "%~dp0launch-bg.vbs"
start "" wscript.exe "%~dp0launch.vbs"
echo Stratlab is set up. You can close this window.
timeout /t 4 >nul
"@ | Set-Content "$app\Install.bat" -Encoding ASCII
@"
Stratlab $ver

1. Unzip this folder somewhere it can stay (for example Documents\Stratlab). Do not run it from inside the zip.
2. Run Install.bat once. It adds the shortcuts, starts Stratlab at login, and makes .stratlab packs open in the app.
   Windows may ask whether to open a file from the internet: allow it.
3. Open Stratlab from the desktop or Start menu. The in-game overlay is the Overlay button at the top.

Nothing else to install: Stratlab runs on the PowerShell and Edge that come with Windows.
Your strats stay in this folder (data\ and assets\). To move on to a newer version, unzip it over this folder.
"@ | Set-Content "$app\README-FIRST.txt" -Encoding UTF8
$zip = Join-Path $root "dist\Stratlab-$ver.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $app -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force
Write-Host "built $zip ($([Math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
