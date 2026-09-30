# Valorant lineup overlay.
# A compact translucent card in the top-right of the screen, above Valorant's performance
# graphs: a large media preview on the left, a five-line readout beside it (map, agent, option,
# lineup, step) and the lineup title + step caption underneath. Click-through; hotkeys only.
#
# Map and agent are detected automatically:
#   1. Riot's local client API (the lockfile on this PC) is asked, read-only, whether you are in
#      agent select or in a match, and which map / agent that is. Works from agent select on.
#   2. If that is unavailable, the map is read from Valorant's own log when the match loads.
#
#   Left / Right    previous / next lineup (walks every lineup for this map + agent)
#   Up / Down       previous / next step (stand, aim, execute)
#   5               jump to the next site / option          6  next agent (manual override)
#   7               next map (manual override)              0  show / hide
#   Alt+arrows      nudge the panel 10px (saved)            Alt+5  next monitor (saved)
#   Ctrl+Shift+Q    quit
#
# Everything is configurable in config.json. Valorant must run in Windowed Fullscreen for the
# panel to be visible over it. The overlay never touches the game process.

param(
    [string]$ScreenshotPath,  # test hook: save a picture of the panel to this path, then exit
    [string]$LogPath          # test hook: read the map from this file instead of Valorant's log
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- native helpers -------------------------------------------------------------------------
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Borderless, never activates, no alt-tab entry, and mouse input passes through to whatever is
// underneath (WS_EX_TRANSPARENT + WS_EX_LAYERED).
public class OverlayForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00080000;   // WS_EX_LAYERED
            cp.ExStyle |= 0x00000020;   // WS_EX_TRANSPARENT (click-through)
            return cp;
        }
    }
}

// Hotkeys via a low-level keyboard hook. Unlike RegisterHotKey, a key is only taken when the game
// is the foreground window (or the binding is marked global); everywhere else it passes through
// untouched, so the number row and arrows keep working in other apps and on other monitors.
public class KeyboardHook : IDisposable
{
    delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

    class Binding { public int Id, Mods, Vk; public bool Loose, Global, Swallow; }
    List<Binding> binds = new List<Binding>();
    HashSet<int> held = new HashSet<int>();
    LowLevelProc proc; IntPtr hook = IntPtr.Zero; Control ui;
    uint lastPid; string lastName = ""; DateTime lastCheck = DateTime.MinValue;
    public event Action<int> Pressed;
    public string GameProcess = "VALORANT-Win64-Shipping";
    public bool OnlyInGame = true;

    public KeyboardHook(Control uiControl)
    {
        ui = uiControl; proc = Callback;           // keep the delegate alive for the hook's lifetime
        hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);
    }
    // loose = a bare key that may also be pressed with Shift / Ctrl held (walk, crouch)
    // swallow = false lets the game see the key too (used for Tab: the panel toggles AND the scoreboard opens)
    public void Add(int id, int mods, int vk, bool loose, bool global, bool swallow) { binds.Add(new Binding { Id = id, Mods = mods, Vk = vk, Loose = loose, Global = global, Swallow = swallow }); }

    bool InGame()
    {
        if (!OnlyInGame) return true;
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        if (pid != lastPid || (DateTime.Now - lastCheck).TotalSeconds > 2)
        {
            lastPid = pid; lastCheck = DateTime.Now;
            try { lastName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { lastName = ""; }
        }
        return string.Equals(lastName, GameProcess, StringComparison.OrdinalIgnoreCase);
    }
    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32(); int vk = Marshal.ReadInt32(lParam);
            if (msg == 0x101 || msg == 0x105) held.Remove(vk);                 // key up
            else if (msg == 0x100 || msg == 0x104)                                // key down (incl. with Alt)
            {
                int mods = 0;
                if ((GetAsyncKeyState(0x11) & 0x8000) != 0) mods |= 2;   // Ctrl
                if ((GetAsyncKeyState(0x10) & 0x8000) != 0) mods |= 4;   // Shift
                if ((GetAsyncKeyState(0x12) & 0x8000) != 0) mods |= 1;   // Alt
                if (((GetAsyncKeyState(0x5B) | GetAsyncKeyState(0x5C)) & 0x8000) != 0) mods |= 8;   // Win
                foreach (var b in binds)
                {
                    if (b.Vk != vk) continue;
                    bool ok = b.Loose ? ((mods & ~6) == 0) : (mods == b.Mods);
                    if (!ok) continue;
                    if (!b.Global && !InGame()) continue;
                    bool repeat = held.Contains(vk); held.Add(vk);
                    if (!repeat && Pressed != null)
                    {
                        int id = b.Id;
                        try { ui.BeginInvoke(new Action(() => Pressed(id))); } catch { }   // never do work inside the hook
                    }
                    if (b.Swallow) return (IntPtr)1;                                       // the game never sees it
                    break;                                                                 // pass-through key: fall out to the game

                }
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }
    public void Dispose() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
}
'@
# Compiled animator for the preview: slide transitions and the zoom pulse render in C# on a
# double buffer (no per-frame PowerShell work), from a source pre-scaled to the zoom's needs.
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;

public class MediaAnimator : IDisposable
{
    PictureBox pic; int W, H;
    Timer timer = new Timer();
    Bitmap[] buf = new Bitmap[2]; int bi = 0;
    Bitmap from, to; double tt = -1;                       // transition (tt < 0: none)
    Bitmap zoomSrc; bool zooming; double fx, fy, factor, period, zt;
    Image final;
    Bitmap shown;                                          // the fitted W x H bitmap currently on screen (stills)
    DateTime last;
    public double TransitionSeconds = 0.28;

    public MediaAnimator(PictureBox p, int w, int h)
    {
        pic = p; W = w; H = h;
        buf[0] = new Bitmap(w, h); buf[1] = new Bitmap(w, h);
        timer.Interval = 16; timer.Tick += Tick;   // ~60 fps; each frame is one native draw
    }

    static void DrawFitted(Image img, Bitmap bmp)
    {
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Black);
            if (img == null) return;
            // stills are drawn once, so use the best filter: a 1280-wide screenshot shrunk to ~240 px stays sharp
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.CompositingQuality = CompositingQuality.HighQuality;
            double s = Math.Min((double)bmp.Width / img.Width, (double)bmp.Height / img.Height);
            float w = (float)(img.Width * s), h = (float)(img.Height * s);
            g.DrawImage(img, (bmp.Width - w) / 2, (bmp.Height - h) / 2, w, h);
        }
    }

    public Bitmap Snapshot() { var b = new Bitmap(W, H); DrawFitted(pic.Image, b); return b; }

    // draw img at the given opacity with a blur amount 0..1 (0 = sharp). The blur is a downscale to a
    // small scratch bitmap and back up, bilinear both ways; scratch bitmaps are reused, never per-frame.
    Bitmap[] scratch;
    void DrawBlurred(Graphics g, Bitmap img, double alpha, double blur)
    {
        if (alpha <= 0.01) return;
        if (scratch == null)
        {
            scratch = new Bitmap[4];
            for (int i = 0; i < 4; i++) { int d = 2 << i; scratch[i] = new Bitmap(Math.Max(2, W / d), Math.Max(2, H / d)); }
        }
        using (var ia = new ImageAttributes())
        {
            var cm = new ColorMatrix(); cm.Matrix33 = (float)Math.Min(1, alpha); ia.SetColorMatrix(cm);
            if (blur < 0.08)
            {
                g.DrawImage(img, new Rectangle(0, 0, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia);
                return;
            }
            int level = Math.Min(3, (int)(blur * 4));                    // 1/2, 1/4, 1/8, 1/16 size
            var sm = scratch[level];
            using (var sg = Graphics.FromImage(sm))
            {
                sg.InterpolationMode = InterpolationMode.Bilinear; sg.PixelOffsetMode = PixelOffsetMode.Half;
                sg.DrawImage(img, 0, 0, sm.Width, sm.Height);
            }
            g.DrawImage(sm, new Rectangle(0, 0, W, H), 0, 0, sm.Width, sm.Height, GraphicsUnit.Pixel, ia);
        }
    }

    int dirX, dirY;   // slide direction: (1,0) new slide enters from the right, (0,1) from below, (0,0) crossfade

    bool hold;   // true: the picture stays at its close-up (no pulse)

    // Show img, crossfading from the snapshot if given; then zoom on (fx, fy) if zoom is set:
    // pulsing in and out, or, with hold, sitting at the close-up.
    public void Show(Image img, Bitmap fromSnapshot, int dx, int dy, bool zoom, double fx, double fy, double factor, double period, bool hold)
    {
        Stop();
        final = img; dirX = dx; dirY = dy; this.hold = hold;
        zooming = zoom && img != null && factor > 1;
        if (zooming)
        {
            int sw = (int)Math.Min(img.Width, W * factor * 1.25);          // enough pixels for the closest zoom, no more
            int sh = Math.Max(1, (int)(img.Height * (double)sw / img.Width));
            zoomSrc = new Bitmap(sw, sh);
            using (var g = Graphics.FromImage(zoomSrc)) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.DrawImage(img, 0, 0, sw, sh); }
            this.fx = fx; this.fy = fy; this.factor = factor; this.period = period; zt = 0;
        }
        Bitmap prevShown = shown; shown = null;
        if (fromSnapshot != null && img != null)
        {
            from = fromSnapshot; to = new Bitmap(W, H);
            if (zooming && hold) using (var g = Graphics.FromImage(to)) DrawZoom(g, factor);   // fade straight into the held close-up
            else DrawFitted(img, to);
            tt = 0; pic.Image = from;
        }
        else
        {
            if (fromSnapshot != null) fromSnapshot.Dispose();
            tt = -1;
            if (zooming && hold)
            {   // a held close-up is one still frame: draw it once, no timer (so it can use the best filter)
                shown = new Bitmap(W, H);
                using (var g = Graphics.FromImage(shown)) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; DrawZoomWith(g, factor); }
                pic.Image = shown; if (prevShown != null) prevShown.Dispose(); return;
            }
            // stills always go through the same fitted W x H drawing as fades and zoom frames, so
            // nothing ever shifts by a pixel between the two; animated GIFs are handed over as-is
            if (img != null && !zooming && !ImageAnimator.CanAnimate(img)) { shown = new Bitmap(W, H); DrawFitted(img, shown); pic.Image = shown; }
            else pic.Image = img;         // the zoom's first frame replaces this a tick later
            if (prevShown != null) prevShown.Dispose();
            if (!zooming) return;
        }
        if (prevShown != null) prevShown.Dispose();
        last = DateTime.Now;
        timer.Start();
    }

    // one zoom frame at scale sc: start from the exact letterboxed layout the normal view uses, then scale
    // that rectangle about the focus point, so at scale 1 the frame is identical to the default view
    void DrawZoom(Graphics g, double sc)
    {
        g.InterpolationMode = InterpolationMode.Bilinear; g.PixelOffsetMode = PixelOffsetMode.Half;   // animated frames: fast filter
        DrawZoomWith(g, sc);
    }
    void DrawZoomWith(Graphics g, double sc)   // uses whatever filter the caller set
    {
        double f = Math.Min((double)W / zoomSrc.Width, (double)H / zoomSrc.Height);
        double dw = zoomSrc.Width * f, dh = zoomSrc.Height * f;
        double ox = (W - dw) / 2, oy = (H - dh) / 2;
        double px = ox + fx * dw, py = oy + fy * dh;
        double nw = dw * sc, nh = dh * sc;
        double nx = px - (px - ox) * sc, ny = py - (py - oy) * sc;
        if (nw >= W) nx = Math.Min(0, Math.Max(W - nw, nx));      // no gaps once the picture covers the frame
        if (nh >= H) ny = Math.Min(0, Math.Max(H - nh, ny));
        g.Clear(Color.Black);
        g.DrawImage(zoomSrc, new RectangleF((float)nx, (float)ny, (float)nw, (float)nh));
    }

    void Tick(object s, EventArgs e)
    {
        double dt = (DateTime.Now - last).TotalSeconds; last = DateTime.Now;
        if (dt > 0.2) dt = 0.2;
        var b = buf[bi]; bi ^= 1;
        using (var g = Graphics.FromImage(b))
        {
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.CompositingQuality = CompositingQuality.HighSpeed;
            if (tt >= 0)
            {
                tt += dt / TransitionSeconds;
                if (tt < 1)
                {
                    // plain crossfade (used between pictures of the same step); nothing moves, no blur
                    double k = tt * tt * (3 - 2 * tt);                         // smoothstep
                    g.DrawImage(from, 0, 0, W, H);
                    var cm = new ColorMatrix(); cm.Matrix33 = (float)k;
                    using (var ia = new ImageAttributes())
                    {
                        ia.SetColorMatrix(cm);
                        g.DrawImage(to, new Rectangle(0, 0, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia);
                    }
                    pic.Image = b;
                    return;
                }
                if (!zooming || hold)
                {   // keep the fade's final frame on screen (the fitted picture, or the held close-up): no jump
                    if (shown != null) shown.Dispose();
                    shown = to; to = null; pic.Image = shown;
                    EndTransition(); timer.Stop(); return;
                }
                EndTransition();
            }
            if (zooming)
            {
                zt += dt;
                DrawZoom(g, ZoomScale(zt % ZoomPeriod()));
                pic.Image = b;
            }
        }
    }

    // zoom profile: full view -> close-up -> full view, holding at both, steady glides between.
    // About two thirds of the cycle is spent at the close-up (HoldClose + its glides), one third at full view.
    public double HoldFar = 1.0, HoldClose = 2.4, GlideSeconds = 0.5;
    double ZoomPeriod() { return HoldFar + HoldClose + 2 * GlideSeconds; }
    double ZoomScale(double t)
    {
        if (t < HoldFar) return 1;                                                   // full view
        t -= HoldFar;
        if (t < GlideSeconds) return 1 + (factor - 1) * Smooth(t / GlideSeconds);   // glide in
        t -= GlideSeconds;
        if (t < HoldClose) return factor;                                           // close-up
        t -= HoldClose;
        return factor - (factor - 1) * Smooth(t / GlideSeconds);                    // glide out
    }
    static double Smooth(double x) { x = Math.Max(0, Math.Min(1, x)); return x * x * (3 - 2 * x); }

    void EndTransition()
    {
        tt = -1;
        if (from != null) { from.Dispose(); from = null; }
        if (to != null) { to.Dispose(); to = null; }
    }
    public void Stop()
    {
        timer.Stop(); EndTransition(); zooming = false;
        if (zoomSrc != null) { zoomSrc.Dispose(); zoomSrc = null; }
    }
    public void Dispose() { Stop(); timer.Dispose(); buf[0].Dispose(); buf[1].Dispose(); if (shown != null) shown.Dispose(); }
}
'@

