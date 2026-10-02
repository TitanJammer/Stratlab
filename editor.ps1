# Stratlab (formerly The Lineup Lab): a small local web app. This script is the backend (files + JSON), the UI is
# web\editor.html, opened in an Edge app window. Nothing to install.
# The server keeps running after the window closes, so the app (and any taskbar pin of its window)
# can be reopened at any time. Launching it again while it runs just opens another window to it.
#   GET  /                 the UI
#   GET  /api/state        maps, agents (with abilities), lineups
#   POST /api/save         { lineup } -> writes data\lineups.json, saves pictures to assets\
#   POST /api/delete       { id }
#   GET  /api/ping         heartbeat from the page
#   GET  /api/monitors     the screens (numbered like the overlay) and the overlay's current one
#   POST /api/monitor      { monitor } -> config.json; a running overlay moves on its own
#   GET  /assets/...       pictures and icons
#   -Background            start the server only, no window (used at login)
param([int]$Port = 47821, [switch]$NoBrowser, [switch]$Background, [switch]$AtLogin, [string]$Import)   # -AtLogin: started by the Startup shortcut (honours "Start with Windows")   # -Import <pack>: open the app with that pack's import preview

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataPath = Join-Path $root 'data\lineups.json'
$gamePath = Join-Path $root 'data\game.json'
$assets   = Join-Path $root 'assets'
$html     = Join-Path $root 'web\editor.html'
# version.json: { version: "x.y.z", repo: "owner/name" }; the app shows the version and, with a repo set,
# checks GitHub Releases for a newer one
$APP = try { Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json } catch { [pscustomobject]@{ version = '0.0.0'; repo = '' } }
$pendingPack = $null   # a pack opened from Explorer, waiting for the app window to show its preview
function Slug([string]$s) { ($s.ToLower() -replace '[^a-z0-9]', '') }
function Slug-Dash([string]$s) { (($s.ToLower() -replace '\s+', '-') -replace '[^a-z0-9-]', '') }

function Read-Json([string]$path) { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }

# overlay monitor: the screens in the same order the overlay uses (Forms.Screen.AllScreens, numbered from 1),
# and the choice saved to config.json "monitor"; a running overlay notices the file change and moves
Add-Type -AssemblyName System.Windows.Forms
$configPath = Join-Path $root 'config.json'
# Valorant's display mode, read from the game's own settings file (read only, nothing touches the game):
# 0 = Fullscreen (the game draws over the overlay), 1 = Windowed Fullscreen, 2 = Windowed, $null = unknown
function Get-DisplayMode {
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
        if (-not (Test-Path $dir)) { return $null }
        $ini = Get-ChildItem $dir -Recurse -Filter 'GameUserSettings.ini' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\WindowsClient\\' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $ini) { return $null }
        $sec = ''; $mode = $null
        foreach ($line in [IO.File]::ReadAllLines($ini.FullName)) {
            if ($line -match '^\[(.+)\]') { $sec = $Matches[1]; continue }
            if ($sec -eq '/Script/ShooterGame.ShooterGameUserSettings' -and $line -match '^FullscreenMode=(\d)') { $mode = [int]$Matches[1] }
        }
        $mode
    } catch { $null }
}
function Get-Monitors {
    $cur = 1; if (Test-Path $configPath) { try { $c = Read-Json $configPath; if ($c.monitor) { $cur = [int]$c.monitor } } catch {} }
    $i = 0
    $list = foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
        $i++; $b = $sc.Bounds
        [ordered]@{ n = $i; x = $b.X; y = $b.Y; w = $b.Width; h = $b.Height; primary = $sc.Primary }
    }
    [ordered]@{ monitors = @($list); current = $(if ($cur -ge 1 -and $cur -le $i) { $cur } else { 1 }) }
}
function Set-Monitor($req) {
    $n = [int]$req.monitor; $count = [System.Windows.Forms.Screen]::AllScreens.Count
    if ($n -lt 1 -or $n -gt $count) { throw "No monitor $n" }
    $c = if (Test-Path $configPath) { Read-Json $configPath } else { [pscustomobject]@{} }
    if ($c.PSObject.Properties['monitor']) { $c.monitor = $n } else { $c | Add-Member -NotePropertyName monitor -NotePropertyValue $n }
    $c | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
    [ordered]@{ ok = $true; current = $n }
}
# overlay settings the app exposes (config.json): the card's width (its size: everything scales with it,
# 372 = the design size) and the screen corner it sits in. A running overlay lays itself out at start, so a
# width change restarts it (the corner and the monitor it picks up live from the file).
function Get-Settings {
    $c = if (Test-Path $configPath) { try { Read-Json $configPath } catch { $null } } else { $null }
    $w = 372; if ($c -and "$($c.width)" -match '^\d+$') { $w = [int]$c.width }
    $a = 'top-right'; if ($c -and "$($c.anchor)" -match '^(top|bottom)-(left|right)$') { $a = [string]$c.anchor }
    $auto = -not ($c -and $c.PSObject.Properties['autostart'] -and $c.autostart -eq $false)   # start with Windows: on unless turned off
    [ordered]@{ width = $w; anchor = $a; autostart = $auto }
}
function Overlay-Pid { $pf = Join-Path $root 'overlay.pid'; if (Test-Path $pf) { try { (Get-Process -Id ([int](Get-Content $pf -Raw).Trim()) -ErrorAction Stop).Id } catch { $null } } else { $null } }
function Toggle-Overlay {   # start it, or stop it; returns whether it is now running
    $opid = Overlay-Pid
    if ($opid) { Stop-Process -Id $opid -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $root 'overlay.pid') -ErrorAction SilentlyContinue; return $false }
    Start-Process wscript.exe -ArgumentList "`"$(Join-Path $root 'overlay.vbs')`"" -WorkingDirectory $root   # via .vbs: no console flash
    $true
}
function Restart-Overlay {
    $opid = Overlay-Pid; if (-not $opid) { return $false }
    Stop-Process -Id $opid -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $root 'overlay.pid') -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    Start-Process wscript.exe -ArgumentList "`"$(Join-Path $root 'overlay.vbs')`"" -WorkingDirectory $root
    $true
}
function Set-Settings($req) {
    $c = if (Test-Path $configPath) { Read-Json $configPath } else { [pscustomobject]@{} }
    $set = { param($k, $v) if ($c.PSObject.Properties[$k]) { $c.$k = $v } else { $c | Add-Member -NotePropertyName $k -NotePropertyValue $v } }
    $restart = $false
    if ($null -ne $req.width) {
        $w = [int][Math]::Round([double]$req.width); if ($w -lt 280 -or $w -gt 900) { throw 'Width must be between 280 and 900' }
        $old = (Get-Settings).width; & $set 'width' $w; if ($w -ne $old) { $restart = $true }
    }
    if ($req.anchor) { $a = [string]$req.anchor; if ($a -notmatch '^(top|bottom)-(left|right)$') { throw 'Bad corner' }; & $set 'anchor' $a }
    if ($null -ne $req.autostart) { & $set 'autostart' ([bool]$req.autostart) }
    $c | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
    $restarted = if ($restart) { Restart-Overlay } else { $false }
    $out = Get-Settings; $out['restarted'] = [bool]$restarted; $out
}
function Write-Data($data) { $data | ConvertTo-Json -Depth 10 | Set-Content $dataPath -Encoding UTF8 }

