# ---------------------------------------------------------------------------
# make_icons.ps1  --  regenerate all Android launcher icons from the server logo
#
# Pure .NET BCL implementation (no Add-Type / no COM / no external tools):
#   PNG decode (colorType 2, bitDepth 8) -> box downsample -> compose -> PNG encode
#
# Run with:  $sb = [scriptblock]::Create((Get-Content -Raw -Encoding UTF8 $PSScriptRoot\make_icons.ps1)); . $sb
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$SrcPng = 'C:\Users\Administrator\WorkBuddy\spaces\2026_11_20_10-53-45\印刷管理系统\public\logo.png'
$ResDir = 'C:\Users\Administrator\WorkBuddy\spaces\2026_11_20_10-53-45\PrintClientAndroid\app\src\main\res'

# ---------------------------------------------------------------- base helpers
function Get-Be32 {
    param([byte[]]$b, [int]$o)
    return ([int]$b[$o] -shl 24) -bor ([int]$b[$o + 1] -shl 16) -bor ([int]$b[$o + 2] -shl 8) -bor [int]$b[$o + 3]
}

function Put-Be32 {
    param([byte[]]$b, [int]$o, [int64]$v)
    $b[$o]     = [byte](($v -shr 24) -band 0xFF)
    $b[$o + 1] = [byte](($v -shr 16) -band 0xFF)
    $b[$o + 2] = [byte](($v -shr 8) -band 0xFF)
    $b[$o + 3] = [byte]($v -band 0xFF)
}

# CRC32：直接用逐位算法（反射，多项式 0xEDB88320）。
# 之前用查找表的写法在 PowerShell 5.1 下是错的：
#   1) 0xEDB88320 / 0xFFFFFFFF 这类 >Int32 的十六进制字面量会被解析成【负的 Int32】；
#   2) [long] 的 -shr 是算术右移，不截断会带出符号位。
# 结果就是每个 chunk 的 CRC 都写错 → Android 的 libpng 解码失败 →
# 桌面启动器退回系统默认图标（绿底机器人）。别再用表，就用逐位，慢一点但不会错。
# 多项式与初值都用十进制字面量，避免字面量类型坑。
function Get-Crc32 {
    param([byte[]]$data, [int]$off, [int]$len)
    [int64]$crc = 4294967295          # 0xFFFFFFFF
    $end = $off + $len
    for ($i = $off; $i -lt $end; $i++) {
        $crc = $crc -bxor [int64]$data[$i]
        for ($k = 0; $k -lt 8; $k++) {
            if (($crc -band 1) -ne 0) {
                $crc = (($crc -shr 1) -bxor 3988292384) -band 4294967295   # 0xEDB88320
            } else {
                $crc = ($crc -shr 1) -band 4294967295
            }
        }
    }
    return [int64](($crc -bxor 4294967295) -band 4294967295)
}

function Get-Adler32 {
    param([byte[]]$data, [int]$len)
    [uint64]$a = 1
    [uint64]$b = 0
    $i = 0
    while ($i -lt $len) {
        $chunk = [Math]::Min(5552, $len - $i)
        $stop = $i + $chunk
        while ($i -lt $stop) {
            $a += $data[$i]
            $b += $a
            $i++
        }
        $a = $a % 65521
        $b = $b % 65521
    }
    return [uint32](($b -shl 16) -bor $a)
}