# The Riot client's local API uses a self-signed certificate; accept it for this process only.
Add-Type -TypeDefinition @'
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustLocalRiot : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; }
}
'@
[Net.ServicePointManager]::CertificatePolicy = New-Object TrustLocalRiot
[Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls13'

# --- data -----------------------------------------------------------------------------------
$root = $PSScriptRoot
$data = Get-Content (Join-Path $root 'data\lineups.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$MAPS = [System.Collections.ArrayList]@($data.maps)       # detection may append maps / agents that have no lineups yet
$AGENTS = [System.Collections.ArrayList]@($data.agents)
$detectLog = Join-Path $root 'detect.log'                  # what detection saw, for troubleshooting
function Write-DetectLog([string]$msg) {
    try {
        if ((Test-Path $detectLog) -and (Get-Item $detectLog).Length -gt 200000) { Clear-Content $detectLog }
        Add-Content $detectLog "$(Get-Date -Format 'HH:mm:ss') $msg"
    } catch {}
}

# shared mutable state (hashtable so event handlers, which run in script scope, see the same object).
# NOTE: PowerShell variable names are case-insensitive, so no local may be called $st, $tw or $icon.
$ST = @{ sel = @{ Map = -1; Agent = -1 }; all = @(); li = 0; si = 0; image = $null; icons = @{}; dir = @(0, 0)   # -1 = unknown, block stays blank
         det = @{ map = ''; agent = ''; source = '' }; token = $null; tokenAt = [DateTime]::MinValue; riot = $null }

# --- config ---------------------------------------------------------------------------------
$configPath = Join-Path $root 'config.json'
$cfg = @{
    monitor = 1; width = 372
    anchor = 'top-right'; offsetX = 16; offsetY = 296    # corner the panel sits in, and its distance from those two edges (mid-right, under the performance graphs)
    autoDetect = $true                  # local client API (agent select + match) with log fallback (map, match only)
    autoShow = $true                    # hide in the menus, show from agent select through the match
    onlyInGame = $true                  # keys act only while Valorant is the foreground window (quit is always global)
    hotkeys = [ordered]@{
        prevStep = 'Left'; nextStep = 'Right'; prevLineup = 'Down'; nextLineup = 'Up'   # Up counts up (Strat 1 -> 2)
        toggle = 'Tab'                                                    # Tab passes through to the game (scoreboard) as well
        nextType = '\'                                                    # cycles the type blocks under the card
        # the number keys are off ('' = not bound; user: no number inputs): 5 next site, 6 / 7 manual agent / map,
        # Alt+5 next monitor (the app's Screen picker does that now). Set them in config.json to bring any back.
        nextOption = ''; nextAgent = ''; nextMap = ''; nextMonitor = ''
        nudgeLeft = 'Alt+Left'; nudgeRight = 'Alt+Right'; nudgeUp = 'Alt+Up'; nudgeDown = 'Alt+Down'
        quit = 'Ctrl+Shift+Q'
    }
}
if (Test-Path $configPath) {
    $j = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'monitor', 'width', 'offsetX', 'offsetY') { if ($null -ne $j.$k -and "$($j.$k)" -ne '') { $cfg[$k] = [int]$j.$k } }
    if ($j.anchor -and $j.anchor -match '^(top|bottom)-(left|right)$') { $cfg.anchor = [string]$j.anchor }
    if ($null -ne $j.autoDetect) { $cfg.autoDetect = [bool]$j.autoDetect }
    if ($null -ne $j.autoShow)   { $cfg.autoShow = [bool]$j.autoShow }
    if ($null -ne $j.onlyInGame) { $cfg.onlyInGame = [bool]$j.onlyInGame }
    if ($j.hotkeys)   { foreach ($p in $j.hotkeys.PSObject.Properties)   { if ($cfg.hotkeys.Contains($p.Name)) { $cfg.hotkeys[$p.Name] = [string]$p.Value } } }
}
function Save-Config {
    [ordered]@{ monitor = $cfg.monitor; width = $cfg.width; anchor = $cfg.anchor; offsetX = $cfg.offsetX; offsetY = $cfg.offsetY
                autoDetect = $cfg.autoDetect; autoShow = $cfg.autoShow; onlyInGame = $cfg.onlyInGame; hotkeys = $cfg.hotkeys } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    if ($ST -and $ST.ContainsKey('cfgStamp')) { $ST.cfgStamp = (Get-Item $configPath).LastWriteTimeUtc }   # our own write: not a change from the app
}

# "Ctrl+Shift+Q" / "5" / "Left"  ->  @{ mods = <RegisterHotKey modifier bits>; vk = <virtual key> }
function Parse-Hotkey([string]$spec) {
    $mods = 0; $vk = $null
    foreach ($part in ($spec -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        switch -Regex ($part) {
            '^(ctrl|control)$' { $mods = $mods -bor 2; continue }
            '^shift$'          { $mods = $mods -bor 4; continue }
            '^alt$'            { $mods = $mods -bor 1; continue }
            '^(win|windows)$'  { $mods = $mods -bor 8; continue }
            '^[0-9]$'          { $vk = [int][System.Windows.Forms.Keys]"D$part"; continue }
            '^=$'              { $vk = [int][System.Windows.Forms.Keys]::Oemplus; continue }          # the = / + key
            '^-$'              { $vk = [int][System.Windows.Forms.Keys]::OemMinus; continue }
            '^\[$'             { $vk = [int][System.Windows.Forms.Keys]::OemOpenBrackets; continue }
            '^\]$'             { $vk = [int][System.Windows.Forms.Keys]::OemCloseBrackets; continue }
            '^;$'              { $vk = [int][System.Windows.Forms.Keys]::OemSemicolon; continue }
            "^'$"              { $vk = [int][System.Windows.Forms.Keys]::OemQuotes; continue }
            '^`$'              { $vk = [int][System.Windows.Forms.Keys]::Oemtilde; continue }
            '^\\$'             { $vk = [int][System.Windows.Forms.Keys]::OemPipe; continue }          # the \ / | key (above Enter)
            default            { $vk = [int][System.Windows.Forms.Keys]$part }
        }
    }
    if ($null -eq $vk) { throw "Bad hotkey '$spec'" }
    @{ mods = $mods; vk = $vk }
}
function Key-Label([string]$spec) { ($spec -replace '\+', ' ').ToLower() }

# --- theme: black / grey, translucent, rounded ----------------------------------------------
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function P([int]$x, [int]$y) { New-Object System.Drawing.Point $x, $y }
$CLR_BG = C '#0c0c0c'; $CLR_TEXT = C '#f2f2f2'; $CLR_DIM = C '#9a9a9a'; $CLR_KEY = C '#6e6e6e'; $CLR_AUTO = C '#6fbf73'
$CLR_ROW = C '#171717'
# type: Bahnschrift (the DIN face that ships with Windows), matching Valorant's DIN-style UI
$FONT_T = New-Object System.Drawing.Font 'Bahnschrift SemiBold', 10  # lineup title
$FONT_V = New-Object System.Drawing.Font 'Bahnschrift SemiBold', 8   # row values
$FONT   = New-Object System.Drawing.Font 'Bahnschrift', 8.5          # caption
$FONT_K = New-Object System.Drawing.Font 'Bahnschrift', 7            # keys

# layout: media left, readout column right, title + caption under both
$WIDTH = [Math]::Max(300, [int]$cfg.width)
$PAD = 8; $RADIUS = 12; $GAP = 3
$INNER = $WIDTH - 2 * $PAD
$MENU_W = 108                          # narrow readout column: most of the width goes to the video
$MEDIA_W = $INNER - $MENU_W - $PAD; $MEDIA_H = [int]($MEDIA_W * 9 / 16)
$MX = $PAD + $MEDIA_W + $PAD
$ROW_H = [int](($MEDIA_H - 4 * $GAP) / 5)
$MEDIA_H = 5 * $ROW_H + 4 * $GAP       # snap the preview height to the rows so their bottoms line up

function Set-Rounded($ctl, [int]$r) {
    $w = $ctl.Width; $h = $ctl.Height; $d = 2 * $r
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $h - $d, $d, $d, 0, 90); $path.AddArc(0, $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $ctl.Region = New-Object System.Drawing.Region $path
}
function Text-Width([string]$text, $font) { [System.Windows.Forms.TextRenderer]::MeasureText($text, $font).Width }

# --- form -----------------------------------------------------------------------------------
$form = New-Object OverlayForm
$form.Text = 'Valorant Lineups'
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.BackColor = $CLR_BG
$form.ForeColor = $CLR_TEXT
$form.Opacity = 0.94   # was 0.84: the whole window's opacity also dims the pictures and text, so keep it high

# a fine outline just inside the rounded edge (like the app's cards), so the card reads cleanly over the game
$form.Add_Paint({
    param($sender, $ev)
    $og = $ev.Graphics; $og.SmoothingMode = 'AntiAlias'
    $ow = $form.ClientSize.Width - 2; $oh = $form.ClientSize.Height - 2; $od = 2 * ($RADIUS - 1)
    $op = New-Object System.Drawing.Drawing2D.GraphicsPath
    $op.AddArc(1, 1, $od, $od, 180, 90); $op.AddArc($ow - $od + 1, 1, $od, $od, 270, 90)
    $op.AddArc($ow - $od + 1, $oh - $od + 1, $od, $od, 0, 90); $op.AddArc(1, $oh - $od + 1, $od, $od, 90, 90); $op.CloseFigure()
    $og.DrawPath((New-Object System.Drawing.Pen (C '#2e2e34'), 1), $op)
})
function Add-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $font, $color, [string]$align = 'MiddleLeft', $parent = $form) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = P $x $y; $l.Size = New-Object System.Drawing.Size $w, $h
    $l.Font = $font; $l.ForeColor = $color; $l.TextAlign = $align; $l.BackColor = 'Transparent'; $l.AutoEllipsis = $true
    $parent.Controls.Add($l); return $l
}

