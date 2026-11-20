# 拆开 APK 看里面到底有哪些图标资源（纯 .NET BCL，不依赖 ZipFile 类型）
# 用法：powershell -ExecutionPolicy Bypass -File tools\inspect_apk.ps1 -Apk "C:\path\app-debug.apk"
param(
    [Parameter(Mandatory=$true)][string]$Apk,
    [string[]]$Strings = @(),          # 要提取可读字符串的条目名，如 AndroidManifest.xml
    [int]$MaxStrings = 80,
    [switch]$Quiet                     # 只输出关键结论，不列全部 res 条目
)

function U16 { param([byte[]]$b, [int64]$o) ([int64]$b[$o] + ([int64]$b[$o+1] * 256)) }
function U32 { param([byte[]]$b, [int64]$o) ([int64]$b[$o] + ([int64]$b[$o+1] * 256) + ([int64]$b[$o+2] * 65536) + ([int64]$b[$o+3] * 16777216)) }

$bytes = [IO.File]::ReadAllBytes($Apk)
$len = $bytes.Length
Write-Output ("APK 大小: {0:N0} 字节" -f $len)

# --- 找 EOCD ---
$eocd = -1
for ($i = $len - 22; $i -ge 0 -and $i -ge $len - 66000; $i--) {
    if ($bytes[$i] -eq 0x50 -and $bytes[$i+1] -eq 0x4B -and $bytes[$i+2] -eq 0x05 -and $bytes[$i+3] -eq 0x06) { $eocd = $i; break }
}
if ($eocd -lt 0) { throw "找不到 ZIP 目录结尾（不是有效的 APK/ZIP）" }

$count = U16 $bytes ($eocd + 10)
$cdOff = U32 $bytes ($eocd + 16)
Write-Output ("中央目录: {0} 条, 偏移 {1}" -f $count, $cdOff)

$entries = New-Object System.Collections.ArrayList
$p = $cdOff
for ($n = 0; $n -lt $count; $n++) {
    if ((U32 $bytes $p) -ne 0x02014b50) { break }
    $method  = U16 $bytes ($p + 10)
    $csize   = U32 $bytes ($p + 20)
    $usize   = U32 $bytes ($p + 24)
    $nameLen = U16 $bytes ($p + 28)
    $extraLen= U16 $bytes ($p + 30)
    $cmtLen  = U16 $bytes ($p + 32)
    $lho     = U32 $bytes ($p + 42)
    $name    = [Text.Encoding]::UTF8.GetString($bytes, [int]($p + 46), [int]$nameLen)
    [void]$entries.Add([pscustomobject]@{ Name=$name; Method=$method; CSize=$csize; USize=$usize; LHO=$lho })
    $p += 46 + $nameLen + $extraLen + $cmtLen
}
Write-Output ("解析到 {0} 个条目" -f $entries.Count)

function Get-EntryBytes {
    param($e)
    $off = $e.LHO
    if ((U32 $bytes $off) -ne 0x04034b50) { return $null }
    $nLen = U16 $bytes ($off + 26)
    $xLen = U16 $bytes ($off + 28)
    $start = $off + 30 + $nLen + $xLen
    if ($e.Method -eq 0) {
        $out = New-Object byte[] $e.USize
        [Array]::Copy($bytes, [int]$start, $out, 0, [int]$e.USize)
        return $out
    }
    if ($e.Method -ne 8) { return $null }
    $ms = New-Object IO.MemoryStream
    $ms.Write($bytes, [int]$start, [int]$e.CSize)
    $ms.Position = 0
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    $buf = New-Object byte[] 65536
    while (($r = $ds.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $r) }
    $ds.Dispose(); $ms.Dispose()
    return $out.ToArray()
}

function Get-Md5 { param([byte[]]$d) $md5 = [Security.Cryptography.MD5]::Create(); try { return ([BitConverter]::ToString($md5.ComputeHash($d)) -replace '-', '').ToLower() } finally { $md5.Dispose() } }

# --- 关键文件是否在 ---
Write-Output ""
Write-Output "=== 关键条目 ==="
foreach ($k in @('AndroidManifest.xml','resources.arsc','classes.dex')) {
    $hit = $entries | Where-Object { $_.Name -eq $k }
    if ($hit) { Write-Output ("{0,-22} 在，{1:N0} 字节" -f $k, $hit.USize) } else { Write-Output ("{0,-22} 缺失" -f $k) }
}

