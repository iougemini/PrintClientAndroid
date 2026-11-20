# 检查 PNG 的视觉特征：判断图标是「瑜华印务圆徽」还是「安卓默认机器人」
# 纯 .NET BCL 实现（本机无法加载图像库）
param([string[]]$Paths)

function Read-PngRgba {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    $w = [int](($b[16] -shl 24) -bor ($b[17] -shl 16) -bor ($b[18] -shl 8) -bor $b[19])
    $h = [int](($b[20] -shl 24) -bor ($b[21] -shl 16) -bor ($b[22] -shl 8) -bor $b[23])
    $depth = $b[24]; $ctype = $b[25]

    $idat = New-Object IO.MemoryStream
    $p = 8
    while ($p -lt $b.Length) {
        $len = [int](($b[$p] -shl 24) -bor ($b[$p+1] -shl 16) -bor ($b[$p+2] -shl 8) -bor $b[$p+3])
        $type = [Text.Encoding]::ASCII.GetString($b, $p + 4, 4)
        if ($type -eq 'IDAT') { $idat.Write($b, $p + 8, $len) }
        $p += 12 + $len
    }
    $z = $idat.ToArray()
    $ms = New-Object IO.MemoryStream
    $ms.Write($z, 2, $z.Length - 2)
    $ms.Position = 0
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $raw = New-Object IO.MemoryStream
    $buf = New-Object byte[] 65536
    while (($n = $ds.Read($buf, 0, $buf.Length)) -gt 0) { $raw.Write($buf, 0, $n) }
    $data = $raw.ToArray()

    $bpp = switch ($ctype) { 0 { 1 } 2 { 3 } 4 { 2 } 6 { 4 } }
    if ($depth -ne 8 -or $bpp -eq $null) { throw "unsupported depth=$depth ctype=$ctype" }

    $stride = $w * $bpp
    $out = New-Object byte[] ($w * $h * 4)
    $prev = New-Object byte[] $stride
    $cur  = New-Object byte[] $stride
    $off = 0
    for ($y = 0; $y -lt $h; $y++) {
        $ft = $data[$off]; $off++
        [Array]::Copy($data, $off, $cur, 0, $stride)
        $off += $stride
        for ($x = 0; $x -lt $stride; $x++) {
            $a = if ($x -ge $bpp) { $cur[$x - $bpp] } else { 0 }
            $u = $prev[$x]
            $c = if ($x -ge $bpp) { $prev[$x - $bpp] } else { 0 }
            switch ($ft) {
                0 { }
                1 { $cur[$x] = [byte](($cur[$x] + $a) -band 0xFF) }
                2 { $cur[$x] = [byte](($cur[$x] + $u) -band 0xFF) }
                3 { $cur[$x] = [byte](($cur[$x] + [math]::Floor(($a + $u) / 2)) -band 0xFF) }
                4 {
                    $pp = $a + $u - $c
                    $pa = [math]::Abs($pp - $a); $pb = [math]::Abs($pp - $u); $pc = [math]::Abs($pp - $c)
                    $pr = if (($pa -le $pb) -and ($pa -le $pc)) { $a } elseif ($pb -le $pc) { $u } else { $c }
                    $cur[$x] = [byte](($cur[$x] + $pr) -band 0xFF)
                }
            }
        }
        for ($x = 0; $x -lt $w; $x++) {
            $si = $x * $bpp; $di = ($y * $w + $x) * 4
            switch ($ctype) {
                0 { $out[$di] = $cur[$si]; $out[$di+1] = $cur[$si]; $out[$di+2] = $cur[$si]; $out[$di+3] = 255 }
                2 { $out[$di] = $cur[$si]; $out[$di+1] = $cur[$si+1]; $out[$di+2] = $cur[$si+2]; $out[$di+3] = 255 }
                4 { $out[$di] = $cur[$si]; $out[$di+1] = $cur[$si]; $out[$di+2] = $cur[$si]; $out[$di+3] = $cur[$si+1] }
                6 { $out[$di] = $cur[$si]; $out[$di+1] = $cur[$si+1]; $out[$di+2] = $cur[$si+2]; $out[$di+3] = $cur[$si+3] }
            }
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return @{ W = $w; H = $h; Px = $out }
}

function Pix {
    param([byte[]]$px, [int]$w, [int]$x, [int]$y)
    $i = ($y * $w + $x) * 4
    return ('({0},{1},{2},a{3})' -f $px[$i], $px[$i+1], $px[$i+2], $px[$i+3])
}

foreach ($path in $Paths) {
    if (-not (Test-Path $path)) { $path + '  -> MISSING'; continue }
    $img = Read-PngRgba $path
    $w = $img.W; $h = $img.H; $px = $img.Px
    $n = $w * $h
    $sumR = 0; $sumG = 0; $sumB = 0
    $green = 0; $white = 0; $red = 0; $transparent = 0
    for ($i = 0; $i -lt $n; $i++) {
        $r = $px[$i*4]; $g = $px[$i*4+1]; $bl = $px[$i*4+2]; $al = $px[$i*4+3]
        $sumR += $r; $sumG += $g; $sumB += $bl
        if ($al -lt 16) { $transparent++ }
        if ($al -gt 200) {
            if ($r -lt 60 -and $g -gt 90 -and $g -lt 160 -and $bl -lt 90) { $green++ }
            if ($r -gt 230 -and $g -gt 230 -and $bl -gt 230) { $white++ }
            if ($r -gt 120 -and $g -lt 100 -and $bl -lt 90) { $red++ }
        }
    }
    $name = Split-Path $path -Leaf
    $dir = Split-Path (Split-Path $path -Parent) -Leaf
    "$dir/$name  ${w}x${h}"
    "  avg RGB = {0},{1},{2}" -f [int]($sumR/$n), [int]($sumG/$n), [int]($sumB/$n)
    "  绿底占比 = {0:N1}%   纯白 = {1:N1}%   朱红 = {2:N1}%   透明 = {3:N1}%" -f (100.0*$green/$n), (100.0*$white/$n), (100.0*$red/$n), (100.0*$transparent/$n)
    "  四角 = " + ((Pix $px $w 1 1) + ' ' + (Pix $px $w ($w-2) 1) + ' ' + (Pix $px $w 1 ($h-2)) + ' ' + (Pix $px $w ($w-2) ($h-2)))
    "  正中心 = " + (Pix $px $w ([int]($w/2)) ([int]($h/2)))
    ''
}