$hk = $cfg.hotkeys

# media (left)
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Location = P $PAD $PAD
$pic.Size = New-Object System.Drawing.Size $MEDIA_W, $MEDIA_H
$pic.SizeMode = 'Zoom'; $pic.BackColor = C '#000000'
Set-Rounded $pic 8
$form.Controls.Add($pic)
$badge = Add-Label '' 6 6 28 14 $FONT_K $CLR_TEXT 'MiddleCenter' $pic
$badge.BackColor = C '#2a2a2a'; $badge.Visible = $false
Set-Rounded $badge 4
$anim = New-Object MediaAnimator $pic, $MEDIA_W, $MEDIA_H   # compiled slide transition + zoom pulse

# top of the column: MAP and AGENT as two side-by-side blocks. Both are automatic, so no keys;
# a green dot in the corner means the value came from the game.
$BLK_H = 2 * $ROW_H + $GAP; $BLK_W = [int](($MENU_W - $GAP) / 2)
function Add-Block([int]$x, [string]$caption) {
    $b = New-Object System.Windows.Forms.Panel
    $b.Location = P $x $PAD; $b.Size = New-Object System.Drawing.Size $BLK_W, $BLK_H; $b.BackColor = $CLR_ROW
    Set-Rounded $b 5
    $form.Controls.Add($b)
    # no caption: the content says what it is. Picture fills the block; map name sits centred on its banner.
    $ic = New-Object System.Windows.Forms.PictureBox
    $ic.Location = P 0 0; $ic.Size = New-Object System.Drawing.Size $BLK_W, $BLK_H; $ic.SizeMode = 'Zoom'; $ic.BackColor = 'Transparent'; $ic.Visible = $false
    $b.Controls.Add($ic)
    $val = Add-Label '' 2 0 ($BLK_W - 4) $BLK_H $FONT_V $CLR_TEXT 'MiddleCenter' $b
    $dot = Add-Label ([string][char]0x25CF) ($BLK_W - 11) 0 10 10 $FONT_K $CLR_AUTO 'MiddleCenter' $b   # ● = detected
    $dot.Visible = $false
    @{ panel = $b; dot = $dot; icon = $ic; val = $val }
}
$mapBlock   = Add-Block $MX 'MAP'
$agentBlock = Add-Block ($MX + $BLK_W + $GAP) 'AGENT'
# a map picture cropped to the block's shape and darkened so the name stays readable on top of it.
# Looks for data.mapImages.<Map>, else assets/maps/<map>.png. Cached per map.
function Get-MapBackdrop([string]$mapName) {
    if (-not $mapName) { return $null }
    $key = "bg:$mapName"
    if ($ST.icons.ContainsKey($key)) { return $ST.icons[$key] }
    $rel = $null
    if ($data.mapImages -and $data.mapImages.$mapName) { $rel = $data.mapImages.$mapName }
    else { $rel = "assets/maps/$($mapName.ToLower() -replace '[^a-z0-9]', '').png" }
    $path = Join-Path $root ($rel -replace '/', '\')
    $bmp = $null
    if (Test-Path $path) {
        $src = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))))
        $bmp = New-Object System.Drawing.Bitmap $BLK_W, $BLK_H
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'
        $scale = [Math]::Max($BLK_W / $src.Width, $BLK_H / $src.Height)          # cover: scale up, then centre-crop
        $w = [int]($src.Width * $scale); $h = [int]($src.Height * $scale)
        $g.DrawImage($src, [int](($BLK_W - $w) / 2), [int](($BLK_H - $h) / 2), $w, $h)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(130, 0, 0, 0))), 0, 0, $BLK_W, $BLK_H)
        # extra dark band where the name sits, so bright banners (Summit) read like dark ones (Bind)
        $band = New-Object System.Drawing.Drawing2D.LinearGradientBrush ((New-Object System.Drawing.Point 0, ([int]($BLK_H * 0.2))), (New-Object System.Drawing.Point 0, ([int]($BLK_H * 0.8))), ([System.Drawing.Color]::FromArgb(0, 0, 0, 0)), ([System.Drawing.Color]::FromArgb(0, 0, 0, 0)))
        $blend = New-Object System.Drawing.Drawing2D.ColorBlend 3
        $blend.Colors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, 0, 0, 0), [System.Drawing.Color]::FromArgb(140, 0, 0, 0), [System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        $blend.Positions = [single[]]@(0, 0.5, 1)
        $band.InterpolationColors = $blend
        $g.FillRectangle($band, 0, [int]($BLK_H * 0.2), $BLK_W, [int]($BLK_H * 0.6))
        # the map name is drawn INTO the banner (grayscale anti-aliasing, fixed shadow): a transparent label
        # over the picture used ClearType, which renders differently over bright banners like Summit's
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $nameFont = New-Object System.Drawing.Font 'Bahnschrift SemiBold Condensed', 9.5
        $rect = New-Object System.Drawing.RectangleF 0, 0, $BLK_W, $BLK_H
        $shadowRect = New-Object System.Drawing.RectangleF 0, 1, $BLK_W, $BLK_H
        $g.DrawString($mapName.ToUpper(), $nameFont, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 0, 0, 0))), $shadowRect, $fmt)
        $g.DrawString($mapName.ToUpper(), $nameFont, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 242, 242, 242))), $rect, $fmt)
        $g.Dispose(); $src.Dispose()
    }
    $ST.icons[$key] = $bmp
    $bmp
}

# backdrop for the agent block: a heavily blurred, desaturated, darkened copy of the portrait itself
# (neutral grey, no colour cast). Without a portrait: a soft grey gradient. Cached per agent.
function Get-AgentBackdrop([string]$agentName, $portrait) {
    $key = "bg:agent:$agentName"
    if ($ST.icons.ContainsKey($key)) { return $ST.icons[$key] }
    $bmp = New-Object System.Drawing.Bitmap $BLK_W, $BLK_H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBilinear'
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#1a1a1a'))
    if ($portrait) {
        # blur = shrink to a handful of pixels and stretch back; grey = luminance colour matrix; then darken
        $tiny = New-Object System.Drawing.Bitmap 6, 6
        $tg = [System.Drawing.Graphics]::FromImage($tiny); $tg.InterpolationMode = 'HighQualityBilinear'
        $tg.Clear([System.Drawing.ColorTranslator]::FromHtml('#2a2a2a'))
        $tg.DrawImage($portrait, -1, -1, 8, 8); $tg.Dispose()
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = 0.3; $cm.Matrix01 = 0.3; $cm.Matrix02 = 0.3
        $cm.Matrix10 = 0.59; $cm.Matrix11 = 0.59; $cm.Matrix12 = 0.59
        $cm.Matrix20 = 0.11; $cm.Matrix21 = 0.11; $cm.Matrix22 = 0.11
        $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
        $g.DrawImage($tiny, (New-Object System.Drawing.Rectangle -4, -4, ($BLK_W + 8), ($BLK_H + 8)), 0, 0, 6, 6, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $tiny.Dispose()
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(205, 0, 0, 0))), 0, 0, $BLK_W, $BLK_H)   # much darker: a faint grey ghost of the portrait
    } else {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddEllipse(-$BLK_W * 0.3, -$BLK_H * 0.3, $BLK_W * 1.6, $BLK_H * 1.6)
        $glow = New-Object System.Drawing.Drawing2D.PathGradientBrush $path
        $glow.CenterColor = [System.Drawing.ColorTranslator]::FromHtml('#2b2b2b')
        $glow.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.ColorTranslator]::FromHtml('#141414'))
        $g.FillRectangle($glow, 0, 0, $BLK_W, $BLK_H)
    }
    $g.Dispose()
    $ST.icons[$key] = $bmp
    $bmp
}

function Set-Block($blk, [string]$text, $iconImg, [bool]$auto, $backdrop = $null) {
    $blk.panel.BackgroundImage = $backdrop
    $blk.panel.BackgroundImageLayout = 'None'
    if ($iconImg) {   # picture only, no name
        $blk.icon.Image = $iconImg; $blk.icon.Visible = $true; $blk.val.Visible = $false
        $blk.dot.Parent = $blk.icon      # a transparent label over a sibling PictureBox would paint the panel
    } else {                             # background over it; as a child of the PictureBox it shows the picture
        $blk.icon.Visible = $false; $blk.val.Visible = $true
        $blk.dot.Parent = $blk.panel
    }
    $blk.val.Text = $text
    $blk.dot.Visible = $auto
}