function Get-State {
    $data = Read-Json $dataPath; $game = Read-Json $gamePath
    $maps = foreach ($m in $game.maps) {
        $img = "assets/maps/$(Slug $m).png"
        $sites = if ($game.sites -and $game.sites.$m) { @($game.sites.$m) } else { @('A', 'B') }
        [ordered]@{ name = $m; image = $(if (Test-Path (Join-Path $root $img)) { "/$img" } else { $null }); sites = $sites; ranked = (@($game.ranked) -contains $m) }
    }
    $agents = foreach ($a in $game.agents) {
        $p = "assets/icons/agent-$(Slug $a.name).png"
        [ordered]@{
            name = $a.name; role = $a.role
            portrait = $(if (Test-Path (Join-Path $root $p)) { "/$p" } else { $null })
            abilities = @(foreach ($ab in $a.abilities) { $ic = "assets/icons/ability-$(Slug-Dash $ab).png"; [ordered]@{ name = $ab; icon = $(if (Test-Path (Join-Path $root $ic)) { "/$ic" } else { $null }) } })
        }
    }
    [ordered]@{ maps = @($maps); agents = @($agents); lineups = @($data.lineups); packs = @(Get-PacksState) }
}

function Save-Lineup($req) {
    $data = Read-Json $dataPath
    $L = $req.lineup
    foreach ($f in 'map', 'agent', 'site', 'title') { if (-not $L.$f) { throw "Missing $f" } }
    # strat types (keep in sync with TYPES in web\editor.html); anything unknown is treated as a post-plant
    $type = ([string]$L.type).ToLower()
    if (@('post-plant', 'entry', 'smoke', 'one-way', 'flash', 'recon', 'setup', 'deny') -notcontains $type) { $type = 'post-plant' }
    $id = if ($L.id) { [string]$L.id } else {
        $base = "$(Slug $L.agent)-$(Slug $L.map)-$(([string]$L.site).ToLower())-$($type -replace '-', '')"
        $n = 1; while ($data.lineups | Where-Object { $_.id -eq "$base-$n" }) { $n++ }
        "$base-$n"
    }
    # steps: 1 to 5, each with its own name (default names per type, keep in sync with STEP_DEFAULTS in
    # web\editor.html) and an optional short note ("jump throw", "1 bounce"...)
    $defaults = switch ($type) { 'post-plant' { @('Plant', 'Stand', 'Aim') } 'setup' { @('Util 1', 'Util 2', 'Util 3') } default { @('Stand', 'Aim', 'Result') } }
    $reqSteps = @($L.steps)
    if ($reqSteps.Count -lt 1 -or $reqSteps.Count -gt 5) { throw 'A strat needs 1 to 5 steps' }
    $steps = @()
    for ($i = 0; $i -lt $reqSteps.Count; $i++) {
        $s = $reqSteps[$i]
        $label = (([string]$s.name) -replace '[^\p{L}\p{N} \-]', '').Trim()
        if (-not $label) { $label = $(if ($i -lt $defaults.Count) { $defaults[$i] } else { "Step $($i + 1)" }) }
        if ($label.Length -gt 16) { $label = $label.Substring(0, 16).Trim() }
        $note = ([string]$s.notes).Trim(); if ($note.Length -gt 60) { $note = $note.Substring(0, 60).Trim() }
        $fileName = (($label.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')); if (-not $fileName) { $fileName = "step$($i + 1)" }
        $srcs = @(); $k = 0
        $zooms = New-Object System.Collections.Generic.List[object]   # one entry per picture: zoom settings or $null
        $times = New-Object System.Collections.Generic.List[object]   # one entry per picture: seconds before the next picture
        foreach ($p in @($s.pics)) {
            $k++
            $z = $null
            if ($p.zoom) {
                $z = [ordered]@{ factor = [double]$p.zoom.factor; x = [Math]::Round([double]$p.zoom.x, 3); y = [Math]::Round([double]$p.zoom.y, 3)
                                 mode = $(if ([string]$p.zoom.mode -eq 'hold') { 'hold' } else { 'pulse' }) }   # pulse = in and out, hold = stays zoomed
            }
            $zooms.Add($z)
            $times.Add($(if ($p.dur) { [Math]::Round([double]$p.dur, 1) } else { 1.8 }))
            if ($p.src) { $srcs += [string]$p.src; continue }                       # existing picture, kept
            $ext = if (([string]$p.data) -match '^data:image/gif[;,]') { 'gif' } else { 'png' }   # a clip arrives as a GIF and stays one
            $dest = Join-Path $assets "$id-$fileName-$k.$ext"
            $n = $k; while (Test-Path $dest) { $n++; $dest = Join-Path $assets "$id-$fileName-$n.$ext" }
            $b64 = ([string]$p.data) -replace '^data:[^,]*,', ''
            [IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String($b64))
            $srcs += ('assets/' + (Split-Path $dest -Leaf))
        }
        if ($srcs.Count -eq 0) { throw "$label needs at least one picture" }
        # label = the step's name (the overlay shows it), notes = its short note; caption kept for older readers
        # an older strat's how-to text ("legacy", never shown in the overlay) stays in the caption when no note replaces it
        $legacy = ([string]$s.legacy).Trim()
        $step = [ordered]@{ type = 'png'; src = $(if ($srcs.Count -eq 1) { $srcs[0] } else { $srcs }); label = $label; notes = $note
                            caption = $(if ($note) { "${label}: $note" } elseif ($legacy) { "${label}: $legacy" } else { $label }) }
        # NOTE: indexer syntax. Adding a new key that holds an array via property syntax ($step.picZoom = ...)
        # throws "Argument types do not match" on an [ordered] dictionary.
        if ($srcs.Count -eq 1) { if ($zooms[0]) { $step['zoom'] = $zooms[0] } }              # one picture: plain "zoom"
        else {
            $step['picZoom'] = [object[]]$zooms.ToArray()                                    # several: each picture's own zoom
            $step['picTime'] = [object[]]$times.ToArray()                                    # and its own seconds before the next
        }
        $steps += [pscustomobject]$step
    }
    $new = [pscustomobject]([ordered]@{
        id = $id; map = [string]$L.map; agent = [string]$L.agent; type = $type
        option = "$($L.site) $type"; site = [string]$L.site
        side = $(if ($type -ne 'post-plant' -and @('Defense', 'Both') -contains [string]$L.side) { [string]$L.side } else { 'Attack' })   # post-plants are always attack
        # Sova-style bolts: bounces 0-2 and charge 0-3, or $null when not set / not a bolt
        bounces = $(if ($null -ne $L.bounces -and "$($L.bounces)" -match '^[0-2]$') { [int]$L.bounces } else { $null })
        charge = $(if ($null -ne $L.charge -and "$($L.charge)" -match '^[0-3]$') { [int]$L.charge } else { $null })
        ability = [string]$L.ability; title = ([string]$L.title).Trim(); difficulty = [string]$L.difficulty
        # speed is optional and only means something for a post-plant; 'average' is the old name of 'moderate'
        speed = $(if ($type -ne 'post-plant') { '' } else { switch (([string]$L.speed).ToLower()) { 'fast' { 'fast' } 'moderate' { 'moderate' } 'average' { 'moderate' } 'slow' { 'slow' } default { '' } } })
        steps = $steps
    })
    Register-Refs $data $new
    $existing = $data.lineups | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($existing -and $existing.pack) { $new | Add-Member -NotePropertyName pack -NotePropertyValue $existing.pack }   # an imported strat stays linked to its pack
    if ($existing) { $data.lineups = @($data.lineups | ForEach-Object { if ($_.id -eq $id) { $new } else { $_ } }) }
    else { $data.lineups = @($data.lineups) + $new }
    Write-Data $data
    [ordered]@{ ok = $true; id = $id }
}
# the overlay reads maps / agents / ability icons from lineups.json too: make sure a strat's are listed
function Register-Refs($data, $new) {
    if (@($data.maps) -notcontains $new.map) { $data.maps = @($data.maps) + $new.map }
    if (-not ($data.agents | Where-Object { $_.name -eq $new.agent })) { $data.agents = @($data.agents) + [pscustomobject]@{ name = $new.agent; icon = "assets/icons/agent-$(Slug $new.agent).png" } }
    if ($new.ability -and -not $data.abilities.PSObject.Properties[$new.ability]) { $data.abilities | Add-Member -NotePropertyName $new.ability -NotePropertyValue "assets/icons/ability-$(Slug-Dash $new.ability).png" }
}

# --- strat packs (.stratlab; packs made as .lineuplab before the rename are still accepted) ----------
# A pack is a zip: manifest.json (format, id, name, created, counts), strats.json (the strats, their
# pictures pointing at pics/N.jpg) and pics/ (pictures re-encoded as JPEG, at most 1280 wide).
# Import only ever accepts those three things; every field is re-checked and rebuilt (never copied as-is),
# every picture must decode as an image, and sizes / counts are capped. Nothing in a pack is executed.
Add-Type -AssemblyName System.IO.Compression, System.Drawing
$PACK_MAX = 60MB; $PACK_MAX_PIC = 8MB; $PACK_MAX_JSON = 4MB; $PACK_MAX_ENTRIES = 600; $PACK_MAX_STRATS = 200
$PACK_TYPES = @('post-plant', 'entry', 'smoke', 'one-way', 'flash', 'recon', 'setup', 'deny')

function Pic-Jpeg([string]$file) {   # any picture -> JPEG bytes, quality 85, at most 1280 wide
    $img = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($file))))
    try {
        $sc = [Math]::Min(1.0, 1280.0 / $img.Width)
        $bmp = New-Object System.Drawing.Bitmap ([int][Math]::Max(1, $img.Width * $sc)), ([int][Math]::Max(1, $img.Height * $sc))
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, 0, 0, $bmp.Width, $bmp.Height); $g.Dispose()
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]85)
        $out = New-Object IO.MemoryStream; $bmp.Save($out, $codec, $ep); $bmp.Dispose()
        , $out.ToArray()
    } finally { $img.Dispose() }
}
function Zip-Add($zip, [string]$name, [byte[]]$bytes) {
    $en = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal); $st = $en.Open(); try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Dispose() }
}
# --- pack definitions (data\packs.json): every pack you made or imported, with its member strats -------
# { id, name, description, author, kind ('own' | 'imported'), created, updated, ids }. Home filters by these;
# re-exporting an own pack keeps its id, so whoever imports the new file gets updates instead of copies.
$packsPath = Join-Path $root 'data\packs.json'
function Clip-Text($v, [int]$len) { $t = (([string]$v).Trim() -replace '[\x00-\x08\x0b\x0c\x0e-\x1f]', ''); if ($t.Length -gt $len) { $t.Substring(0, $len).Trim() } else { $t } }
function Read-Packs { if (Test-Path $packsPath) { $p = Read-Json $packsPath; @($p.packs | ForEach-Object { $_ } | Where-Object { $_ }) } else { @() } }
function Write-Packs($list) { [pscustomobject]@{ packs = @($list) } | ConvertTo-Json -Depth 6 | Set-Content $packsPath -Encoding UTF8 }
function Get-PacksState {   # for the app: member ids trimmed to strats that still exist
    $data = Read-Json $dataPath; $have = @{}; foreach ($L in @($data.lineups)) { $have[[string]$L.id] = $true }
    # pscustomobject, not [ordered]: a dictionary written from inside foreach gets unrolled into its entries
    @(foreach ($p in Read-Packs) {
        [pscustomobject]([ordered]@{ id = $p.id; name = $p.name; description = [string]$p.description; author = [string]$p.author; kind = $p.kind; created = [string]$p.created; updated = [string]$p.updated; stamp = [string]$p.stamp
                    ids = [object[]]@(@($p.ids) | ForEach-Object { [string]$_ } | Where-Object { $have[$_] }) })
    })
}
function Save-PackDef($req) {
    $data = Read-Json $dataPath; $packs = Read-Packs
    $name = Clip-Text $req.name 60; if (-not $name) { throw 'Give the pack a name' }
    $desc = Clip-Text $req.description 500; $author = Clip-Text $req.author 40
    $have = @{}; foreach ($L in @($data.lineups)) { $have[[string]$L.id] = $true }
    $ids = @(@($req.ids) | ForEach-Object { [string]$_ } | Where-Object { $have[$_] } | Select-Object -Unique)
    if (-not $ids.Count) { throw 'Pick at least one strat' }
    $now = (Get-Date).ToString('s')
    $id = ([string]$req.id) -replace '[^A-Za-z0-9-]', ''
    if ($id) {
        $p = $packs | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $p) { throw 'That pack no longer exists' }
        $p.name = $name; $p.description = $desc; $p.author = $author; $p.updated = $now
        if ($p.PSObject.Properties['ids']) { $p.ids = [object[]]$ids } else { $p | Add-Member -NotePropertyName ids -NotePropertyValue ([object[]]$ids) }
    } else {
        $id = [guid]::NewGuid().ToString()
        $p = [pscustomobject]([ordered]@{ id = $id; name = $name; description = $desc; author = $author; kind = 'own'; created = $now; updated = $now; ids = [object[]]$ids })
        $packs = @($packs) + $p
    }
    Write-Packs $packs
    [ordered]@{ ok = $true; id = $id; name = $name }
}
function Delete-PackDef($req) {   # { id, withStrats }: drop the pack; with withStrats also its strats (an imported pack's "uninstall")
    $id = ([string]$req.id) -replace '[^A-Za-z0-9-]', ''
    $packs = Read-Packs; $p = $packs | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $p) { throw 'That pack no longer exists' }
    $removed = 0
    if ($req.withStrats) {
        $data = Read-Json $dataPath; $gone = @(@($p.ids) | ForEach-Object { [string]$_ })
        $removed = @($data.lineups | Where-Object { $gone -contains $_.id }).Count
        $data.lineups = @($data.lineups | Where-Object { $gone -notcontains $_.id })
        Write-Data $data
        foreach ($g in $gone) { Get-ChildItem $assets -Filter "$g-pk*.*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpg|gif)$' } | Remove-Item -Force -ErrorAction SilentlyContinue }   # pictures that came with the pack
        foreach ($o in $packs) { if ($o.id -ne $id -and $o.ids) { $o.ids = [object[]]@(@($o.ids) | Where-Object { $gone -notcontains [string]$_ }) } }
    }
    Write-Packs @($packs | Where-Object { $_.id -ne $id })
    [ordered]@{ ok = $true; removed = $removed }
}
function Export-Pack($req) {
    $data = Read-Json $dataPath
    # by pack id (a kept pack: its identity travels with the file), or ad hoc from ids + name
    $packId = ([string]$req.packId) -replace '[^A-Za-z0-9-]', ''
    if ($packId) {
        $def = Read-Packs | Where-Object { $_.id -eq $packId } | Select-Object -First 1
        if (-not $def) { throw 'That pack no longer exists' }
        $ids = @(@($def.ids) | ForEach-Object { [string]$_ }); $name = [string]$def.name; $desc = [string]$def.description; $author = [string]$def.author
    } else {
        $ids = @($req.ids | ForEach-Object { [string]$_ }); $name = Clip-Text $req.name 60; $desc = Clip-Text $req.description 500; $author = Clip-Text $req.author 40
        $packId = [guid]::NewGuid().ToString()
    }
    $picked = @($data.lineups | Where-Object { $ids -contains $_.id })
    if (-not $picked.Count) { throw 'Nothing to export' }
    if (-not $name) { $name = 'Stratlab pack' }
    $buf = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($buf, [IO.Compression.ZipArchiveMode]::Create, $true)
    $n = 0; $out = @()
    try {
        foreach ($L in $picked) {
            $copy = $L | ConvertTo-Json -Depth 10 | ConvertFrom-Json   # a copy: the library itself is not touched
            if ($copy.PSObject.Properties['pack']) { $copy.PSObject.Properties.Remove('pack') }   # re-exporting makes it part of the new pack
            foreach ($stp in @($copy.steps)) {
                $srcs = @(foreach ($src in @($stp.src)) {
                    $file = [IO.Path]::GetFullPath((Join-Path $root (([string]$src) -replace '/', '\')))
                    if (-not $file.StartsWith($assets, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $file)) { throw "Missing picture for '$($L.title)'" }
                    $n++
                    if ($file -match '\.gif$') { Zip-Add $zip "pics/$n.gif" ([IO.File]::ReadAllBytes($file)); "pics/$n.gif" }   # a clip travels as it is
                    else { Zip-Add $zip "pics/$n.jpg" (Pic-Jpeg $file); "pics/$n.jpg" }
                })
                $stp.src = if ($srcs.Count -eq 1) { $srcs[0] } else { [object[]]$srcs }
            }
            $out += $copy
        }
        $manifest = [ordered]@{ format = 'stratlab'; version = 1; id = $packId; name = $name; description = $desc; author = $author; created = (Get-Date).ToString('s')
                                app = 'Stratlab'; strats = $out.Count; agents = @($out | ForEach-Object { $_.agent } | Select-Object -Unique); maps = @($out | ForEach-Object { $_.map } | Select-Object -Unique) }
        Zip-Add $zip 'manifest.json' ([Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 5)))
        Zip-Add $zip 'strats.json' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($out) -Depth 10)))
    } finally { $zip.Dispose() }
    , $buf.ToArray()
}
# open and check a pack; returns the manifest, the rebuilt strats and the picture bytes by name
function Read-Pack([byte[]]$bytes) {
    if ($bytes.Length -gt $PACK_MAX) { throw 'Pack is too big (over 60 MB)' }
    $game = Read-Json $gamePath
    try { $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $bytes)), [IO.Compression.ZipArchiveMode]::Read) } catch { throw 'Not a .stratlab pack (the file is not a valid zip)' }
    $files = @{}
    try {
        if ($zip.Entries.Count -gt $PACK_MAX_ENTRIES) { throw 'Pack has too many files' }
        foreach ($en in $zip.Entries) {
            $nm = $en.FullName -replace '\\', '/'
            if ($nm.EndsWith('/')) { continue }                                          # folder entry
            $cap = if ($nm -eq 'manifest.json' -or $nm -eq 'strats.json') { $PACK_MAX_JSON }
                   elseif ($nm -match '^pics/[A-Za-z0-9_-]{1,40}\.(jpg|jpeg|png|gif)$') { $PACK_MAX_PIC }
                   else { throw "Unexpected file in pack: $nm" }                          # nothing else is allowed in
            $st = $en.Open(); $ms = New-Object IO.MemoryStream; $chunk = New-Object byte[] 65536
            try { while (($r = $st.Read($chunk, 0, $chunk.Length)) -gt 0) { $ms.Write($chunk, 0, $r); if ($ms.Length -gt $cap) { throw "File too big in pack: $nm" } } } finally { $st.Dispose() }
            $files[$nm] = $ms.ToArray()
        }
    } finally { $zip.Dispose() }
    if (-not $files['manifest.json'] -or -not $files['strats.json']) { throw 'Not a .stratlab pack (manifest or strats missing)' }
    $man = [Text.Encoding]::UTF8.GetString($files['manifest.json']) | ConvertFrom-Json
    if (@('stratlab', 'lineuplab') -notcontains [string]$man.format) { throw 'Not a .stratlab pack' }   # 'lineuplab': the format's first name
    $packId = ([string]$man.id) -replace '[^A-Za-z0-9-]', ''; if (-not $packId) { throw 'Pack has no id' }
    $packName = ([string]$man.name).Trim(); if ($packName.Length -gt 60) { $packName = $packName.Substring(0, 60) }; if (-not $packName) { $packName = 'Unnamed pack' }
    # ConvertFrom-Json (PS 5.1) emits a JSON array as ONE object; ForEach-Object unrolls it into the strats
    $raw = @([Text.Encoding]::UTF8.GetString($files['strats.json']) | ConvertFrom-Json | ForEach-Object { $_ })
    if ($raw.Count -gt $PACK_MAX_STRATS) { throw "Pack has too many strats (over $PACK_MAX_STRATS)" }
    $clip = { param($v, [int]$len) $t = ([string]$v).Trim() -replace '[\x00-\x1f]', ''; if ($t.Length -gt $len) { $t.Substring(0, $len) } else { $t } }
    $num = { param($v, [double]$lo, [double]$hi, [double]$def) $d = 0.0; if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { [Math]::Min($hi, [Math]::Max($lo, $d)) } else { $def } }
    $zoomOf = { param($z) if ($null -eq $z -or $z -is [bool]) { $null } else { [ordered]@{ factor = (& $num $z.factor 1.5 12 8); x = [Math]::Round((& $num $z.x 0 1 0.5), 3); y = [Math]::Round((& $num $z.y 0 1 0.5), 3); mode = $(if ([string]$z.mode -eq 'hold') { 'hold' } else { 'pulse' }) } } }
    $good = @(); $checked = @{}
    foreach ($s in $raw) {
        $agent = & $clip $s.agent 30; $map = & $clip $s.map 30
        if (-not ($game.agents | Where-Object { $_.name -eq $agent })) { throw "Unknown agent in pack: '$agent'" }
        if (@($game.maps) -notcontains $map) { throw "Unknown map in pack: '$map'" }
        $type = ([string]$s.type).ToLower(); if ($PACK_TYPES -notcontains $type) { $type = 'post-plant' }
        $site = ([string]$s.site).ToUpper(); if ($site -notmatch '^([ABC]|MID)$') { throw "Bad site in pack: '$site'" }
        if ($site -eq 'MID') { $site = 'Mid'; if ($type -eq 'post-plant') { throw 'A post-plant cannot be at Mid' } }   # Mid: any type but post-plant
        $stepsIn = @($s.steps); if ($stepsIn.Count -lt 1 -or $stepsIn.Count -gt 5) { throw "A strat in the pack has $($stepsIn.Count) steps (1 to 5 allowed)" }
        $steps = @(foreach ($stp in $stepsIn) {
            $srcs = @($stp.src | ForEach-Object { [string]$_ })
            if (-not $srcs.Count -or $srcs.Count -gt 12) { throw 'A step in the pack has no pictures, or too many' }
            foreach ($src in $srcs) {
                if (-not $files.ContainsKey($src)) { throw "Pack is missing a picture: $src" }
                if (-not $checked.ContainsKey($src)) {   # must really be a picture of sane size
                    try { $im = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $files[$src]))); $ok = $im.Width -le 8000 -and $im.Height -le 8000; $im.Dispose() } catch { $ok = $false }
                    if (-not $ok) { throw "Not a valid picture in pack: $src" }
                    $checked[$src] = $true
                }
            }
            # the step name; older strats only have it as the "Name:" in front of their caption
            $lblRaw = [string]$stp.label; if (-not $lblRaw -and ([string]$stp.caption) -match '^\s*([A-Za-z][\w -]*?)\s*(:|$)') { $lblRaw = $Matches[1] }
            $label = (& $clip $lblRaw 16) -replace '[^\p{L}\p{N} \-]', ''; if (-not $label) { $label = 'Step' }
            $note = & $clip $stp.notes 60
            $o = [ordered]@{ type = 'png'; src = $(if ($srcs.Count -eq 1) { $srcs[0] } else { [object[]]$srcs }); label = $label; notes = $note; caption = $(if ($note) { "${label}: $note" } else { $label }) }
            if ($srcs.Count -eq 1) { $z = & $zoomOf $stp.zoom; if ($z) { $o['zoom'] = $z } }
            else {
                $o['picZoom'] = [object[]]@(for ($k = 0; $k -lt $srcs.Count; $k++) { & $zoomOf $(if ($stp.picZoom) { @($stp.picZoom)[$k] } else { $stp.zoom }) })
                $o['picTime'] = [object[]]@(for ($k = 0; $k -lt $srcs.Count; $k++) { [Math]::Round((& $num $(if ($stp.picTime) { @($stp.picTime)[$k] } else { $stp.interval }) 0.6 8 1.8), 1) })
            }
            [pscustomobject]$o
        })
        $side = if ($type -eq 'post-plant') { 'Attack' } elseif (@('Defense', 'Both') -contains [string]$s.side) { [string]$s.side } else { 'Attack' }
        $diff = ([string]$s.difficulty).ToLower(); if (@('easy', 'intermediate', 'challenging') -notcontains $diff) { $diff = 'easy' }
        $speed = if ($type -ne 'post-plant') { '' } else { switch (([string]$s.speed).ToLower()) { 'fast' { 'fast' } 'moderate' { 'moderate' } 'average' { 'moderate' } 'slow' { 'slow' } default { '' } } }
        $title = & $clip $s.title 80; if (-not $title) { $title = 'Imported strat' }
        $good += [pscustomobject]([ordered]@{
            source = (([string]$s.id) -replace '[^a-z0-9-]', ''); map = $map; agent = $agent; type = $type; site = $site; side = $side
            bounces = $(if ("$($s.bounces)" -match '^[0-2]$') { [int]$s.bounces } else { $null }); charge = $(if ("$($s.charge)" -match '^[0-3]$') { [int]$s.charge } else { $null })
            ability = (& $clip $s.ability 40); title = $title; difficulty = $diff; speed = $speed; steps = $steps })
    }
    @{ id = $packId; name = $packName; description = (& $clip $man.description 500); author = (& $clip $man.author 40); created = (& $clip $man.created 30); strats = $good; files = $files }
}
function Preview-Pack([byte[]]$bytes) {
    $p = Read-Pack $bytes; $data = Read-Json $dataPath
    $own = Read-Packs | Where-Object { $_.id -eq $p.id -and $_.kind -eq 'own' } | Select-Object -First 1
    if ($own) { throw "'$($p.name)' was exported from this library: its strats are already here" }
    $items = @(foreach ($s in $p.strats) {
        $has = $data.lineups | Where-Object { $_.pack -and $_.pack.id -eq $p.id -and $_.pack.source -eq $s.source } | Select-Object -First 1
        [ordered]@{ title = $s.title; agent = $s.agent; map = $s.map; site = $s.site; type = $s.type; status = $(if ($has) { 'update' } else { 'new' }) }
    })
    [ordered]@{ name = $p.name; description = $p.description; author = $p.author; created = $p.created; count = $items.Count; items = $items }
}
function Import-Pack([byte[]]$bytes) {
    $p = Read-Pack $bytes; $data = Read-Json $dataPath
    if (Read-Packs | Where-Object { $_.id -eq $p.id -and $_.kind -eq 'own' }) { throw "'$($p.name)' was exported from this library: its strats are already here" }
    $added = 0; $updated = 0; $memberIds = @()
    foreach ($s in $p.strats) {
        $has = $data.lineups | Where-Object { $_.pack -and $_.pack.id -eq $p.id -and $s.source -and $_.pack.source -eq $s.source } | Select-Object -First 1
        $id = if ($has) { [string]$has.id } else {
            $base = "$(Slug $s.agent)-$(Slug $s.map)-$($s.site.ToLower())-$($s.type -replace '-', '')"
            $n = 1; while ($data.lineups | Where-Object { $_.id -eq "$base-$n" }) { $n++ }; "$base-$n"
        }
        if ($has) { Get-ChildItem $assets -Filter "$id-pk*.*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpg|gif)$' } | Remove-Item -Force -ErrorAction SilentlyContinue }   # the pack's old pictures of this strat
        $k = 0; $map = @{}
        foreach ($stp in $s.steps) {
            $new = @(foreach ($src in @($stp.src)) {
                if (-not $map.ContainsKey($src)) { $k++; $fn = "$id-pk$k." + $(if ($src -match '\.gif$') { 'gif' } else { 'jpg' }); [IO.File]::WriteAllBytes((Join-Path $assets $fn), $p.files[$src]); $map[$src] = "assets/$fn" }
                $map[$src]
            })
            $stp.src = if ($new.Count -eq 1) { $new[0] } else { [object[]]$new }
        }
        $L = [pscustomobject]([ordered]@{
            id = $id; map = $s.map; agent = $s.agent; type = $s.type; option = "$($s.site) $($s.type)"; site = $s.site; side = $s.side
            bounces = $s.bounces; charge = $s.charge; ability = $s.ability; title = $s.title; difficulty = $s.difficulty; speed = $s.speed; steps = $s.steps
            pack = [ordered]@{ id = $p.id; name = $p.name; source = $(if ($s.source) { $s.source } else { $id }) } })
        Register-Refs $data $L
        if ($has) { $data.lineups = @($data.lineups | ForEach-Object { if ($_.id -eq $id) { $L } else { $_ } }); $updated++ }
        else { $data.lineups = @($data.lineups) + $L; $added++ }
        $memberIds += $id
    }
    Write-Data $data
    # the pack definition: new, or the same pack re-imported (keeps its first import date)
    $packs = Read-Packs; $now = (Get-Date).ToString('s')
    $def = $packs | Where-Object { $_.id -eq $p.id } | Select-Object -First 1
    if ($def) {
        $def.name = $p.name; $def.description = $p.description; $def.author = $p.author; $def.updated = $now
        $all = @(@($def.ids) | ForEach-Object { [string]$_ }) + $memberIds | Select-Object -Unique
        if ($def.PSObject.Properties['ids']) { $def.ids = [object[]]$all } else { $def | Add-Member -NotePropertyName ids -NotePropertyValue ([object[]]$all) }
        if ($def.PSObject.Properties['stamp']) { $def.stamp = $p.created } else { $def | Add-Member -NotePropertyName stamp -NotePropertyValue $p.created }
    } else {
        # stamp: when the pack file was exported; Browse compares it with the catalog's to offer updates
        $packs = @($packs) + [pscustomobject]([ordered]@{ id = $p.id; name = $p.name; description = $p.description; author = $p.author; kind = 'imported'; created = $now; updated = $now; stamp = $p.created; ids = [object[]]$memberIds })
    }
    Write-Packs $packs
    [ordered]@{ ok = $true; name = $p.name; added = $added; updated = $updated }
}

function Delete-Lineup($req) {
    $data = Read-Json $dataPath
    $data.lineups = @($data.lineups | Where-Object { $_.id -ne [string]$req.id })
    Write-Data $data
    # and out of any pack it was in
    $packs = Read-Packs; $touched = $false
    foreach ($p in $packs) { if ($p.ids -and (@($p.ids) -contains [string]$req.id)) { $p.ids = [object[]]@(@($p.ids) | Where-Object { [string]$_ -ne [string]$req.id }); $touched = $true } }
    if ($touched) { Write-Packs $packs }
    [ordered]@{ ok = $true }
}

# --- http -------------------------------------------------------------------------------------
$mime = @{ '.png' = 'image/png'; '.gif' = 'image/gif'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'; '.woff' = 'font/woff'; '.ttf' = 'font/ttf'; '.otf' = 'font/otf'; '.html' = 'text/html; charset=utf-8'; '.json' = 'application/json' }
function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$code = 200) {
    $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = $type; $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) { Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))) 'application/json' $code }
