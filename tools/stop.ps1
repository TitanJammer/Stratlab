# Stops Stratlab's server and overlay (used by the installer before an upgrade and by the uninstaller).
$here = Split-Path -Parent $PSScriptRoot
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'editor\.ps1|overlay\.ps1' -and $_.CommandLine -like "*$here*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $here 'overlay.pid') -ErrorAction SilentlyContinue