# below the blocks: three one-line rows (option, lineup, step): key at left, value, and a
# right-hand slot for arrows. Labels never overlap: a transparent WinForms label paints the
# parent background over siblings.
$KEY_W = 4; $SLOT_W = 26; $ICON_PX = 16   # KEY_W is now just left padding for the row text
$rows = @()
$rowKeys = @('', '', '')   # no key on the option row (the number keys are unbound)
# the right-hand slot of the lineup and step rows draws two little key caps: [↑][↓] and [←][→]
$rowSlots = @($null, @([char]0x2191, [char]0x2193), @([char]0x2190, [char]0x2192))
$ry = $PAD + $BLK_H + $GAP
for ($i = 0; $i -lt 3; $i++) {
    $r = New-Object System.Windows.Forms.Panel
    $r.Location = P $MX $ry; $r.Size = New-Object System.Drawing.Size $MENU_W, $ROW_H; $r.BackColor = $CLR_ROW
    Set-Rounded $r 5
    $form.Controls.Add($r)
    $key  = Add-Label $rowKeys[$i] 4 0 $KEY_W $ROW_H $FONT_K $CLR_KEY 'MiddleLeft' $r
    $slot = Add-Label '' ($MENU_W - $SLOT_W - 3) 0 $SLOT_W $ROW_H $FONT_K $CLR_DIM 'MiddleRight' $r
    $slot.AutoEllipsis = $false
    $slot.Tag = $rowSlots[$i]
    $slot.Add_Paint({
        param($sender, $ev)
        $caps = $sender.Tag; if (-not $caps) { return }
        $g = $ev.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $cap = 11; $gap = 2; $y0 = [int](($sender.Height - $cap) / 2)
        $x0 = $sender.Width - ($caps.Count * $cap + ($caps.Count - 1) * $gap) - 1
        $pen = New-Object System.Drawing.Pen $CLR_KEY, 1
        $brush = New-Object System.Drawing.SolidBrush $CLR_DIM
        $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        for ($c = 0; $c -lt $caps.Count; $c++) {
            $x = $x0 + $c * ($cap + $gap)
            $g.DrawRectangle($pen, $x, $y0, $cap, $cap)
            $g.DrawString([string]$caps[$c], $FONT_K, $brush, (New-Object System.Drawing.RectangleF $x, ($y0 - 1), ($cap + 1), ($cap + 1)), $fmt)
        }
    })
    $ic = New-Object System.Windows.Forms.PictureBox
    $ic.Location = P ($KEY_W + 2) ([int](($ROW_H - $ICON_PX) / 2)); $ic.Size = New-Object System.Drawing.Size $ICON_PX, $ICON_PX; $ic.SizeMode = 'Zoom'; $ic.BackColor = 'Transparent'; $ic.Visible = $false
    $r.Controls.Add($ic)
    $val = Add-Label '' ($KEY_W + 2) 0 ($MENU_W - $KEY_W - 2 - $SLOT_W - 5) $ROW_H $FONT_V $CLR_TEXT 'MiddleLeft' $r
    $rows += @{ panel = $r; key = $key; slot = $slot; val = $val; icon = $ic }
    $ry += $ROW_H + $GAP
}

# title (with ability icon) + caption across the full width; "0 hide" at the end of the title row
$y = $PAD + $MEDIA_H + $PAD - 2
$hideText = "$(Key-Label $hk.toggle) hide"
$hw = (Text-Width $hideText $FONT_K) + 4
$abilityIcon = New-Object System.Windows.Forms.PictureBox
$abilityIcon.Location = P $PAD ($y + 1); $abilityIcon.Size = New-Object System.Drawing.Size 18, 18; $abilityIcon.SizeMode = 'Zoom'; $abilityIcon.BackColor = 'Transparent'
$form.Controls.Add($abilityIcon)
$lblTitle = Add-Label '' ($PAD + 23) $y ($INNER - 23 - $hw - 6) 20 $FONT_T $CLR_TEXT
Add-Label $hideText ($PAD + $INNER - $hw) $y $hw 20 $FONT_K $CLR_KEY 'MiddleRight' | Out-Null
$y += 21
$lblCaption = Add-Label '' $PAD $y ($INNER - 164) 16 $FONT $CLR_DIM 'MiddleLeft'
$lblCaption.AutoEllipsis = $true   # a long step note ends in "..." instead of running under the difficulty
$lblDiff = Add-Label '' ($PAD + $INNER - 160) $y 160 16 (New-Object System.Drawing.Font 'Bahnschrift SemiBold', 8) $CLR_DIM 'MiddleRight'   # difficulty, in its colour
$y += 15
# speed (post-plants only) stacked under the difficulty, in its own blue family so it never reads as difficulty
$lblSpeed = Add-Label '' ($PAD + $INNER - 160) $y 160 13 (New-Object System.Drawing.Font 'Bahnschrift SemiBold', 7.5) $CLR_DIM 'MiddleRight'
$y += 13 + $PAD - 3
# strat types as shown in the overlay (keys match TYPES in web\editor.html)
# ('smoke' shows as "smokes": "optimal smokes" is too wide for the row)
$TYPE_NAMES = @{ 'post-plant' = 'post-plant'; 'entry' = 'entry'; 'smoke' = 'smokes'; 'one-way' = 'one-way'; 'flash' = 'flash'; 'recon' = 'recon'; 'setup' = 'site setup'; 'deny' = 'deny space' }
# type order (same as TYPES in web\editor.html) and short names for the counter row (71 px wide)
$TYPE_ORDER = @('post-plant', 'entry', 'smoke', 'one-way', 'flash', 'recon', 'setup', 'deny')
# ('post-plant' shows as "Plants": "Post-plant 1/4" is wider than the row)
$TYPE_SHORT = @{ 'post-plant' = 'Plants'; 'entry' = 'Entry'; 'smoke' = 'Smokes'; 'one-way' = 'One-way'; 'flash' = 'Flash'; 'recon' = 'Recon'; 'setup' = 'Setup'; 'deny' = 'Deny' }
$SPEED = @{
    fast     = @{ text = 'Fast';     color = C '#5fd0ff' }
    moderate = @{ text = 'Moderate'; color = C '#8fa6ff' }
    slow     = @{ text = 'Slow';     color = C '#a98bff' }
}
$DIFFICULTY = @{
    easy         = @{ text = 'Easy';         color = C '#5fc96b' }
    intermediate = @{ text = 'Intermediate'; color = C '#e3c34a' }
    challenging  = @{ text = 'Challenging';  color = C '#e2564f' }
}

$HEIGHT = $y
$form.ClientSize = New-Object System.Drawing.Size $WIDTH, $HEIGHT
Set-Rounded $form $RADIUS

# --- placement ------------------------------------------------------------------------------
function Place-OnMonitor {
    if ($ScreenshotPath) { $form.Location = P -7000 -7000; return }   # test runs draw off-screen, never over the game
    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($cfg.monitor -lt 1 -or $cfg.monitor -gt $screens.Count) { $cfg.monitor = 1 }
    $b = $screens[$cfg.monitor - 1].Bounds
    # until the game has told us the agent, the panel waits in the bottom-right corner, out of the way;
    # once the agent is known it moves to its configured spot
    $anchor = $cfg.anchor; $ox = $cfg.offsetX; $oy = $cfg.offsetY
    if ($ST.sel.Agent -lt 0) { $anchor = 'bottom-right'; $ox = 16; $oy = 16 }
    $x = if ($anchor -like '*-left') { $b.Left + $ox } else { $b.Right - $WIDTH - $ox }
    $y = if ($anchor -like 'top-*')  { $b.Top + $oy }  else { $b.Bottom - $HEIGHT - $oy }
    $form.Location = P $x $y
}
# --- type blocks: small separate blocks floating just under the card, one per strat type this agent has on
# this map (with the key that cycles them and All first), the picked one in red; with a single type just that
# one block. The card itself is exactly as before. A second click-through window that follows the card.
$tabForm = New-Object OverlayForm
$tabForm.Text = 'Valorant Lineups types'; $tabForm.FormBorderStyle = 'None'; $tabForm.TopMost = $true
$tabForm.ShowInTaskbar = $false; $tabForm.StartPosition = 'Manual'; $tabForm.BackColor = $CLR_BG; $tabForm.Opacity = 0.94
$TB_H = 20; $TB_GAP = 5; $TB_PAD = 9
$ST.tbItems = @()
# double-buffered painting (off-screen, then one blit): switching tabs and the highlight glide must not flicker.
# DoubleBuffered / SetStyle are protected, hence reflection.
$tbFlags = [System.Reflection.BindingFlags]'NonPublic, Instance'
[System.Windows.Forms.Control].GetProperty('DoubleBuffered', $tbFlags).SetValue($tabForm, $true, $null)
[System.Windows.Forms.Control].GetMethod('SetStyle', $tbFlags).Invoke($tabForm, @(([System.Windows.Forms.ControlStyles]'OptimizedDoubleBuffer, AllPaintingInWmPaint, UserPaint'), $true))
$tabForm.Add_Paint({
    param($sender, $ev)
    $tbG = $ev.Graphics; $tbG.SmoothingMode = 'AntiAlias'; $tbG.TextRenderingHint = 'ClearTypeGridFit'
    $tbFmt = New-Object System.Drawing.StringFormat; $tbFmt.Alignment = 'Center'; $tbFmt.LineAlignment = 'Center'
    # the red highlight is drawn at its (possibly gliding) position; the window's region clips it to the blocks
    if ($ST.tbHi) { $tbG.FillRectangle((New-Object System.Drawing.SolidBrush (C '#ff4655')), (New-Object System.Drawing.RectangleF $ST.tbHi.x, 0, $ST.tbHi.w, $TB_H)) }
    foreach ($tbI in $ST.tbItems) {
        $tbRect = New-Object System.Drawing.RectangleF $tbI.x, 0, $tbI.w, $TB_H
        $tbCol = if ($tbI.on) { [System.Drawing.Color]::White } elseif ($tbI.key) { $CLR_KEY } else { $CLR_DIM }
        $tbG.DrawString($tbI.text, $(if ($tbI.key) { $FONT_K } else { $FONT_V }), (New-Object System.Drawing.SolidBrush $tbCol), $tbRect, $tbFmt)
    }
})
function Update-TypeBlocks {
    if (-not $tabForm) { return }
    $want = $form.Visible -and $ST.types -and $ST.types.Count -ge 1
    if (-not $want) { if ($tabForm.Visible) { $tabForm.Hide() }; return }
    $one = $ST.types.Count -eq 1   # a single type: just its block (lit); nothing to cycle, so no key or All
    $labels = @()
    if (-not $one) { $labels += @{ text = (Key-Label $hk.nextType); key = $true; on = $false }; $labels += @{ text = 'All'; key = $false; on = (-not $ST.typeTab) } }
    foreach ($tv in $ST.types) {
        $cnt = @($ST.full | Where-Object { (Type-Of $_) -eq $tv }).Count
        $nm = if ($tv -eq 'post-plant') { 'Post-plant' } elseif ($TYPE_SHORT.ContainsKey($tv)) { $TYPE_SHORT[$tv] } else { $tv }
        $labels += @{ text = "$nm $cnt"; key = $false; on = ($one -or $ST.typeTab -eq $tv) }
    }
    $x = 0; $items = @()
    foreach ($lb in $labels) { $w = (Text-Width $lb.text $(if ($lb.key) { $FONT_K } else { $FONT_V })) + 2 * $TB_PAD - 6; $items += @{ x = $x; w = $w; text = $lb.text; key = $lb.key; on = $lb.on }; $x += $w + $TB_GAP }
    # highlight: glide from the old block to the new one in 0.12 s when only the pick changed; jump otherwise
    $onItem = $items | Where-Object { $_.on } | Select-Object -First 1
    $sameLayout = $ST.tbItems -and $ST.tbItems.Count -eq $items.Count -and (@($ST.tbItems | ForEach-Object { $_.text }) -join '|') -eq (@($items | ForEach-Object { $_.text }) -join '|')
    if ($onItem -and $ST.tbHi -and $sameLayout -and ($ST.tbHi.x -ne $onItem.x)) {
        $ST.tbFrom = @{ x = $ST.tbHi.x; w = $ST.tbHi.w }; $ST.tbTo = @{ x = $onItem.x; w = $onItem.w }; $ST.tbT0 = Get-Date; $ST.tbTimer.Start()
    } else {
        $ST.tbTimer.Stop(); $ST.tbHi = if ($onItem) { @{ x = $onItem.x; w = $onItem.w } } else { $null }
    }
    $ST.tbItems = $items
    $totalW = $x - $TB_GAP
    # size and shape only change when the set of blocks does: re-setting them on every tab switch made Windows
    # repaint the whole window, which was the ugly flash
    if (-not $sameLayout -or $tabForm.ClientSize.Width -ne $totalW) {
        $tabForm.ClientSize = New-Object System.Drawing.Size $totalW, $TB_H
        # each block is its own rounded shape: the window's region is their union, so they float apart
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = 12
        foreach ($it in $items) {
            $path.StartFigure()
            $path.AddArc($it.x, 0, $d, $d, 180, 90); $path.AddArc($it.x + $it.w - $d, 0, $d, $d, 270, 90)
            $path.AddArc($it.x + $it.w - $d, $TB_H - $d, $d, $d, 0, 90); $path.AddArc($it.x, $TB_H - $d, $d, $d, 90, 90)
            $path.CloseFigure()
        }
        $tabForm.Region = New-Object System.Drawing.Region $path
    }
    # under the card, lined up with its anchored side; above it when the card sits at the bottom of the screen
    $scr = [System.Windows.Forms.Screen]::FromControl($form).Bounds
    $tx = if ($cfg.anchor -like '*-left') { $form.Left } else { $form.Right - $totalW }
    $ty = if ($form.Bottom + 6 + $TB_H -le $scr.Bottom) { $form.Bottom + 6 } else { $form.Top - 6 - $TB_H }
    if ($tabForm.Left -ne $tx -or $tabForm.Top -ne $ty) { $tabForm.Location = P $tx $ty }
    $tabForm.Invalidate()
    if (-not $tabForm.Visible) { $tabForm.Opacity = $form.Opacity; $tabForm.Show() }   # fades together with the card
}
$ST.tbTimer = New-Object System.Windows.Forms.Timer; $ST.tbTimer.Interval = 15
$ST.tbTimer.Add_Tick({
    $gk = [Math]::Min(1, ((Get-Date) - $ST.tbT0).TotalSeconds / 0.12); $ge = 1 - [Math]::Pow(1 - $gk, 3)
    $ST.tbHi = @{ x = $ST.tbFrom.x + ($ST.tbTo.x - $ST.tbFrom.x) * $ge; w = $ST.tbFrom.w + ($ST.tbTo.w - $ST.tbFrom.w) * $ge }
    $tabForm.Invalidate()
    if ($gk -ge 1) { $ST.tbTimer.Stop() }
})
$form.Add_LocationChanged({ Update-TypeBlocks })
$form.Add_VisibleChanged({ Update-TypeBlocks })
function Next-Monitor {
    $count = [System.Windows.Forms.Screen]::AllScreens.Count
    $cfg.monitor = ($cfg.monitor % $count) + 1
    Place-OnMonitor; Save-Config
}
function Nudge([int]$dx, [int]$dy) {   # dx/dy are screen directions; offsets grow away from the anchored edges
    $sx = if ($cfg.anchor -like '*-left') { 1 } else { -1 }
    $sy = if ($cfg.anchor -like 'top-*')  { 1 } else { -1 }
    $cfg.offsetX = [Math]::Max(0, $cfg.offsetX + $sx * $dx)
    $cfg.offsetY = [Math]::Max(0, $cfg.offsetY + $sy * $dy)
    Place-OnMonitor; Save-Config
}
Place-OnMonitor

