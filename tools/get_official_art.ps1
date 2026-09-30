# Downloads official Valorant art from valorant-api.com (a community mirror of Riot's game assets):
#   assets/maps/<map>.png            map banner, drawn darkened behind the MAP block
#   assets/icons/agent-<agent>.png   agent portrait for the AGENT block
#   assets/icons/ability-<name>.png  ability icon shown next to the lineup title
# Existing files are replaced unless -KeepExisting is given. Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File tools\get_official_art.ps1
param([switch]$KeepExisting)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls13'
$root = Split-Path -Parent $PSScriptRoot
$mapsDir = Join-Path $root 'assets\maps'; $iconsDir = Join-Path $root 'assets\icons'
New-Item -ItemType Directory -Force $mapsDir, $iconsDir | Out-Null

function Slug([string]$s, [bool]$keepDash = $false) {
    $t = $s.ToLower()
    if ($keepDash) { ($t -replace '\s+', '-') -replace '[^a-z0-9-]', '' } else { $t -replace '[^a-z0-9]', '' }
}
$done = 0; $skipped = 0
function Fetch([string]$url, [string]$path) {
    if ($KeepExisting -and (Test-Path $path)) { $script:skipped++; return }
    Invoke-WebRequest -Uri $url -OutFile $path -TimeoutSec 30 -UseBasicParsing
    $script:done++
    Write-Host ("{0,-46} {1,7:N0} bytes" -f (Split-Path $path -Leaf), (Get-Item $path).Length)
}

Write-Host '== maps'
$maps = (Invoke-RestMethod -Uri 'https://valorant-api.com/v1/maps' -TimeoutSec 20).data
foreach ($m in $maps) {
    if (-not $m.mapUrl -or -not $m.listViewIcon) { continue }
    if ($m.displayName -match 'Range|Basic Training|Drift|Kasbah|Piazza|District|Glitch|Skyline|Gauntlet|Skirmish') { continue }   # game-mode maps, not standard ones
    Fetch $m.listViewIcon (Join-Path $mapsDir "$(Slug $m.displayName).png")
}

Write-Host '== agents + abilities'
$agents = (Invoke-RestMethod -Uri 'https://valorant-api.com/v1/agents?isPlayableCharacter=true' -TimeoutSec 20).data
foreach ($r in ($agents | ForEach-Object { $_.role } | Where-Object { $_ } | Sort-Object displayName -Unique)) {   # the four role icons
    Fetch $r.displayIcon (Join-Path $iconsDir "role-$(Slug $r.displayName).png")
}
foreach ($a in $agents) {
    if ($a.displayIcon) { Fetch $a.displayIcon (Join-Path $iconsDir "agent-$(Slug $a.displayName).png") }
    foreach ($ab in $a.abilities) {
        if (-not $ab.displayIcon -or -not $ab.displayName) { continue }
        Fetch $ab.displayIcon (Join-Path $iconsDir "ability-$(Slug $ab.displayName $true).png")
    }
}
Write-Host "done: $done file(s) downloaded, $skipped kept"