# --- 所有 PNG：尺寸 + md5 ---
Write-Output ""
Write-Output "=== 图标类资源（名字含 launcher / 或以 res/ 开头的图片）==="
$rows = @()
foreach ($e in $entries) {
    if ($e.Name -notmatch '\.(png|webp|xml)$') { continue }
    if ($e.Name -notmatch '^res/' -and $e.Name -notmatch 'launcher') { continue }
    $d = Get-EntryBytes $e
    if ($null -eq $d) { continue }
    $isPng = ($d.Length -gt 24 -and $d[0] -eq 0x89 -and $d[1] -eq 0x50 -and $d[2] -eq 0x4E -and $d[3] -eq 0x47)
    $w = 0; $h = 0; $ct = ''
    if ($isPng) {
        $w = U32 $d 16; $h = U32 $d 20
        $ct = "depth=$($d[24]) type=$($d[25])"
    }
    $rows += [pscustomobject]@{
        Name = $e.Name
        USize = $e.USize
        W = if ($isPng) { $w } else { '' }
        H = if ($isPng) { $h } else { '' }
        Md5 = Get-Md5 $d
        Note = $ct
    }
}
if (-not $Quiet) {
    $rows | Sort-Object Name | Format-Table -AutoSize | Out-String -Width 200
} else {
    Write-Output ("图标类图片条目数: {0}" -f $rows.Count)
}

# --- 提取指定条目里的可读字符串（二进制 XML / arsc 用得上）---
foreach ($want in $Strings) {
    $e = $entries | Where-Object { $_.Name -eq $want } | Select-Object -First 1
    if (-not $e) { Write-Output "`n=== $want 不在 APK 里 ==="; continue }
    $d = Get-EntryBytes $e
    Write-Output ""
    Write-Output ("=== {0} 内的可读字符串（{1:N0} 字节）===" -f $want, $d.Length)
    $found = New-Object System.Collections.ArrayList
    # UTF-8 / ASCII 连续可打印段
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $d) {
        if ($ch -ge 32 -and $ch -lt 127) { [void]$sb.Append([char]$ch) }
        else {
            if ($sb.Length -ge 4) { [void]$found.Add($sb.ToString()) }
            [void]$sb.Clear()
        }
    }
    if ($sb.Length -ge 4) { [void]$found.Add($sb.ToString()) }
    # UTF-16LE 段
    $sb2 = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $d.Length - 1; $i += 2) {
        $lo = $d[$i]; $hi = $d[$i + 1]
        if ($hi -eq 0 -and $lo -ge 32 -and $lo -lt 127) { [void]$sb2.Append([char]$lo) }
        else {
            if ($sb2.Length -ge 3) { [void]$found.Add('[u16]' + $sb2.ToString()) }
            [void]$sb2.Clear()
        }
    }
    if ($sb2.Length -ge 3) { [void]$found.Add('[u16]' + $sb2.ToString()) }
    $found | Select-Object -Unique -First $MaxStrings | ForEach-Object { "  " + $_ }
}
Write-Output "=== 与工程内图标 MD5 对照 ==="
$res = Join-Path (Split-Path $PSScriptRoot -Parent) 'app\src\main\res'
if (Test-Path $res) {
    $known = @{}
    Get-ChildItem $res -Recurse -File -Filter *.png | ForEach-Object {
        $h = (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower()
        $known[$h] = $_.FullName.Substring($res.Length + 1)
    }
    $matched = 0
    foreach ($r in $rows) { if ($known.ContainsKey($r.Md5)) { $matched++; Write-Output ("  命中: {0}  <=  {1}" -f $r.Name, $known[$r.Md5]) } }
    Write-Output ("  命中 {0} / APK 内图片 {1} 张，工程内共 {2} 张" -f $matched, $rows.Count, $known.Count)
    if ($matched -eq 0) { Write-Output "  ⚠ 一个都没命中：APK 里的图标不是工程里这套（可能是模板图标，也可能被 aapt2 重新压缩过）" }
}