# ------------------------------------------------------------------ png decode
function Read-PngRgb {
    param([string]$path)

    $bytes = [IO.File]::ReadAllBytes($path)
    $w = Get-Be32 $bytes 16
    $h = Get-Be32 $bytes 20
    $depth = $bytes[24]
    $ctype = $bytes[25]
    $inter = $bytes[28]
    if ($bytes[0] -ne 137 -or $bytes[1] -ne 80) { throw 'not a png' }
    if ($depth -ne 8 -or $ctype -ne 2 -or $inter -ne 0) {
        throw "unsupported png (depth=$depth colorType=$ctype interlace=$inter)"
    }

    $idat = New-Object System.IO.MemoryStream
    $p = 8
    while ($p -lt $bytes.Length) {
        $len = Get-Be32 $bytes $p
        $type = [Text.Encoding]::ASCII.GetString($bytes, $p + 4, 4)
        if ($type -eq 'IDAT') { $idat.Write($bytes, $p + 8, $len) }
        $p += 12 + $len
    }

    $inMs = New-Object System.IO.MemoryStream
    $z = $idat.ToArray()
    $inMs.Write($z, 2, $z.Length - 2)   # skip 2-byte zlib header
    $inMs.Position = 0

    $ds = New-Object System.IO.Compression.DeflateStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
    $outMs = New-Object System.IO.MemoryStream
    $buf = New-Object 'byte[]' 131072
    while (($n = $ds.Read($buf, 0, $buf.Length)) -gt 0) { $outMs.Write($buf, 0, $n) }
    $ds.Dispose(); $inMs.Dispose(); $idat.Dispose()

    $raw = $outMs.ToArray()
    $stride = $w * 3
    if ($raw.Length -lt $h * ($stride + 1)) { throw "inflate short: $($raw.Length) < $($h * ($stride + 1))" }

    # unfilter
    $px = New-Object 'byte[]' ($stride * $h)
    $bpp = 3
    $rowLen = $stride + 1
    for ($y = 0; $y -lt $h; $y++) {
        $ro = $y * $rowLen
        $ft = $raw[$ro]
        $si = $ro + 1
        $di = $y * $stride
        $pi = $di - $stride

        if ($ft -eq 0) {
            [Array]::Copy($raw, $si, $px, $di, $stride)
        }
        elseif ($ft -eq 1) {
            for ($i = 0; $i -lt $bpp; $i++) { $px[$di + $i] = $raw[$si + $i] }
            for ($i = $bpp; $i -lt $stride; $i++) {
                $px[$di + $i] = [byte](([int]$raw[$si + $i] + [int]$px[$di + $i - $bpp]) -band 0xFF)
            }
        }
        elseif ($ft -eq 2) {
            if ($y -eq 0) {
                [Array]::Copy($raw, $si, $px, $di, $stride)
            } else {
                for ($i = 0; $i -lt $stride; $i++) {
                    $px[$di + $i] = [byte](([int]$raw[$si + $i] + [int]$px[$pi + $i]) -band 0xFF)
                }
            }
        }
        elseif ($ft -eq 3) {
            for ($i = 0; $i -lt $bpp; $i++) {
                $up = if ($y -eq 0) { 0 } else { [int]$px[$pi + $i] }
                $px[$di + $i] = [byte](([int]$raw[$si + $i] + [int]($up / 2)) -band 0xFF)
            }
            for ($i = $bpp; $i -lt $stride; $i++) {
                $up = if ($y -eq 0) { 0 } else { [int]$px[$pi + $i] }
                $avg = [int](([int]$px[$di + $i - $bpp] + $up) / 2)
                $px[$di + $i] = [byte](([int]$raw[$si + $i] + $avg) -band 0xFF)
            }
        }
        else {
            for ($i = 0; $i -lt $stride; $i++) {
                $a = if ($i -ge $bpp) { [int]$px[$di + $i - $bpp] } else { 0 }
                $up = if ($y -eq 0) { 0 } else { [int]$px[$pi + $i] }
                $ul = if ($y -eq 0 -or $i -lt $bpp) { 0 } else { [int]$px[$pi + $i - $bpp] }
                $pp = $a + $up - $ul
                $pa = [Math]::Abs($pp - $a)
                $pb = [Math]::Abs($pp - $up)
                $pc = [Math]::Abs($pp - $ul)
                if ($pa -le $pb -and $pa -le $pc) { $pr = $a }
                elseif ($pb -le $pc) { $pr = $up }
                else { $pr = $ul }
                $px[$di + $i] = [byte](([int]$raw[$si + $i] + $pr) -band 0xFF)
            }
        }
    }

    return [pscustomobject]@{ W = $w; H = $h; Pixels = $px }
}

# ---------------------------------------------------------------- box resample
function Resize-Box {
    param([byte[]]$src, [int]$sw, [int]$sh, [int]$tw, [int]$th)

    $dst = New-Object 'byte[]' ($tw * $th * 3)
    $xs = New-Object 'int[]' $tw
    $xe = New-Object 'int[]' $tw
    $ys = New-Object 'int[]' $th
    $ye = New-Object 'int[]' $th

    for ($x = 0; $x -lt $tw; $x++) {
        $xs[$x] = [int][Math]::Floor($x * $sw / $tw)
        $xe[$x] = [int][Math]::Floor(($x + 1) * $sw / $tw)
        if ($xe[$x] -le $xs[$x]) { $xe[$x] = $xs[$x] + 1 }
        if ($xe[$x] -gt $sw) { $xe[$x] = $sw }
    }
    for ($y = 0; $y -lt $th; $y++) {
        $ys[$y] = [int][Math]::Floor($y * $sh / $th)
        $ye[$y] = [int][Math]::Floor(($y + 1) * $sh / $th)
        if ($ye[$y] -le $ys[$y]) { $ye[$y] = $ys[$y] + 1 }
        if ($ye[$y] -gt $sh) { $ye[$y] = $sh }
    }

    $rowBytes = $sw * 3
    for ($y = 0; $y -lt $th; $y++) {
        $y0 = $ys[$y]; $y1 = $ye[$y]
        $dy = $y * $th
        for ($x = 0; $x -lt $tw; $x++) {
            $x0 = $xs[$x]; $x1 = $xe[$x]
            $r = 0; $g = 0; $b = 0; $n = 0
            for ($yy = $y0; $yy -lt $y1; $yy++) {
                $base = $yy * $rowBytes + $x0 * 3
                for ($xx = $x0; $xx -lt $x1; $xx++) {
                    $r += $src[$base]; $g += $src[$base + 1]; $b += $src[$base + 2]
                    $base += 3
                    $n++
                }
            }
            $di = ($dy + $x) * 3
            $half = $n / 2.0
            $dst[$di]     = [byte][Math]::Min(255, [Math]::Floor(($r + $half) / $n))
            $dst[$di + 1] = [byte][Math]::Min(255, [Math]::Floor(($g + $half) / $n))
            $dst[$di + 2] = [byte][Math]::Min(255, [Math]::Floor(($b + $half) / $n))
        }
    }
    return $dst
}

