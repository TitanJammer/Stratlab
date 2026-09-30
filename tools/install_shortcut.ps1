# Makes the editor a desktop app:
#   assets\app-icon.png + assets\app.ico   the molly icon (drawn here, no download)
#   launch.vbs                             starts editor.ps1 with no console window at all
#   Desktop + Start Menu "Stratlab"         shortcut with the icon (pin it to the taskbar from there)
#   Startup "Stratlab (background)"         runs launch-bg.vbs at login so the server is always up
# Run:  powershell -ExecutionPolicy Bypass -File tools\install_shortcut.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'

# --- the icon: Riot's Incendiary ability icon on a dark rounded square ------------------------------
$src = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes((Join-Path $assets 'icons\ability-incendiary.png')))))
function Draw-Icon([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $r = [Math]::Max(2, [int]($size * 0.22)); $d = 2 * $r
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($size - $d, 0, $d, $d, 270, 90); $p.AddArc($size - $d, $size - $d, $d, $d, 0, 90); $p.AddArc(0, $size - $d, $d, $d, 90, 90); $p.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#161616'))), $p)
    $pad = [int]($size * 0.16)
    $g.DrawImage($src, $pad, $pad, $size - 2 * $pad, $size - 2 * $pad)
    $g.Dispose(); $bmp
}

$png = Join-Path $assets 'app-icon.png'
$big = Draw-Icon 256; $big.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)

# .ico with PNG-compressed frames (Vista+): 256, 64, 48, 32, 16
$ico = Join-Path $assets 'app.ico'
$frames = foreach ($sz in 256, 64, 48, 32, 16) { $b = Draw-Icon $sz; $ms = New-Object IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); @{ size = $sz; bytes = $ms.ToArray() } }
$out = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $w.Write([byte]$(if ($f.size -ge 256) { 0 } else { $f.size })); $w.Write([byte]$(if ($f.size -ge 256) { 0 } else { $f.size }))
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$f.bytes.Length); $w.Write([uint32]$offset)
    $offset += $f.bytes.Length
}
foreach ($f in $frames) { $w.Write($f.bytes) }
$w.Flush(); [IO.File]::WriteAllBytes($ico, $out.ToArray())
$big.Dispose()

# --- silent launcher --------------------------------------------------------------------------
$vbs = Join-Path $root 'launch.vbs'   # ships with the app and finds its folder on its own (nothing hard-coded)

# --- shortcuts --------------------------------------------------------------------------------
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
    foreach ($oldName in 'Lineups.lnk', 'Mollydex.lnk', 'The Lineup Lab.lnk') { $old = Join-Path $dir $oldName; if (Test-Path $old) { Remove-Item $old -Force } }   # earlier names
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Stratlab.lnk'))
    $lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $lnk.Arguments = "`"$vbs`""
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation = "$ico,0"
    $lnk.Description = 'Stratlab: Valorant strats, editor and in-game overlay'
    $lnk.Save()
    Write-Host "shortcut: $(Join-Path $dir 'Stratlab.lnk')"
}
Write-Host "icon: $ico"

# --- background server at login, so the app (or a taskbar pin of its window) opens any time ----------
$startup = [Environment]::GetFolderPath('Startup')
$oldBg = Join-Path $startup 'The Lineup Lab (background).lnk'; if (Test-Path $oldBg) { Remove-Item $oldBg -Force }   # earlier name
$bg = $shell.CreateShortcut((Join-Path $startup 'Stratlab (background).lnk'))
$bg.TargetPath = "$env:WINDIR\System32\wscript.exe"
$bg.Arguments = "`"$(Join-Path $root 'launch-bg.vbs')`""
$bg.WorkingDirectory = $root
$bg.IconLocation = "$ico,0"
$bg.Description = 'Starts the Stratlab server in the background at login (delete this shortcut to stop that)'
$bg.Save()
Write-Host "startup: $(Join-Path $startup 'Stratlab (background).lnk')"

# --- .stratlab packs open in the app when double-clicked (per user, no admin) --------------------------
$cls = 'HKCU:\Software\Classes'
New-Item -Path "$cls\.stratlab" -Force | Out-Null; Set-ItemProperty -Path "$cls\.stratlab" -Name '(default)' -Value 'Stratlab.Pack'
New-Item -Path "$cls\Stratlab.Pack\DefaultIcon" -Force | Out-Null; New-Item -Path "$cls\Stratlab.Pack\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$cls\Stratlab.Pack" -Name '(default)' -Value 'Stratlab pack'
Set-ItemProperty -Path "$cls\Stratlab.Pack\DefaultIcon" -Name '(default)' -Value "$ico,0"
Set-ItemProperty -Path "$cls\Stratlab.Pack\shell\open\command" -Name '(default)' -Value "`"$env:WINDIR\System32\wscript.exe`" `"$(Join-Path $root 'import.vbs')`" `"%1`""
Write-Host 'file type: .stratlab opens in Stratlab'

# --- files that came from the internet carry a "blocked" mark that makes Windows warn on every launch ----
Get-ChildItem $root -Recurse -File -Include *.ps1, *.vbs, *.bat, *.html, *.json | Unblock-File -ErrorAction SilentlyContinue
