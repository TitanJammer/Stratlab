# Generates placeholder media for every step in data\lineups.json that has no file yet.
#   .png steps -> a still frame labelled WHERE TO STAND / WHERE TO AIM
#   .gif steps -> a real animated GIF (a dot flying along an arc) so playback can be verified
# Run:  powershell -ExecutionPolicy Bypass -File tools\make_placeholders.ps1
# Delete a placeholder and re-run to regenerate it; real captures are never overwritten.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$data = Get-Content (Join-Path $root 'data\lineups.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Minimal GIF89a writer (uncompressed-style LZW, 256-colour global palette, looping).
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Drawing;

public static class SimpleGif
{
    public static void Save(string path, Bitmap[] frames, int delayCentiseconds)
    {
        int w = frames[0].Width, h = frames[0].Height;
        var palette = new List<int>();
        var index = new Dictionary<int, int>();
        var indexed = new List<byte[]>();

        foreach (var f in frames)
        {
            var d = new byte[w * h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int c = f.GetPixel(x, y).ToArgb() & 0xFFFFFF;
                    int i;
                    if (!index.TryGetValue(c, out i))
                    {
                        if (palette.Count < 256) { i = palette.Count; palette.Add(c); }
                        else i = Nearest(palette, c);
                        index[c] = i;
                    }
                    d[y * w + x] = (byte)i;
                }
            indexed.Add(d);
        }

        using (var s = new BinaryWriter(File.Create(path)))
        {
            s.Write(System.Text.Encoding.ASCII.GetBytes("GIF89a"));
            s.Write((ushort)w); s.Write((ushort)h);
            s.Write((byte)0xF7); s.Write((byte)0); s.Write((byte)0);           // global table, 256 entries
            for (int i = 0; i < 256; i++)
            {
                int c = i < palette.Count ? palette[i] : 0;
                s.Write((byte)(c >> 16)); s.Write((byte)(c >> 8)); s.Write((byte)c);
            }
            // NETSCAPE2.0 loop-forever extension
            s.Write((byte)0x21); s.Write((byte)0xFF); s.Write((byte)11);
            s.Write(System.Text.Encoding.ASCII.GetBytes("NETSCAPE2.0"));
            s.Write((byte)3); s.Write((byte)1); s.Write((ushort)0); s.Write((byte)0);

            foreach (var d in indexed)
            {
                s.Write((byte)0x21); s.Write((byte)0xF9); s.Write((byte)4);     // graphic control ext
                s.Write((byte)0); s.Write((ushort)delayCentiseconds); s.Write((byte)0); s.Write((byte)0);
                s.Write((byte)0x2C); s.Write((ushort)0); s.Write((ushort)0);     // image descriptor
                s.Write((ushort)w); s.Write((ushort)h); s.Write((byte)0);
                s.Write((byte)8);                                                // LZW min code size
                var bytes = Lzw(d);
                int p = 0;
                while (p < bytes.Length)
                {
                    int n = Math.Min(255, bytes.Length - p);
                    s.Write((byte)n); s.Write(bytes, p, n); p += n;
                }
                s.Write((byte)0);
            }
            s.Write((byte)0x3B);
        }
    }

    static int Nearest(List<int> pal, int c)
    {
        int best = 0, bd = int.MaxValue;
        int r = c >> 16 & 255, g = c >> 8 & 255, b = c & 255;
        for (int i = 0; i < pal.Count; i++)
        {
            int pr = pal[i] >> 16 & 255, pg = pal[i] >> 8 & 255, pb = pal[i] & 255;
            int dd = (pr - r) * (pr - r) + (pg - g) * (pg - g) + (pb - b) * (pb - b);
            if (dd < bd) { bd = dd; best = i; }
        }
        return best;
    }

    // Emits every pixel as a literal 9-bit code, resetting the table before it could grow to 10 bits.
    static byte[] Lzw(byte[] pixels)
    {
        var o = new MemoryStream();
        int acc = 0, bits = 0;
        Action<int> put = code =>
        {
            acc |= code << bits; bits += 9;
            while (bits >= 8) { o.WriteByte((byte)(acc & 255)); acc >>= 8; bits -= 8; }
        };
        put(256);
        int since = 0;
        foreach (var px in pixels)
        {
            put(px);
            if (++since == 250) { put(256); since = 0; }
        }
        put(257);
        if (bits > 0) o.WriteByte((byte)(acc & 255));
        return o.ToArray();
    }
}
'@

$W = 480; $H = 270
$titleById = @{}
foreach ($l in $data.lineups) { $titleById[$l.id] = $l.title }

function New-Frame([string]$label, [string]$title, [string]$caption, [double]$t, [bool]$animated) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'None'
    $g.TextRenderingHint = 'SingleBitPerPixelGridFit'   # keeps the colour count tiny for the GIF palette
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#131a24'))
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#0d1117'))), 0, 190, $W, 80)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#2a3446'))), 60, 130, 90, 60)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#232c3b'))), 320, 100, 110, 90)

    $red = [System.Drawing.ColorTranslator]::FromHtml('#ff4655')
    $pen = New-Object System.Drawing.Pen $red, 2
    if ($animated) {
        $g.DrawArc((New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#3a4557')), 1), 100, 40, 280, 300, 180, 180)
        $x = 100 + 280 * $t
        $y = 190 - 150 * [math]::Sin($t * [math]::PI)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $red), $x - 6, $y - 6, 12, 12)
        if ($t -gt 0.95) { $g.DrawEllipse($pen, 380 - 20, 190 - 20, 40, 40) }
    } else {
        $g.DrawLine($pen, 240, 120, 240, 150); $g.DrawLine($pen, 225, 135, 255, 135)
        $g.DrawEllipse($pen, 226, 121, 28, 28)
    }

    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#ece8e1'))
    $grey  = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#9aa5b5'))
    $g.DrawString($label,   (New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Bold)), $white, (New-Object System.Drawing.RectangleF 0, 18, $W, 30), $fmt)
    $g.DrawString($title,   (New-Object System.Drawing.Font 'Segoe UI', 10), $grey,  (New-Object System.Drawing.RectangleF 0, 50, $W, 24), $fmt)
    $g.DrawString($caption, (New-Object System.Drawing.Font 'Segoe UI', 10), $white, (New-Object System.Drawing.RectangleF 10, 220, ($W - 20), 40), $fmt)
    $tag = if ($animated) { 'placeholder GIF' } else { 'placeholder PNG' }
    $g.DrawString($tag, (New-Object System.Drawing.Font 'Segoe UI', 8), $grey, $W - 100, $H - 16)
    $g.Dispose()
    return $bmp
}