# ------------------------------------------------------------------- compose
# mode 'square' : opaque rounded-nothing square, white padding around the badge
# mode 'circle' : transparent outside the inscribed circle (launcher / in-app use)
function Compose-Icon {
    param([byte[]]$rgb, [int]$L, [int]$N, [string]$mode, [int]$bg = 255)

    $off = [int][Math]::Floor(($N - $L) / 2)
    $out = New-Object 'byte[]' ($N * $N * 4)
    $c = ($N - 1) / 2.0
    $rOut = ($N / 2.0) - 0.5

    for ($y = 0; $y -lt $N; $y++) {
        $inY = ($y -ge $off) -and ($y -lt $off + $L)
        $sy = $y - $off
        for ($x = 0; $x -lt $N; $x++) {
            $di = ($y * $N + $x) * 4
            $inX = ($x -ge $off) -and ($x -lt $off + $L)

            if ($inX -and $inY) {
                $si = ($sy * $L + ($x - $off)) * 3
                $out[$di]     = $rgb[$si]
                $out[$di + 1] = $rgb[$si + 1]
                $out[$di + 2] = $rgb[$si + 2]
            } else {
                $out[$di]     = [byte]$bg
                $out[$di + 1] = [byte]$bg
                $out[$di + 2] = [byte]$bg
            }

            if ($mode -eq 'circle') {
                $dx = $x - $c
                $dy = $y - $c
                $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
                $cov = $rOut - $d + 0.5
                if ($cov -le 0) { $out[$di + 3] = 0 }
                elseif ($cov -ge 1) { $out[$di + 3] = 255 }
                else { $out[$di + 3] = [byte][int]($cov * 255) }
            } else {
                $out[$di + 3] = 255
            }
        }
    }
    return $out
}