# --- logic ----------------------------------------------------------------------------------
function Get-Icon([string]$rel) {
    if (-not $rel) { return $null }
    if (-not $ST.icons.ContainsKey($rel)) {
        $path = Join-Path $root ($rel -replace '/', '\')
        $ST.icons[$rel] = if (Test-Path $path) { [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path)))) } else { $null }
    }
    $ST.icons[$rel]
}
function Current-Map   { if ($ST.sel.Map -ge 0)   { $MAPS[$ST.sel.Map % $MAPS.Count] }       else { $null } }
function Current-Agent { if ($ST.sel.Agent -ge 0) { $AGENTS[$ST.sel.Agent % $AGENTS.Count] } else { $null } }

# "zoom": 4  or  "zoom": { "factor": 4, "x": 0.5, "y": 0.5 }  (x/y = focus point as a fraction of the image)
function Parse-Zoom($spec) {
    $z = @{ on = $false; factor = 4.0; fx = 0.5; fy = 0.5; hold = $false }
    if ($null -eq $spec) { return $z }
    if ($spec -is [bool]) { $z.on = $spec; return $z }
    if ($spec -is [ValueType]) { $z.factor = [double]$spec; $z.on = $z.factor -gt 1; return $z }
    if ($spec.factor) { $z.factor = [double]$spec.factor }
    if ($null -ne $spec.x) { $z.fx = [double]$spec.x }
    if ($null -ne $spec.y) { $z.fy = [double]$spec.y }
    $z.hold = ([string]$spec.mode -eq 'hold')   # "hold" = stays zoomed in; anything else pulses
    $z.on = $z.factor -gt 1
    $z
}
# seconds picture k of a step shows before the next: its own "picTime" entry, else the older step-wide
# "interval", else 1.8
function Pic-Time($step, [int]$k) {
    if ($null -ne $step.picTime) { $t = @($step.picTime); if ($k -lt $t.Count -and $t[$k]) { return [Math]::Max(0.4, [double]$t[$k]) } }
    if ($step.interval) { return [Math]::Max(0.4, [double]$step.interval) }
    1.8
}

# steps with several pictures cycle through them; $ST.sub is which one is showing
$ST.sub = 0
# zoom for picture k of a step: its own entry in "picZoom" when the step has several pictures,
# otherwise the step's "zoom" (older lineups set one zoom for the whole step)
function Pic-Zoom($step, [int]$k) {
    if ($null -ne $step.picZoom) { $z = @($step.picZoom); if ($k -lt $z.Count) { return $z[$k] } else { return $null } }
    $step.zoom
}
$ST.subTimer = New-Object System.Windows.Forms.Timer; $ST.subTimer.Interval = 1800
$ST.subTimer.Add_Tick({
    try {
        if ($ST.all.Count -eq 0) { $ST.subTimer.Stop(); return }
        $srcs = @($ST.all[$ST.li].steps[$ST.si].src)
        if ($srcs.Count -lt 2) { $ST.subTimer.Stop(); return }
        $ST.sub = ($ST.sub + 1) % $srcs.Count
        $st2 = $ST.all[$ST.li].steps[$ST.si]
        Set-Image (Join-Path $root ([string]$srcs[$ST.sub] -replace '/', '\')) (Pic-Zoom $st2 $ST.sub) $true   # $true = crossfade
        $ST.subTimer.Interval = [int]((Pic-Time $st2 $ST.sub) * 1000)   # the picture now showing sets the wait for the next
    } catch { $ST.subTimer.Stop(); Write-Host "pictures: $_" }
})

# swap the preview to a new file: a clean cut between steps, a short crossfade between the pictures
# of one step ($fade), then zoom-pulse if the step asks
function Set-Image([string]$path, $zoom = $null, [bool]$fade = $false) {
    # switching strat or type (Up / Down / \) gets a very quick crossfade; pictures within a step keep their
    # normal 0.28 s one; changing step stays a plain cut (the user's choice)
    $quick = [bool]$ST.quickFade; $ST.quickFade = $false
    $anim.TransitionSeconds = if ($quick) { 0.12 } else { 0.28 }
    $fade = $fade -or $quick
    $from = if ($fade -and $pic.Image -and $form.Visible) { $anim.Snapshot() } else { $null }
    $anim.Stop()
    $old = $ST.image
    if ($path -and (Test-Path $path)) {
        $ms = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))   # load from memory so the file isn't locked
        $ST.image = [System.Drawing.Image]::FromStream($ms)
    } else {
        $ST.image = $null
    }
    $z = Parse-Zoom $zoom
    if ($z.on -and $ST.image) {   # stills only; an animated GIF keeps playing as-is
        $frames = $ST.image.GetFrameCount((New-Object System.Drawing.Imaging.FrameDimension ($ST.image.FrameDimensionsList[0])))
        if ($frames -gt 1) { $z.on = $false }
    }
    $anim.Show($ST.image, $from, [int]$ST.dir[0], [int]$ST.dir[1], $z.on, $z.fx, $z.fy, $z.factor, 4.5, [bool]$z.hold)
    $ST.dir = @(0, 0)   # direction is set by the key that caused the change; anything else crossfades
    if ($old) { $old.Dispose() }
}

function Set-Row([int]$i, [string]$text, $iconImg = $null, $slot = $null, $slotColor = $null) {
    # $slot is deliberately untyped: a [string] parameter turns $null into '' and would wipe the arrows
    $r = $rows[$i]
    if ($iconImg) {
        $r.icon.Image = $iconImg; $r.icon.Visible = $true
        $r.val.Left = $KEY_W + 2 + $ICON_PX + 4
    } else {
        $r.icon.Visible = $false
        $r.val.Left = $KEY_W + 2
    }
    $r.val.Width = $MENU_W - $r.val.Left - $SLOT_W - 5
    $r.val.Text = $text
    if ($null -ne $slot) { $r.slot.Text = $slot }
    if ($null -ne $slotColor) { $r.slot.ForeColor = $slotColor }
}