$made = 0
foreach ($l in $data.lineups) {
    foreach ($s in $l.steps) {
        $path = Join-Path $root ($s.src -replace '/', '\')
        if (Test-Path $path) { continue }
        $kind = [IO.Path]::GetFileNameWithoutExtension($path).Split('-')[-1]
        $label = switch ($kind) { 'stand' { 'WHERE TO STAND' } 'aim' { 'WHERE TO AIM' } 'exec' { 'EXECUTION' } default { 'STEP' } }
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null

        if ($s.type -eq 'gif') {
            $frames = @()
            for ($i = 0; $i -lt 24; $i++) { $frames += New-Frame $label $l.title $s.caption ($i / 23) $true }
            [SimpleGif]::Save($path, [System.Drawing.Bitmap[]]$frames, 8)
            $frames | ForEach-Object { $_.Dispose() }
        } else {
            $bmp = New-Frame $label $l.title $s.caption 0 $false
            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        $made++
        Write-Host "wrote $($s.src)"
    }
}
# --- icons: agents (rounded square, initials) and abilities (circle, initials) ---------------
function New-Icon([string]$text, [int]$size, [bool]$circle, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $fill = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#3c3c3c'))
    if ($circle) {
        $g.FillEllipse($fill, 0, 0, $size - 1, $size - 1)
    } else {
        $r = [int]($size / 5); $d = 2 * $r
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($size - $d - 1, 0, $d, $d, 270, 90)
        $p.AddArc($size - $d - 1, $size - $d - 1, $d, $d, 0, 90); $p.AddArc(0, $size - $d - 1, $d, $d, 90, 90); $p.CloseFigure()
        $g.FillPath($fill, $p)
    }
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $font = New-Object System.Drawing.Font 'Segoe UI', ([int]($size * 0.34)), ([System.Drawing.FontStyle]::Bold)
    $g.DrawString($text, $font, (New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#eaeaea'))), (New-Object System.Drawing.RectangleF 0, 0, $size, $size), $fmt)
    $g.Dispose()
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Initials([string]$name) { (($name -split '[\s-]+' | ForEach-Object { $_.Substring(0, 1) }) -join '').ToUpper() }

foreach ($a in $data.agents) {
    $path = Join-Path $root ($a.icon -replace '/', '\')
    if (Test-Path $path) { continue }
    New-Icon ($a.name.Substring(0, 2).ToUpper()) 64 $false $path
    $made++; Write-Host "wrote $($a.icon)"
}
foreach ($p in $data.abilities.PSObject.Properties) {
    $path = Join-Path $root ($p.Value -replace '/', '\')
    if (Test-Path $path) { continue }
    New-Icon (Initials $p.Name) 40 $true $path
    $made++; Write-Host "wrote $($p.Value)"
}

# --- map pictures: assets/maps/<map>.png, shown darkened behind the MAP block -----------------
function New-MapPlaceholder([string]$mapName, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap 240, 120
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
    $seed = 0; foreach ($ch in $mapName.ToCharArray()) { $seed = ($seed * 31 + [int]$ch) % 360 }   # a hue per map
    $rnd = New-Object System.Random $seed
    $c1 = [System.Drawing.Color]::FromArgb(255, (40 + $rnd.Next(60)), (60 + $rnd.Next(80)), (80 + $rnd.Next(100)))
    $c2 = [System.Drawing.Color]::FromArgb(255, (20 + $rnd.Next(40)), (30 + $rnd.Next(40)), (40 + $rnd.Next(60)))
    $g.FillRectangle((New-Object System.Drawing.Drawing2D.LinearGradientBrush ((New-Object System.Drawing.Point 0, 0), (New-Object System.Drawing.Point 240, 120), $c1, $c2)), 0, 0, 240, 120)
    $blockBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
    for ($k = 0; $k -lt 9; $k++) { $g.FillRectangle($blockBrush, $rnd.Next(200), $rnd.Next(100), (10 + $rnd.Next(50)), (8 + $rnd.Next(30))) }   # "buildings"
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($mapName.Substring(0, 1).ToUpper(), (New-Object System.Drawing.Font 'Segoe UI', 56, ([System.Drawing.FontStyle]::Bold)), (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, 255, 255, 255))), (New-Object System.Drawing.RectangleF 0, 0, 240, 120), $fmt)
    $g.Dispose()
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
foreach ($m in $data.maps) {
    $rel = "assets/maps/$($m.ToLower() -replace '[^a-z0-9]', '').png"
    $path = Join-Path $root ($rel -replace '/', '\')
    if (Test-Path $path) { continue }
    New-MapPlaceholder $m $path
    $made++; Write-Host "wrote $rel"
}

Write-Host "done: $made placeholder file(s) created"