# ----------------------------------------------------------------- png encode
function Write-PngRgba {
    param([string]$path, [byte[]]$rgba, [int]$w, [int]$h)

    $stride = $w * 4
    $rowLen = $stride + 1
    $raw = New-Object 'byte[]' ($rowLen * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $raw[$y * $rowLen] = 0
        [Array]::Copy($rgba, $y * $stride, $raw, $y * $rowLen + 1, $stride)
    }

    $z = New-Object System.IO.MemoryStream
    $z.WriteByte(0x78); $z.WriteByte(0x9C)
    $dz = New-Object System.IO.Compression.DeflateStream($z, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $dz.Write($raw, 0, $raw.Length)
    $dz.Dispose()
    $ad = Get-Adler32 $raw $raw.Length
    $z.WriteByte([byte](($ad -shr 24) -band 0xFF))
    $z.WriteByte([byte](($ad -shr 16) -band 0xFF))
    $z.WriteByte([byte](($ad -shr 8) -band 0xFF))
    $z.WriteByte([byte]($ad -band 0xFF))
    $zdata = $z.ToArray()
    $z.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $sig = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    $ms.Write($sig, 0, 8)

    $ihdr = New-Object 'byte[]' 25
    Put-Be32 $ihdr 0 13
    [Text.Encoding]::ASCII.GetBytes('IHDR').CopyTo($ihdr, 4)
    Put-Be32 $ihdr 8 ([uint32]$w)
    Put-Be32 $ihdr 12 ([uint32]$h)
    $ihdr[16] = 8; $ihdr[17] = 6; $ihdr[18] = 0; $ihdr[19] = 0; $ihdr[20] = 0
    Put-Be32 $ihdr 21 (Get-Crc32 $ihdr 4 17)
    $ms.Write($ihdr, 0, 25)

    $ch = New-Object 'byte[]' ($zdata.Length + 12)
    Put-Be32 $ch 0 ([uint32]$zdata.Length)
    [Text.Encoding]::ASCII.GetBytes('IDAT').CopyTo($ch, 4)
    [Array]::Copy($zdata, 0, $ch, 8, $zdata.Length)
    Put-Be32 $ch ($zdata.Length + 8) (Get-Crc32 $ch 4 ($zdata.Length + 4))
    $ms.Write($ch, 0, $ch.Length)

    $iend = New-Object 'byte[]' 12
    Put-Be32 $iend 0 0
    [Text.Encoding]::ASCII.GetBytes('IEND').CopyTo($iend, 4)
    Put-Be32 $iend 8 (Get-Crc32 $iend 4 4)
    $ms.Write($iend, 0, 12)

    [IO.File]::WriteAllBytes($path, $ms.ToArray())
    $ms.Dispose()
}

# --------------------------------------------------------------------- driver
$sw = [Diagnostics.Stopwatch]::StartNew()

Write-Output 'decoding source logo ...'
$img = Read-PngRgb $SrcPng
Write-Output ("  source {0}x{1}  ({2:n1}s)" -f $img.W, $img.H, $sw.Elapsed.TotalSeconds)

Write-Output 'building 512px master ...'
$mid = Resize-Box $img.Pixels $img.W $img.H 512 512
Write-Output ("  done ({0:n1}s)" -f $sw.Elapsed.TotalSeconds)

$jobs = @(
    @{ Dir = 'mipmap-mdpi';    Name = 'ic_launcher';            Size = 48;  Ratio = 0.92; Mode = 'square' }
    @{ Dir = 'mipmap-hdpi';    Name = 'ic_launcher';            Size = 72;  Ratio = 0.92; Mode = 'square' }
    @{ Dir = 'mipmap-xhdpi';   Name = 'ic_launcher';            Size = 96;  Ratio = 0.92; Mode = 'square' }
    @{ Dir = 'mipmap-xxhdpi';  Name = 'ic_launcher';            Size = 144; Ratio = 0.92; Mode = 'square' }
    @{ Dir = 'mipmap-xxxhdpi'; Name = 'ic_launcher';            Size = 192; Ratio = 0.92; Mode = 'square' }
    @{ Dir = 'mipmap-mdpi';    Name = 'ic_launcher_round';      Size = 48;  Ratio = 0.92; Mode = 'circle' }
    @{ Dir = 'mipmap-hdpi';    Name = 'ic_launcher_round';      Size = 72;  Ratio = 0.92; Mode = 'circle' }
    @{ Dir = 'mipmap-xhdpi';   Name = 'ic_launcher_round';      Size = 96;  Ratio = 0.92; Mode = 'circle' }
    @{ Dir = 'mipmap-xxhdpi';  Name = 'ic_launcher_round';      Size = 144; Ratio = 0.92; Mode = 'circle' }
    @{ Dir = 'mipmap-xxxhdpi'; Name = 'ic_launcher_round';      Size = 192; Ratio = 0.92; Mode = 'circle' }
    @{ Dir = 'mipmap-mdpi';    Name = 'ic_launcher_foreground'; Size = 108; Ratio = 0.66; Mode = 'circle' }
    @{ Dir = 'mipmap-hdpi';    Name = 'ic_launcher_foreground'; Size = 162; Ratio = 0.66; Mode = 'circle' }
    @{ Dir = 'mipmap-xhdpi';   Name = 'ic_launcher_foreground'; Size = 216; Ratio = 0.66; Mode = 'circle' }
    @{ Dir = 'mipmap-xxhdpi';  Name = 'ic_launcher_foreground'; Size = 324; Ratio = 0.66; Mode = 'circle' }
    @{ Dir = 'mipmap-xxxhdpi'; Name = 'ic_launcher_foreground'; Size = 432; Ratio = 0.66; Mode = 'circle' }
    @{ Dir = 'drawable-nodpi'; Name = 'app_logo';               Size = 384; Ratio = 0.94; Mode = 'circle' }
)

foreach ($j in $jobs) {
    $L = [int][Math]::Round($j.Size * $j.Ratio)
    if ($L -ne 512) { $scaled = Resize-Box $mid 512 512 $L $L } else { $scaled = $mid }
    $rgba = Compose-Icon $scaled $L $j.Size $j.Mode

    $dir = Join-Path $ResDir $j.Dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ($j.Name + '.png')
    Write-PngRgba $file $rgba $j.Size $j.Size
    Write-Output ("  {0,-16} {1,4}px  {2,7:n0} B  ({3:n1}s)" -f $j.Name, $j.Size, (Get-Item $file).Length, $sw.Elapsed.TotalSeconds)
}

Write-Output ("all icons written in {0:n1}s" -f $sw.Elapsed.TotalSeconds)