function Read-Body($ctx) { $sr = New-Object IO.StreamReader $ctx.Request.InputStream, $ctx.Request.ContentEncoding; try { $sr.ReadToEnd() } finally { $sr.Dispose() } }
function Read-BodyBytes($ctx, [long]$max) {   # raw upload (a pack file), refused past $max bytes
    $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536
    while (($n = $ctx.Request.InputStream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n); if ($ms.Length -gt $max) { throw 'Pack is too big (over 60 MB)' } }
    $ms.ToArray()
}

# in-app update: the newest GitHub release of version.json's repo. Only its own installer asset is taken,
# only from github.com, and only when it matches the .sha256 published beside it.
function Get-Update {
    $repo = [string]$APP.repo; if (-not $repo -or $repo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'No update source is set up' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $hdr = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Stratlab' }
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $hdr -TimeoutSec 20
    $tag = ([string]$rel.tag_name) -replace '^[vV]', ''
    if ($tag -notmatch '^\d+\.\d+\.\d+$') { throw 'No release found' }
    $exe = $rel.assets | Where-Object { $_.name -match '^Stratlab-Setup-[\d.]+\.exe$' } | Select-Object -First 1
    $sha = $rel.assets | Where-Object { $_.name -match '^Stratlab-Setup-[\d.]+\.exe\.sha256$' } | Select-Object -First 1
    if (-not $exe -or -not $sha) { throw 'The release has no installer and checksum attached' }
    foreach ($a in $exe, $sha) { if (-not ([string]$a.browser_download_url).StartsWith("https://github.com/$repo/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected download location' } }
    $dir = Join-Path $env:TEMP 'Stratlab-update'; New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir ([string]$exe.name)
    Invoke-WebRequest $exe.browser_download_url -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab' } -TimeoutSec 300
    $raw = (Invoke-WebRequest $sha.browser_download_url -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab' } -TimeoutSec 60).Content
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::ASCII.GetString($raw) }
    $want = (([string]$raw).Trim() -split '\s+')[0].ToLower()
    $have = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($want -notmatch '^[0-9a-f]{64}$' -or $want -ne $have) { Remove-Item $file -Force -ErrorAction SilentlyContinue; throw 'The download did not match its checksum, so it was not installed' }
    @{ file = $file; tag = $tag }
}
# the community catalog: catalog.json in version.json's "catalog" repository (raw.githubusercontent.com),
# kept for 10 minutes. Pack files are only ever fetched from that repository's release downloads.
$catCache = $null; $catAt = [DateTime]::MinValue
function Get-Catalog([bool]$force) {
    $repo = [string]$APP.catalog; if (-not $repo -or $repo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'No pack catalog is set up' }
    if (-not $force -and $catCache -and ((Get-Date) - $catAt).TotalMinutes -lt 10) { return $catCache }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # raw.githubusercontent.com is cached for five minutes (whatever the query string); Refresh in the app
    # (force) reads through the API instead, which is always current but rate limited, so only on demand
    $raw = $null
    if ($force) { try { $raw = (Invoke-WebRequest "https://api.github.com/repos/$repo/contents/catalog.json?ref=main" -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab'; Accept = 'application/vnd.github.raw+json' } -TimeoutSec 20).Content } catch { $raw = $null } }
    if (-not $raw) { $raw = (Invoke-WebRequest "https://raw.githubusercontent.com/$repo/main/catalog.json" -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab' } -TimeoutSec 20).Content }
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
    $c = $raw | ConvertFrom-Json
    if ([string]$c.format -ne 'stratlab-catalog') { throw 'The catalog could not be read' }
    $prefix = "https://github.com/$repo/releases/download/"
    $packs = @(foreach ($p in @($c.packs | ForEach-Object { $_ })) {
        $id = ([string]$p.id) -replace '[^A-Za-z0-9-]', ''
        if (-not $id -or -not ([string]$p.file).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [pscustomobject]([ordered]@{
            id = $id; name = (Clip-Text $p.name 60); description = (Clip-Text $p.description 500); author = (Clip-Text $p.author 40); publisher = (Clip-Text $p.publisher 40)
            strats = [int]$p.strats; agents = [object[]]@($p.agents | ForEach-Object { Clip-Text $_ 30 }); maps = [object[]]@($p.maps | ForEach-Object { Clip-Text $_ 30 }); types = [object[]]@($p.types | ForEach-Object { Clip-Text $_ 20 })
            size = [long]$p.size; sha256 = ([string]$p.sha256).ToLower(); stamp = (Clip-Text $p.stamp 30); published = (Clip-Text $p.published 30); updated = (Clip-Text $p.updated 30); file = [string]$p.file
            votes = $(if ("$($p.votes)" -match '^\d+$') { [int]$p.votes } else { 0 })
            stratVotes = $(  # { "<strat source>": count } from the bot's tally
                $sv = [ordered]@{}
                if ($p.stratVotes) { foreach ($q in $p.stratVotes.PSObject.Properties) { $k = ([string]$q.Name) -replace '[^a-z0-9-]', ''; if ($k -and "$($q.Value)" -match '^\d+$') { $sv[$k] = [int]$q.Value } } }
                [pscustomobject]$sv) })
    })
    $script:catCache = [ordered]@{ packs = $packs; updated = (Clip-Text $c.updated 30); fetched = (Get-Date).ToString('s') }; $script:catAt = Get-Date
    $catCache
}
# download one catalog pack (checksum verified) and hold it as the pending import, ready for the preview
function Get-CatalogPack([string]$id) {
    $cat = Get-Catalog $false
    $p = $cat.packs | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $p) { $cat = Get-Catalog $true; $p = $cat.packs | Where-Object { $_.id -eq $id } | Select-Object -First 1 }
    if (-not $p) { throw 'That pack is no longer in the catalog' }
    if ($p.size -gt $PACK_MAX) { throw 'Pack is too big (over 60 MB)' }
    $dir = Join-Path $env:TEMP 'Stratlab-packs'; New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir "$($p.id).stratlab"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $p.file -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab' } -TimeoutSec 300
    $bytes = [IO.File]::ReadAllBytes($file); Remove-Item $file -Force -ErrorAction SilentlyContinue
    if ($bytes.Length -gt $PACK_MAX) { throw 'Pack is too big (over 60 MB)' }
    $sha = [Security.Cryptography.SHA256]::Create(); try { $have = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower() } finally { $sha.Dispose() }
    if ($p.sha256 -notmatch '^[0-9a-f]{64}$' -or $have -ne $p.sha256) { throw 'The download did not match the catalog, so it was not opened' }
    , $bytes
}
# upvotes: a vote is one line posted to a private Discord channel through a webhook (version.json "votes");
# the catalog bot tallies those lines, one vote per install, into catalog.json. Locally, data\votes.json
# remembers this install's id and what it voted for, so the buttons show as pressed and a click un-votes.
$votesPath = Join-Path $root 'data\votes.json'
function Read-Votes {
    $v = if (Test-Path $votesPath) { try { Read-Json $votesPath } catch { $null } } else { $null }
    $id = if ($v -and $v.installId) { [string]$v.installId } else { [guid]::NewGuid().ToString() }
    $voted = @{}; if ($v -and $v.voted) { foreach ($p in $v.voted.PSObject.Properties) { if ($p.Value) { $voted[$p.Name] = 1 } } }
    @{ installId = $id; voted = $voted }
}
function Write-Votes($v) { [IO.File]::WriteAllText($votesPath, ([ordered]@{ installId = $v.installId; voted = $v.voted } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
function Send-Vote($req) {
    $hook = [string]$APP.votes
    if (-not $hook -or $hook -notmatch '^https://(discord\.com|discordapp\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+$') { throw 'Voting is not set up in this build' }
    $kind = [string]$req.kind; if (@('pack', 'strat') -notcontains $kind) { throw 'Bad vote' }
    $pack = ([string]$req.pack) -replace '[^A-Za-z0-9-]', ''; $src = ([string]$req.source) -replace '[^a-z0-9-]', ''
    if (-not $pack -or ($kind -eq 'strat' -and -not $src)) { throw 'Bad vote' }
    $v = Read-Votes
    $key = if ($kind -eq 'pack') { "pack:$pack" } else { "strat:$pack/$src" }
    $up = -not $v.voted.ContainsKey($key)
    $line = [ordered]@{ v = 1; id = $v.installId; k = $kind; p = $pack; u = $(if ($up) { 1 } else { 0 }) }; if ($kind -eq 'strat') { $line['s'] = $src }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{ content = 'vote ' + ($line | ConvertTo-Json -Compress); allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Compress -Depth 4
    Invoke-WebRequest $hook -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab' } -TimeoutSec 20 | Out-Null
    if ($up) { $v.voted[$key] = 1 } else { $v.voted.Remove($key) }
    Write-Votes $v
    @{ voted = $up }
}
# feedback: what the user typed in the app's Feedback box, posted through a webhook (version.json
# "feedback") into a private Discord channel, with the app version and a short install id (not a name)
function Send-Feedback($req) {
    $hook = [string]$APP.feedback
    if (-not $hook -or $hook -notmatch '^https://(discord\.com|discordapp\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+$') { throw 'Feedback is not set up in this build' }
    $text = Clip-Text $req.text 1500; if ($text.Length -lt 3) { throw 'Write a little more first' }
    $who = Clip-Text $req.contact 60; if (-not $who) { $who = 'anonymous' }
    $inst = (Read-Votes).installId.Substring(0, 8)
    $content = "**Feedback** from $who  |  Stratlab v$($APP.version)  |  install $inst`n" + ($text -replace '@', ('@' + [char]0x200B))   # no pings
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{ content = $content; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Compress -Depth 4
    Invoke-WebRequest $hook -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -Headers @{ 'User-Agent' = 'Stratlab' } -TimeoutSec 20 | Out-Null
    @{ ok = $true }
}
function Open-Window([string]$u) {
    $edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
    if (Test-Path $edge) { Start-Process $edge -ArgumentList "--app=$u", '--window-size=1280,880' } else { Start-Process $u }
}
# started at login while "Start with Windows" is off: do nothing
if ($AtLogin -and -not (Get-Settings).autostart) { exit }
# already running (the server outlives its window)? then just open a window to it and stop here
try {
    $alive = Invoke-WebRequest "http://localhost:$Port/api/ping" -UseBasicParsing -TimeoutSec 2
    if ($alive.StatusCode -eq 200) {
        if ($Import) {   # hand the pack to the running server, then open a window that asks for its preview
            try { Invoke-WebRequest "http://localhost:$Port/api/import/queue" -Method Post -InFile $Import -ContentType 'application/octet-stream' -UseBasicParsing -TimeoutSec 30 | Out-Null; Open-Window "http://localhost:$Port/?import=1" } catch { Open-Window "http://localhost:$Port/" }
        } elseif (-not ($NoBrowser -or $Background)) { Open-Window "http://localhost:$Port/" }
        exit
    }
} catch {}

# start the server. A fresh HttpListener per attempt: one that failed to start cannot be reused
# (reusing it was why a second launch used to die silently with no window)
$listener = $null
for ($try = 0; $try -lt 10 -and -not $listener; $try++) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://localhost:$Port/")
    try { $l.Start(); $listener = $l } catch { try { $l.Close() } catch {}; $Port++ }
}
if (-not $listener) { throw "No free port for Stratlab" }
$url = "http://localhost:$Port/"
Write-Host "Stratlab at $url"

if ($Import -and (Test-Path $Import)) { try { $pendingPack = [IO.File]::ReadAllBytes($Import) } catch {} }
if ($Import) { Open-Window "$url?import=1" }
elseif (-not ($NoBrowser -or $Background)) { Open-Window $url }

# --- tray icon: the server runs in the background, so it shows itself in the notification area ---------
# Left click opens the app; the menu has the overlay switch, Start with Windows and Quit. Its events are
# handled while the request loop below waits (DoEvents), on this same thread, so they can touch the
# server's state directly. Test instances (-NoBrowser) get no icon.
$tray = $null
function Update-Tray {
    if (-not $tray) { return }
    $on = $null -ne (Overlay-Pid)
    $trayOverlay.Checked = $on; $trayAuto.Checked = (Get-Settings).autostart
    $t = "Stratlab v$($APP.version) $([char]0xB7) overlay $(if ($on) { 'on' } else { 'off' })"; if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }
    $tray.Text = $t
}
if (-not $NoBrowser) {
    try {
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $icoPath = Join-Path $root 'assets\app.ico'
        $tray.Icon = if (Test-Path $icoPath) { New-Object System.Drawing.Icon $icoPath } else { [System.Drawing.SystemIcons]::Application }
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $head = $menu.Items.Add("Stratlab v$($APP.version)"); $head.Enabled = $false
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $trayOpen = $menu.Items.Add('Open Stratlab'); $trayOpen.Font = New-Object System.Drawing.Font $trayOpen.Font, ([System.Drawing.FontStyle]::Bold)
        $trayOverlay = $menu.Items.Add('Overlay')
        $trayAuto = $menu.Items.Add('Start with Windows')
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $trayQuit = $menu.Items.Add('Quit Stratlab')
        $trayOpen.Add_Click({ Open-Window $url })
        $trayOverlay.Add_Click({ [void](Toggle-Overlay); Start-Sleep -Milliseconds 300; Update-Tray })
        $trayAuto.Add_Click({ try { [void](Set-Settings ([pscustomobject]@{ autostart = (-not (Get-Settings).autostart) })) } catch {}; Update-Tray })
        $trayQuit.Add_Click({   # everything stops: the overlay too, then this server
            $opid = Overlay-Pid; if ($opid) { Stop-Process -Id $opid -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $root 'overlay.pid') -ErrorAction SilentlyContinue }
            $script:running = $false
        })
        $menu.Add_Opening({ Update-Tray })
        $tray.ContextMenuStrip = $menu
        $tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Window $url } })
        Update-Tray
        $tray.Visible = $true
    } catch { Write-Host "tray: $($_.Exception.Message)"; $tray = $null }
}

$lastPing = $null; $started = Get-Date; $trayAt = Get-Date
$stateStamp = ''; $stateJson = $null
$running = $true
while ($running) {
    $ar = $listener.BeginGetContext($null, $null)
    while (-not $ar.AsyncWaitHandle.WaitOne(50)) {
        if ($tray) {   # the tray's clicks and menu run here
            [System.Windows.Forms.Application]::DoEvents()
            if (((Get-Date) - $trayAt).TotalSeconds -ge 5) { $trayAt = Get-Date; Update-Tray }   # keep the tooltip current
        }
        if (-not $running) { break }   # Quit from the tray
        # the server stays up when the window closes, so the app can be reopened any time.
        # Only a test instance (-NoBrowser) winds down, 10 minutes after its last ping.
        if ($NoBrowser -and ((Get-Date) - $(if ($lastPing) { $lastPing } else { $started })).TotalMinutes -gt 10) { $running = $false; break }
    }
    if (-not $running) { break }
    $ctx = $listener.EndGetContext($ar)
    try {
        $path = $ctx.Request.Url.AbsolutePath
        switch -Regex ($path) {
            '^/$'            { Send-Bytes $ctx ([IO.File]::ReadAllBytes($html)) 'text/html; charset=utf-8' }
            '^/api/ping$'    { $lastPing = Get-Date; Send-Json $ctx @{ ok = $true } }
            '^/api/version$' { Send-Json $ctx @{ version = [string]$APP.version; repo = [string]$APP.repo; catalog = [string]$APP.catalog; discord = [string]$APP.discord; votes = [bool]([string]$APP.votes); feedback = [bool]([string]$APP.feedback) } }
            '^/api/feedback$' { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Send-Feedback $req) }   # { text, contact }
            # upvotes: GET what this install voted for; POST { kind: pack|strat, pack, source } toggles a vote
            '^/api/votes$' { $v = Read-Votes; Send-Json $ctx @{ voted = [string[]]@($v.voted.Keys) } }
            '^/api/vote$'  { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Send-Vote $req) }
            # the community catalog (Packs > Browse); fetch: download one pack and queue it as the pending import
            '^/api/catalog$' { Send-Json $ctx (Get-Catalog ($ctx.Request.QueryString['force'] -eq '1')) }
            '^/api/catalog/fetch$' {
                $req = Read-Body $ctx | ConvertFrom-Json
                $bytes = Get-CatalogPack (([string]$req.id) -replace '[^A-Za-z0-9-]', '')
                $pv = Preview-Pack $bytes; $pv['pending'] = $true
                $pendingPack = $bytes
                Send-Json $ctx $pv
            }
            '^/api/update$'  {   # download the latest installer from the release, verify its checksum, run it silently
                $u = Get-Update
                Send-Json $ctx @{ ok = $true; tag = $u.tag }
                Start-Process $u.file -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'   # it stops this server and starts the new one
            }
            # a pack opened from Explorer: queued by import.vbs, previewed by the window it opens, imported on confirm
            '^/api/import/queue$'   { $pendingPack = Read-BodyBytes $ctx $PACK_MAX; Send-Json $ctx @{ ok = $true } }
            '^/api/import/pending$' {
                if (-not $pendingPack) { Send-Json $ctx @{ pending = $false } }
                else { try { $pv = Preview-Pack $pendingPack; $pv['pending'] = $true; Send-Json $ctx $pv } catch { $pendingPack = $null; throw } }
            }
            '^/api/import/discard$' { $pendingPack = $null; Send-Json $ctx @{ ok = $true } }   # Cancel in the preview
            '^/api/import/confirm$' {
                if (-not $pendingPack) { throw 'No pack is waiting to be imported' }
                try { Send-Json $ctx (Import-Pack $pendingPack) } finally { $pendingPack = $null }
            }
            '^/api/state$'   {   # cached as JSON until the data files change; building it scans ~150 icon files
                $stamp = "$((Get-Item $dataPath).LastWriteTimeUtc.Ticks)-$((Get-Item $gamePath).LastWriteTimeUtc.Ticks)-$(if (Test-Path $packsPath) { (Get-Item $packsPath).LastWriteTimeUtc.Ticks } else { 0 })"
                if ($stateStamp -ne $stamp) { $stateJson = [Text.Encoding]::UTF8.GetBytes(((Get-State) | ConvertTo-Json -Depth 10 -Compress)); $stateStamp = $stamp }
                Send-Bytes $ctx $stateJson 'application/json'
            }
            '^/api/save$'    { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Save-Lineup $req) }
            '^/api/delete$'  { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Delete-Lineup $req) }
            '^/api/pack/save$'   { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Save-PackDef $req) }
            '^/api/pack/delete$' { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Delete-PackDef $req) }
            '^/api/export$'  {   # { packId } or { ids, name, description, author } -> the .stratlab file
                $req = Read-Body $ctx | ConvertFrom-Json
                $bytes = Export-Pack $req
                $fname = [string]$req.name
                if ($req.packId) { $d = Read-Packs | Where-Object { $_.id -eq [string]$req.packId } | Select-Object -First 1; if ($d) { $fname = [string]$d.name } }
                $safe = ($fname -replace '[^\w \-]', '').Trim(); if (-not $safe) { $safe = 'Stratlab pack' }
                $ctx.Response.Headers['Content-Disposition'] = "attachment; filename=`"$safe.stratlab`""
                Send-Bytes $ctx $bytes 'application/octet-stream'
            }
            '^/api/import/preview$' { Send-Json $ctx (Preview-Pack (Read-BodyBytes $ctx $PACK_MAX)) }   # body: the pack file
            '^/api/import$'  { Send-Json $ctx (Import-Pack (Read-BodyBytes $ctx $PACK_MAX)) }
            '^/api/quit$'    { Send-Json $ctx @{ ok = $true }; $running = $false }
            '^/api/monitors$' { Send-Json $ctx (Get-Monitors) }
            '^/api/settings$' { if ($ctx.Request.HttpMethod -eq 'POST') { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Set-Settings $req) } else { Send-Json $ctx (Get-Settings) } }   # overlay size + corner
            '^/api/monitor$'  { $req = Read-Body $ctx | ConvertFrom-Json; Send-Json $ctx (Set-Monitor $req) }
            '^/api/overlay$' {   # GET: is the overlay running?  POST {toggle:true}: start it or stop it
                # the overlay writes its process id to overlay.pid; checking that is instant (a WMI process
                # scan took hundreds of ms and stalled every other request while it ran)
                if ($ctx.Request.HttpMethod -eq 'POST') { $on = Toggle-Overlay; Send-Json $ctx @{ running = $on; display = (Get-DisplayMode) } }
                else { Send-Json $ctx @{ running = ($null -ne (Overlay-Pid)); display = (Get-DisplayMode) } }   # display: the game's display mode, see Get-DisplayMode
            }
            '^/assets/'      {
                $rel = [Uri]::UnescapeDataString($path.Substring(1)) -replace '/', '\'
                # resolve ".." first: comparing the raw joined path let /assets/..\data\... read files outside assets\
                $file = [IO.Path]::GetFullPath((Join-Path $root $rel))
                if ((Test-Path $file) -and $file.StartsWith($assets + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $ext = [IO.Path]::GetExtension($file).ToLower()
                    Send-Bytes $ctx ([IO.File]::ReadAllBytes($file)) $(if ($mime[$ext]) { $mime[$ext] } else { 'application/octet-stream' })
                } else { Send-Json $ctx @{ error = 'not found' } 404 }
            }
            default          { Send-Json $ctx @{ error = 'not found' } 404 }
        }
    } catch {
        try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch {}
        Write-Host "error: $($_.Exception.Message)"
    }
}
if ($tray) { $tray.Visible = $false; $tray.Dispose() }   # or a dead icon lingers in the tray until hovered
$listener.Stop()