function Render {
    Update-TypeBlocks   # the floating type blocks under the card follow the current list / picked type
    $mapName = [string](Current-Map)
    $ag = Current-Agent
    # blocks stay blank until the game has told us the map / locked agent
    if ($mapName) {   # with a banner the name is already drawn into it; the label is only used when there is no picture
        $bd = Get-MapBackdrop $mapName
        Set-Block $mapBlock $(if ($bd) { '' } else { $mapName }) $null ($ST.det.map -eq $mapName) $bd
    }
    else          { Set-Block $mapBlock '' $null $false $null }
    if ($ag)      { $portrait = Get-Icon $ag.icon; Set-Block $agentBlock ([string]$ag.name) $portrait ($ST.det.agent -eq $ag.name) (Get-AgentBackdrop $ag.name $portrait) }
    else          { Set-Block $agentBlock '' $null $false (Get-AgentBackdrop '' $null) }

    $n = $ST.all.Count
    if ($n -eq 0) {
        Set-Row 0 ''; Set-Row 1 ''; Set-Row 2 ''
        Set-Image $null; $badge.Visible = $false
        $abilityIcon.Image = $null
        if ($mapName -and $ag) { $lblTitle.Text = 'No strats yet'; $lblCaption.Text = "Nothing saved for $($ag.name) on $mapName." }
        else                   { $lblTitle.Text = 'Waiting for agent select'; $lblCaption.Text = '' }
        $lblDiff.Text = ''; $lblSpeed.Text = ''
        return
    }
    $L = $ST.all[$ST.li]
    $step = $L.steps[$ST.si]
    # site + the strat type's display name (the type keys are internal: 'smoke' -> 'smokes', 'setup' -> 'site setup')
    $typeKey = if ($L.type) { ([string]$L.type).ToLower() } else { 'post-plant' }
    $typeName = if ($TYPE_NAMES.ContainsKey($typeKey)) { $TYPE_NAMES[$typeKey] } else { $typeKey }
    Set-Row 0 $(if ($L.site) { "$($L.site) $typeName" } else { [string]$L.option })
    Set-Row 1 "Strat $($ST.li + 1) / $n"
    Set-Row 2 "Step $($ST.si + 1) / $($L.steps.Count)"
    # a step may carry several pictures ("src": [..]); they cycle every few seconds
    $srcs = @($step.src)
    if ($ST.sub -ge $srcs.Count) { $ST.sub = 0 }
    Set-Image (Join-Path $root ([string]$srcs[$ST.sub] -replace '/', '\')) (Pic-Zoom $step $ST.sub)
    if ($srcs.Count -gt 1) {   # each step sets its own swap time ("interval", seconds); 1.8 s if not set
        $ST.subTimer.Interval = [int]((Pic-Time $step $ST.sub) * 1000); $ST.subTimer.Start()   # each picture has its own time
    } else { $ST.subTimer.Stop() }
    $badge.Visible = $false   # no PNG / GIF tag on the preview
    $abilityIcon.Image = Get-Icon $data.abilities.($L.ability)
    $lblTitle.Text = $L.title
    $dk = ([string]$L.difficulty).ToLower()
    $sk = ([string]$L.speed).ToLower(); if ($sk -eq 'average') { $sk = 'moderate' }   # 'average' is the old name of 'moderate'
    # difficulty on the step-name row, speed (fast / moderate / slow, blank if unmarked) stacked under it
    if ($DIFFICULTY.ContainsKey($dk)) { $lblDiff.Text = $DIFFICULTY[$dk].text; $lblDiff.ForeColor = $DIFFICULTY[$dk].color } else { $lblDiff.Text = '' }
    if ($SPEED.ContainsKey($sk)) { $lblSpeed.Text = $SPEED[$sk].text; $lblSpeed.ForeColor = $SPEED[$sk].color } else { $lblSpeed.Text = '' }
    # under the title: the step's name, its short note ("jump throw"), and on the Aim step (or the last
    # step) a bolt's bounces / charge; same text as the app's "Overlay shows" line and its preview
    $capParts = @(Step-Label $step $ST.si)
    # only notes written in the app's Note box ("notes"); older strats' long how-to captions stay hidden
    $stepNote = if ($step.notes) { [string]$step.notes } else { '' }
    if ($stepNote) { $capParts += $stepNote }
    $aimIx = $L.steps.Count - 1
    for ($ix2 = 0; $ix2 -lt $L.steps.Count; $ix2++) { if ((Step-Label $L.steps[$ix2] $ix2) -eq 'Aim') { $aimIx = $ix2; break } }
    if ($ST.si -eq $aimIx -and @('Recon Bolt', 'Shock Bolt') -contains [string]$L.ability) {
        if ($null -ne $L.bounces) { $capParts += "$($L.bounces) bounce$(if ([int]$L.bounces -ne 1) { 's' })" }
        if ($null -ne $L.charge)  { $capParts += "$($L.charge) charge" }
    }
    $lblCaption.Text = $capParts -join "  $([char]0x00B7)  "
}
# a step's name: "label" (current format), else the "Name:" in front of an older caption, else by position
function Step-Label($stp, [int]$index) {
    if ($stp.label) { return [string]$stp.label }
    if ($stp.caption -match '^\s*([A-Za-z][\w -]*?)\s*(:|$)') { return $Matches[1] }
    return @('Plant', 'Stand', 'Aim')[[Math]::Min($index, 2)]
}

# every strat for the current map + agent ($ST.full), grouped by type in the app's type order (file order
# within a type). $ST.all is what Up / Down walk: all of them, or only the type "tab" picked with the 5 key.
function Type-Of($L) { if ($L.type) { ([string]$L.type).ToLower() } else { 'post-plant' } }
# $ST.full: every strat for this map + agent, in file order (exactly as before). $ST.types: the types among
# them, in the app's order. $ST.typeTab: the type block picked with the nextType key (null = All); $ST.all,
# what Up / Down / 5 walk, is $ST.full narrowed to that type.
function Apply-Type { $ST.all = @(if ($ST.typeTab) { $ST.full | Where-Object { (Type-Of $_) -eq $ST.typeTab } } else { $ST.full }) }
function Refresh-Lineups {
    $m = Current-Map; $a = Current-Agent
    $ST.full = @(if ($m -and $a) { $data.lineups | Where-Object { $_.map -eq $m -and $_.agent -eq $a.name } })   # @(): keep a 1-element result a list
    $present = @($ST.full | ForEach-Object { Type-Of $_ } | Select-Object -Unique)
    $ST.types = @($TYPE_ORDER | Where-Object { $present -contains $_ }) + @($present | Where-Object { $TYPE_ORDER -notcontains $_ })
    $key = "$m|$(if ($a) { $a.name })"
    if ($ST.tabFor -ne $key) { $ST.tabFor = $key; $ST.typeTab = $null }   # new map or agent: back to All
    if ($ST.typeTab -and $ST.types -notcontains $ST.typeTab) { $ST.typeTab = $null }
    Apply-Type
    if ($ST.li -ge $ST.all.Count) { $ST.li = 0 }
    if ($ST.all.Count -and $ST.si -ge $ST.all[$ST.li].steps.Count) { $ST.si = 0 }
    Render
    Place-OnMonitor   # bottom-right while the agent is unknown, the configured spot once it is
}

# steps slide horizontally, lineups vertically, in the direction of the key that was pressed
function Move-Lineup([int]$d) { $n = $ST.all.Count; if ($n) { $ST.li = ($ST.li + $d + $n) % $n; $ST.si = 0; $ST.sub = 0; $ST.dir = @(0, $d); $ST.quickFade = ($n -gt 1); Render } }
function Move-Step([int]$d)   { if ($ST.all.Count) { $c = $ST.all[$ST.li].steps.Count; $ST.si = ($ST.si + $d + $c) % $c; $ST.sub = 0; $ST.dir = @($d, 0); Render } }
# the nextType key (the overlay is click-through, so a key instead of clicking): the type blocks under the
# card, All -> each type this agent has on this map -> All. Up / Down then only walk that type.
function Next-Type {
    if ($ST.types.Count -lt 2) { return }
    $i = if ($ST.typeTab) { [array]::IndexOf([object[]]$ST.types, $ST.typeTab) } else { -1 }
    $ST.typeTab = if ($i + 1 -lt $ST.types.Count) { $ST.types[$i + 1] } else { $null }
    Apply-Type
    $ST.li = 0; $ST.si = 0; $ST.sub = 0; $ST.dir = @(0, 1); $ST.quickFade = $true; Render
}
function Next-Option {
    $n = $ST.all.Count; if ($n -eq 0) { return }
    $cur = $ST.all[$ST.li].option
    for ($k = 1; $k -le $n; $k++) {           # first lineup whose option differs, wrapping around
        $ix = ($ST.li + $k) % $n
        if ($ST.all[$ix].option -ne $cur) { $ST.li = $ix; $ST.si = 0; $ST.dir = @(0, 1); Render; return }
    }
}
function Cycle-Map([int]$d)   { $ST.sel.Map = ($ST.sel.Map + $d + $MAPS.Count) % $MAPS.Count; $ST.li = 0; $ST.si = 0; Refresh-Lineups }
function Cycle-Agent([int]$d) { $ST.sel.Agent = ($ST.sel.Agent + $d + $AGENTS.Count) % $AGENTS.Count; $ST.li = 0; $ST.si = 0; Refresh-Lineups }

# apply a detected map / agent. Only a CHANGE in what is detected moves the selection, so a manual
# override (6 / 7) sticks until the game reports something new.
function Apply-Detected([string]$mapName, [string]$agentName, [string]$source) {
    $changed = $false
    if ($mapName -and $mapName -ne $ST.det.map) {
        $ST.det.map = $mapName
        $ix = $MAPS.IndexOf($mapName)
        if ($ix -lt 0) { [void]$MAPS.Add($mapName); $ix = $MAPS.Count - 1; Write-DetectLog "map '$mapName' detected; no lineups for it yet" }
        $ST.sel.Map = $ix; $changed = $true
        Write-DetectLog "map -> $mapName ($source)"
    }
    if ($agentName -and $agentName -ne $ST.det.agent) {
        $ST.det.agent = $agentName
        $ix = [array]::IndexOf(@($AGENTS | ForEach-Object { $_.name }), $agentName)
        if ($ix -lt 0) { [void]$AGENTS.Add([pscustomobject]@{ name = $agentName; icon = "assets/icons/agent-$($agentName.ToLower() -replace '[^a-z]', '').png" }); $ix = $AGENTS.Count - 1 }
        $ST.sel.Agent = $ix; $changed = $true
    }
    if ($source) { $ST.det.source = $source }
    if ($changed) {
        $ST.li = 0; $ST.si = 0
        Refresh-Lineups     # also re-places it: bottom-right until the agent is known, then its spot
        Update-Visibility   # appears once the map is known
    }
}


# --- detection: Riot local client API (read-only) on a BACKGROUND thread, log fallback -------
# All network and file polling happens in a worker runspace and lands in $sync; the UI thread only
# reads $sync once a second, so the preview animations never wait on a request.
# Riot names maps and agents by internal name / UUID; these tables translate them.
$MAP_INTERNAL = @{
    Ascent = 'Ascent'; Duality = 'Bind'; Triad = 'Haven'; Bonsai = 'Split'; Port = 'Icebox'; Foxtrot = 'Breeze'
    Canyon = 'Fracture'; Pitt = 'Pearl'; Jam = 'Lotus'; Juliett = 'Sunset'; Infinity = 'Abyss'; Rook = 'Corrode'
    Plummet = 'Summit'
}
$AGENT_IDS = @{
    '9f0d8ba9-4140-b941-57d3-a7ad57c6b417' = 'Brimstone'; '320b2a48-4d9b-a075-30f1-1f93a9b638fa' = 'Sova'
    '707eab51-4836-f488-046a-cda6bf494859' = 'Viper';     '8e253930-4c05-31dd-1b6c-968525494517' = 'Omen'
    '1e58de9c-4950-5125-93e9-a0aee9f98746' = 'Killjoy';   '117ed9e3-49f3-6512-3ccf-0cada7e3823b' = 'Cypher'
    '569fdd95-4d10-43ab-ca70-79becc718b46' = 'Sage';      'eb93336a-449b-9c1b-0a54-a891f7921d69' = 'Phoenix'
    'add6443a-41bd-e414-f6ad-e58d267f4e95' = 'Jett';      'a3bfb853-43b2-7238-a4f1-ad90e9e46bcc' = 'Reyna'
    'f94c3b30-42be-e959-889c-5aa313dba261' = 'Raze';      '5f8d3a7f-467b-97f3-062c-13acf203c006' = 'Breach'
    '6f2a04ca-43e0-be17-7f36-b3908627744d' = 'Skye';      '7f94d92c-4234-0a36-9646-3a87eb8b5c89' = 'Yoru'
    '41fb69c1-4189-7b37-f117-bcaf1e96f1bf' = 'Astra';     '601dbbe7-43ce-be57-2a40-4abd24953621' = 'KAY/O'
    '22697a3d-45bf-8dd7-4fec-84a9e28c69d7' = 'Chamber';   'bb2a4828-46eb-8cd1-e765-15848195d751' = 'Neon'
    'dade69b4-4f5a-8528-247b-219e5a1facd6' = 'Fade';      '95b78ed7-4637-86d9-7e41-71ba8c293152' = 'Harbor'
    'e370fa57-4757-3604-3648-499e1f642d3f' = 'Gekko';     'cc8b64c8-4b25-4ff9-6e7f-37b4da43d235' = 'Deadlock'
    '0e38b510-41a8-5780-5e8f-568b2a4f2d6c' = 'Iso';       '1dbf2edd-4729-0984-3115-daa5eed44993' = 'Clove'
    'efba5359-4016-a1e5-7626-b1ae76895940' = 'Vyse';      'b444168c-4e35-8076-db47-ef9bf368f384' = 'Tejo'
    'df1cb487-4902-002e-5c17-d28e83e78588' = 'Waylay'
}
$PLATFORM = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"platformType":"PC","platformOS":"Windows","platformOSVersion":"10.0.19042.1.256.64bit","platformChipset":"Unknown"}'))
$LOCKFILE = Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Config\lockfile'
$GAME_LOG = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Logs\ShooterGame.log'
$ST.logPath = if ($LogPath) { $LogPath } else { $GAME_LOG }

function Map-FromId([string]$mapId) {    # "/Game/Maps/Duality/Duality" -> "Bind"
    if (-not $mapId) { return $null }
    $internal = ($mapId -split '/')[-1]
    $name = $MAP_INTERNAL[$internal]
    if ($name) { return $name }
    # a map newer than the table: look its display name up once on the community API
    try {
        $resp = Invoke-RestMethod -Uri 'https://valorant-api.com/v1/maps' -TimeoutSec 5
        foreach ($mp in $resp.data) { if ($mp.mapUrl) { $MAP_INTERNAL[($mp.mapUrl -split '/')[-1]] = $mp.displayName } }
        $name = $MAP_INTERNAL[$internal]
    } catch {}
    if ($name) { $name } else { $internal }   # still unknown: show the internal name rather than nothing
}
function Agent-FromId([string]$uuid) {
    if (-not $uuid) { return $null }
    $name = $AGENT_IDS[$uuid.ToLower()]
    if ($name) { return $name }
    try {   # unknown id (new agent): look it up once on the community API and remember it
        $resp = Invoke-RestMethod -Uri 'https://valorant-api.com/v1/agents?isPlayableCharacter=true' -TimeoutSec 5
        foreach ($a in $resp.data) { $AGENT_IDS[$a.uuid.ToLower()] = $a.displayName }
        return $AGENT_IDS[$uuid.ToLower()]
    } catch { return $null }
}

# one-shot log read used by the test hook (the worker does the same thing continuously)
function Detect-ViaLog {
    if (-not (Test-Path $ST.logPath)) { return $null }
    $fs = [IO.File]::Open($ST.logPath, 'Open', 'Read', 'ReadWrite')
    try { $start = [Math]::Max(0, $fs.Length - 262144); $fs.Seek($start, 'Begin') | Out-Null; $buf = New-Object byte[] ($fs.Length - $start); $fs.Read($buf, 0, $buf.Length) | Out-Null; $tail = [Text.Encoding]::UTF8.GetString($buf) } finally { $fs.Dispose() }
    $hits = [regex]::Matches($tail, 'Map Name: (\w+) \| Changed: TRUE')
    if ($hits.Count -eq 0) { return $null }
    $MAP_INTERNAL[$hits[$hits.Count - 1].Groups[1].Value]
}

# --- the worker: polls the local API (and the log) every 3 s and drops the result in $sync ------
$workerScript = @'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls13'
$global:token = $null; $global:tokenAt = [DateTime]::MinValue; $global:info = $null
$global:logLen = -1; $global:lastMapLine = ''
function Read-Part([string]$path, [long]$start, [int]$bytes) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $n = [int][Math]::Min($bytes, $fs.Length - $start); if ($n -le 0) { return '' }
        $fs.Seek($start, 'Begin') | Out-Null; $buf = New-Object byte[] $n; $fs.Read($buf, 0, $n) | Out-Null
        [Text.Encoding]::UTF8.GetString($buf)
    } finally { $fs.Dispose() }
}
function Get-Info {   # region / shard / client version, from the URLs Valorant prints in its own log
    if ($global:info) { return $global:info }
    if (-not (Test-Path $gameLog)) { return $null }
    $head = Read-Part $gameLog 0 2000000
    $g = [regex]::Match($head, 'glz-([a-z]+)-1\.([a-z]+)\.a\.pvp\.net'); $v = [regex]::Match($head, 'CI server version: (\S+)')
    if ($g.Success -and $v.Success) { $global:info = @{ region = $g.Groups[1].Value; shard = $g.Groups[2].Value; version = $v.Groups[1].Value } }
    $global:info
}
function Get-Token {   # bearer + entitlement tokens from the local client; refreshed every 45 minutes
    if ($global:token -and ([DateTime]::UtcNow - $global:tokenAt).TotalMinutes -lt 45) { return $global:token }
    if (-not (Test-Path $lockfile)) { return $null }
    $lf = (Get-Content $lockfile -Raw) -split ':'
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("riot:$($lf[3])"))
    $t = Invoke-RestMethod -Uri "https://127.0.0.1:$($lf[2])/entitlements/v1/token" -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 4
    $global:token = @{ access = $t.accessToken; ent = $t.token; puuid = $t.subject }; $global:tokenAt = [DateTime]::UtcNow
    $global:token
}
function Riot-Get([string]$url) {   # $null on 404 (not in that phase), throws on anything else
    $tok = Get-Token; $inf = Get-Info
    if (-not $tok -or -not $inf) { return $null }
    $h = @{ Authorization = "Bearer $($tok.access)"; 'X-Riot-Entitlements-JWT' = $tok.ent; 'X-Riot-ClientVersion' = $inf.version; 'X-Riot-ClientPlatform' = $platform }
    try { Invoke-RestMethod -Uri $url -Headers $h -TimeoutSec 6 }
    catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($code -eq 404) { return $null }
        if ($code -eq 400 -or $code -eq 401) { $global:token = $null }
        throw
    }
}
function Poll {
    $r = @{ phase = ''; mapId = ''; charId = ''; locked = $false; logMap = ''; error = '' }
    # game not running at all: definitely not in a match (the Riot client alone answers 404, which would
    # otherwise look like an error and leave the last match's map and agent on screen)
    if (-not (Get-Process -Name 'VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue)) { $r.phase = 'menu'; return $r }
    try {
        $tok = Get-Token; $inf = Get-Info
        if ($tok -and $inf) {
            $glz = "https://glz-$($inf.region)-1.$($inf.shard).a.pvp.net"
            $pre = Riot-Get "$glz/pregame/v1/players/$($tok.puuid)"
            if ($pre -and $pre.MatchID) {
                $m = Riot-Get "$glz/pregame/v1/matches/$($pre.MatchID)"
                if ($m) {
                    $me = $m.AllyTeam.Players | Where-Object { $_.Subject -eq $tok.puuid } | Select-Object -First 1
                    $r.phase = 'agent select'; $r.mapId = [string]$m.MapID; $r.charId = [string]$me.CharacterID
                    $r.locked = ($me.CharacterSelectionState -eq 'locked')
                }
            }
            if (-not $r.phase) {
                $core = Riot-Get "$glz/core-game/v1/players/$($tok.puuid)"
                if ($core -and $core.MatchID) {
                    $m = Riot-Get "$glz/core-game/v1/matches/$($core.MatchID)"
                    if ($m) {
                        $me = $m.Players | Where-Object { $_.Subject -eq $tok.puuid } | Select-Object -First 1
                        $r.phase = 'match'; $r.mapId = [string]$m.MapID; $r.charId = [string]$me.CharacterID; $r.locked = $true
                    }
                }
            }
            if (-not $r.phase) { $r.phase = 'menu' }
        } elseif (Test-Path $lockfile) { $r.phase = 'menu' }
    } catch { $r.error = $_.Exception.Message }
    try {   # log fallback: newest map-load line, reported once per load
        if (Test-Path $mapLog) {
            $len = (Get-Item $mapLog).Length
            if ($len -ne $global:logLen) {
                $global:logLen = $len
                $tail = Read-Part $mapLog ([Math]::Max(0, $len - 262144)) 262144
                $hits = [regex]::Matches($tail, 'Map Name: (\w+) \| Changed: TRUE')
                if ($hits.Count) {
                    $last = $hits[$hits.Count - 1]
                    if ($last.Value -ne $global:lastMapLine) { $global:lastMapLine = $last.Value; $r.logMap = $last.Groups[1].Value }
                }
            }
        }
    } catch {}
    $r
}
while ($sync.running) {
    try { $sync.result = Poll; $sync.stamp = [DateTime]::UtcNow } catch { $sync.error = $_.Exception.Message }
    Start-Sleep -Milliseconds 3000
}
'@
$sync = [hashtable]::Synchronized(@{ running = $true; result = $null; stamp = $null; error = '' })
$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
foreach ($kv in @{ sync = $sync; lockfile = $LOCKFILE; gameLog = $GAME_LOG; mapLog = $ST.logPath; platform = $PLATFORM }.GetEnumerator()) {
    $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
}
$worker = [powershell]::Create(); $worker.Runspace = $rs; [void]$worker.AddScript($workerScript)
$ST.workerHandle = $worker.BeginInvoke()
$form.Add_FormClosed({ $sync.running = $false; try { $worker.Stop() } catch {}; try { $rs.Close() } catch {} })

# phase: 'menu' (not in a game), 'agent select', 'match'.
# Visibility (with autoShow on): hidden at startup and in the menus; it appears once the MAP is known
# (waiting in the bottom-right corner) and moves to its configured spot once the AGENT is known.
# Pressing the hide key keeps it hidden until the next game.
$ST.phase = ''; $ST.manualHide = $false
function Update-Visibility {
    if (-not $cfg.autoShow) { if (-not (Card-Shown)) { Show-Card }; return }
    $want = ($ST.sel.Map -ge 0) -and -not $ST.manualHide
    if ($want -and -not (Card-Shown)) { Place-OnMonitor; Show-Card }
    elseif (-not $want -and (Card-Shown)) { Hide-Card }
}
# the card (and its type blocks) fade in / out in 0.14 s instead of popping; ease-out
$CARD_OPACITY = 0.94
$ST.fadeTo = 0
$ST.fadeTimer = New-Object System.Windows.Forms.Timer; $ST.fadeTimer.Interval = 15
$ST.fadeTimer.Add_Tick({
    $fk = [Math]::Min(1, ((Get-Date) - $ST.fadeT0).TotalSeconds / 0.14)
    $fe = 1 - [Math]::Pow(1 - $fk, 3)
    $fo = $ST.fadeFrom + ($ST.fadeTo - $ST.fadeFrom) * $fe
    $form.Opacity = $fo; $tabForm.Opacity = $fo
    if ($fk -ge 1) { $ST.fadeTimer.Stop(); if ($ST.fadeTo -le 0) { $form.Hide() } }
})
function Start-Fade([double]$to) { $ST.fadeFrom = $form.Opacity; $ST.fadeTo = $to; $ST.fadeT0 = Get-Date; $ST.fadeTimer.Start() }
function Card-Shown { $form.Visible -and $ST.fadeTo -gt 0 }
function Show-Card { if (-not $form.Visible) { $form.Opacity = 0; $tabForm.Opacity = 0; $form.Show() }; Start-Fade $CARD_OPACITY }
function Hide-Card { if ($form.Visible) { Start-Fade 0 } }
function Set-Phase([string]$phase) {
    if ($phase -eq $ST.phase) { return }
    Write-DetectLog "phase -> $phase"
    $ST.phase = $phase
    if ($phase -eq 'menu') {   # match over: forget map and agent so the blocks are blank for the next one
        $ST.manualHide = $false
        $ST.det.map = ''; $ST.det.agent = ''
        $ST.sel.Map = -1; $ST.sel.Agent = -1; $ST.li = 0; $ST.si = 0
        Refresh-Lineups
    }
    Update-Visibility
}

# UI side: once a second, apply whatever the worker last found (only when it is new)
$ST.lastStamp = $null
function Detect-Game {
    if (-not $cfg.autoDetect) { return }
    $r = $sync.result; $stamp = $sync.stamp
    if (-not $r -or $stamp -eq $ST.lastStamp) { return }
    $ST.lastStamp = $stamp
    if ($r.error) { Write-DetectLog "worker: $($r.error)" }
    if ($r.phase) {
        Set-Phase $r.phase
        if ($r.phase -ne 'menu') {
            Write-DetectLog "$($r.phase) MapID='$($r.mapId)' CharacterID='$($r.charId)' locked=$($r.locked)"
            $agent = if ($r.locked -and $r.charId) { Agent-FromId $r.charId } else { $null }
            Apply-Detected (Map-FromId $r.mapId) $agent "api:$($r.phase)"
        }
    } elseif ($r.logMap) {
        $name = $MAP_INTERNAL[$r.logMap]
        if ($name) { Apply-Detected $name '' 'log' }
    }
}
# overlay.pid lets the Mollydex app see instantly whether the overlay is running
$pidFile = Join-Path $root 'overlay.pid'
if (-not $ScreenshotPath) {   # a test run must never take over the running overlay's pid file
    try { Set-Content $pidFile $PID -Encoding ASCII } catch {}
    $form.Add_FormClosed({ try { Remove-Item $pidFile -ErrorAction SilentlyContinue } catch {} })
}

$ST.detTimer = New-Object System.Windows.Forms.Timer
$ST.detTimer.Interval = 1000
$ST.detTimer.Add_Tick({ try { Detect-Game } catch { Write-Host "detect: $_" } })
$ST.detTimer.Start()

# --- live reload: when the editor saves data\lineups.json, pick it up without a restart ------------
$ST.dataStamp = (Get-Item (Join-Path $root 'data\lineups.json')).LastWriteTimeUtc
$ST.reloadTimer = New-Object System.Windows.Forms.Timer; $ST.reloadTimer.Interval = 1500
$ST.cfgStamp = if (Test-Path $configPath) { (Get-Item $configPath).LastWriteTimeUtc } else { [DateTime]::MinValue }
$ST.reloadTimer.Add_Tick({
    # the app's monitor picker writes config.json "monitor": move there without a restart
    try {
        if (Test-Path $configPath) {
            $cf = Get-Item $configPath
            if ($cf.LastWriteTimeUtc -ne $ST.cfgStamp) {
                $ST.cfgStamp = $cf.LastWriteTimeUtc
                Start-Sleep -Milliseconds 100
                $cj = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $cj.monitor -and [int]$cj.monitor -ne $cfg.monitor) { $cfg.monitor = [int]$cj.monitor; Place-OnMonitor; Write-DetectLog "monitor -> $($cfg.monitor) (from the app)" }
            }
        }
    } catch { Write-Host "config reload: $_" }
    try {
        $f = Get-Item (Join-Path $root 'data\lineups.json')
        if ($f.LastWriteTimeUtc -eq $ST.dataStamp) { return }
        $ST.dataStamp = $f.LastWriteTimeUtc
        Start-Sleep -Milliseconds 150   # let the editor finish writing
        $fresh = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:data = $fresh
        foreach ($m in @($fresh.maps)) { if ($MAPS.IndexOf([string]$m) -lt 0) { [void]$MAPS.Add([string]$m) } }
        foreach ($a in @($fresh.agents)) { if (-not ($AGENTS | Where-Object { $_.name -eq $a.name })) { [void]$AGENTS.Add($a) } }
        $ST.icons.Clear()   # icons / backdrops may have changed
        Refresh-Lineups
        Write-DetectLog 'lineups.json reloaded'
    } catch { Write-Host "reload: $_" }
})
$ST.reloadTimer.Start()

# --- global hotkeys -------------------------------------------------------------------------
$hotkeyActions = @(
    @{ name = 'prevLineup';  run = { Move-Lineup -1 } },
    @{ name = 'nextLineup';  run = { Move-Lineup 1 } },
    @{ name = 'prevStep';    run = { Move-Step -1 } },
    @{ name = 'nextStep';    run = { Move-Step 1 } },
    @{ name = 'nextOption';  run = { Next-Option } },
    @{ name = 'nextType';    run = { Next-Type } },
    @{ name = 'nextAgent';   run = { Cycle-Agent 1 } },
    @{ name = 'nextMap';     run = { Cycle-Map 1 } },
    @{ name = 'toggle';      run = { if (Card-Shown) { Hide-Card; $ST.manualHide = $true } else { Show-Card; $ST.manualHide = $false } } },
    @{ name = 'nextMonitor'; run = { Next-Monitor } },
    @{ name = 'nudgeLeft';   run = { Nudge -10 0 } },
    @{ name = 'nudgeRight';  run = { Nudge 10 0 } },
    @{ name = 'nudgeUp';     run = { Nudge 0 -10 } },
    @{ name = 'nudgeDown';   run = { Nudge 0 10 } },
    @{ name = 'quit';        run = { $form.Close(); [System.Windows.Forms.Application]::ExitThread() } }   # also ends the loop if the panel was never shown
)
$hook = $null
$form.Add_HandleCreated({
    # keys are only taken while Valorant is the foreground window (config "onlyInGame"); quit is global.
    # Bare keys are "loose": they also fire with Shift / Ctrl held, so they work while walking or crouching.
    if ($ScreenshotPath) { return }   # test runs take no keys (safe to run while the real overlay is in a match)
    $script:hook = New-Object KeyboardHook $form
    $hook.OnlyInGame = [bool]$cfg.onlyInGame
    $hook.add_Pressed([Action[int]]{
        param($id)
        if ($id -ge 1 -and $id -le $hotkeyActions.Count) { & $hotkeyActions[$id - 1].run }
    })
    for ($i = 0; $i -lt $hotkeyActions.Count; $i++) {
        $name = $hotkeyActions[$i].name
        $spec = $cfg.hotkeys[$name]
        if (-not $spec) { continue }
        try {
            $k = Parse-Hotkey $spec
            $hook.Add($i + 1, [int]$k.mods, [int]$k.vk, ($k.mods -eq 0), ($name -eq 'quit'), ($name -ne 'toggle'))
        } catch { Write-Warning "Skipping hotkey for ${name}: $_" }
    }
})
$form.Add_FormClosed({ if ($hook) { $hook.Dispose() }; Set-Image $null })

# --- test hook: render, snapshot, exit ------------------------------------------------------
if ($ScreenshotPath) {
    $cfg.autoDetect = $false   # the live game state must not overwrite the test selection
    $form.Add_Shown({
        $ST.sel = @{ Map = 0; Agent = 1 }   # Ascent / Sova
        Refresh-Lineups
        if ($LogPath) { $mapName = Detect-ViaLog; if ($mapName) { Apply-Detected $mapName $(if ($env:LINEUP_TEST_AGENT) { $env:LINEUP_TEST_AGENT } else { 'Sova' }) 'log' } }
        Move-Step $(if ($env:LINEUP_TEST_STEP) { [int]$env:LINEUP_TEST_STEP } else { 2 })
        # LINEUP_TEST_KEYS="nextLineup,nextType,toggle": run those hotkey actions, to exercise fades / glides
        foreach ($tn in @(([string]$env:LINEUP_TEST_KEYS) -split ',' | Where-Object { $_ })) {
            $act = $hotkeyActions | Where-Object { $_.name -eq $tn.Trim() } | Select-Object -First 1
            if ($act) { try { & $act.run; Write-Host "test key $tn ok" } catch { Write-Host "TEST KEY ERROR ${tn}: $_" } }
        }
        $ST.timer = New-Object System.Windows.Forms.Timer; $ST.timer.Interval = $(if ($env:LINEUP_TEST_DELAY) { [int]$env:LINEUP_TEST_DELAY } else { 700 })
        $ST.timer.Add_Tick({
            $ST.timer.Stop()
            try {
                # the card, and the type blocks under it when they are showing, on the dark grey of a game frame
                $tbH = if ($tabForm.Visible) { $tabForm.Height + 6 } else { 0 }
                $bmp = New-Object System.Drawing.Bitmap ([Math]::Max($form.Width, $tabForm.Width)), ($form.Height + $tbH)
                $sg = [System.Drawing.Graphics]::FromImage($bmp); $sg.Clear((C '#2b2f36'))
                $cardBmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
                $form.DrawToBitmap($cardBmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
                $sg.SetClip($form.Region, [System.Drawing.Drawing2D.CombineMode]::Replace); $sg.DrawImage($cardBmp, 0, 0); $sg.ResetClip()
                if ($tbH) {
                    $tbBmp = New-Object System.Drawing.Bitmap $tabForm.Width, $tabForm.Height
                    $tabForm.DrawToBitmap($tbBmp, (New-Object System.Drawing.Rectangle 0, 0, $tabForm.Width, $tabForm.Height))
                    $tbX = $bmp.Width - $tabForm.Width
                    $clip = $tabForm.Region.Clone(); $clip.Translate($tbX, $form.Height + 6)
                    $sg.SetClip($clip, [System.Drawing.Drawing2D.CombineMode]::Replace); $sg.DrawImage($tbBmp, $tbX, $form.Height + 6); $sg.ResetClip()
                }
                $sg.Dispose()
                $bmp.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
                $fc = if ($ST.image) { $ST.image.GetFrameCount((New-Object System.Drawing.Imaging.FrameDimension ($ST.image.FrameDimensionsList[0]))) } else { 0 }
                $x = $sync.result
                $api = if ($x) { "$($x.phase) $($x.mapId)/$($x.charId) locked=$($x.locked) err='$($x.error)'" } else { 'worker has not reported yet' }
                Write-Host "screenshot saved; map=$(Current-Map); agent=$((Current-Agent).name); lineups=$($ST.all.Count); step=$($ST.si + 1) picture=$($ST.sub + 1) cycling=$($ST.subTimer.Enabled); frames=$fc; size=$($form.Width)x$($form.Height); api=$api"
            } catch { Write-Host "TEST ERROR: $_" }
            $form.Close()
        })
        $ST.timer.Start()
    })
}

# surface handler exceptions on the console instead of a blocking dialog
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Host "UI ERROR: $($e.Exception.Message)" })

Refresh-Lineups
if ($ScreenshotPath) { [System.Windows.Forms.Application]::Run($form) }
else {
    # start HIDDEN: create the window (and its keyboard hook) without showing it, and run the message loop
    # on its own; detection shows the panel once the map is known
    $null = $form.Handle
    $form.Add_FormClosed({ [System.Windows.Forms.Application]::ExitThread() })
    Update-Visibility   # with autoShow off it shows straight away, as before
    [System.Windows.Forms.Application]::Run()
    if ($hook) { $hook.Dispose() }
    Remove-Item (Join-Path $root 'overlay.pid') -ErrorAction SilentlyContinue
}
