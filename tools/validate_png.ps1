# 校验 PNG 结构：逐个 chunk 计算 CRC32 与文件内记录值比对
# 背景：Android 用 libpng 系解码器，CRC 错会解码失败 → 启动器退回系统默认图标
# 算法：逐位 CRC32（反射，多项式 0xEDB88320），不经查找表，避免 PowerShell 字面量坑
# 用法：powershell -ExecutionPolicy Bypass -File tools\validate_png.ps1 -Paths a.png,b.png
param([string[]]$Paths)

function Crc32-Range {
    param([byte[]]$d, [int]$off, [int]$len)
    [int64]$crc = 4294967295
    $end = $off + $len
    for ($i = $off; $i -lt $end; $i++) {
        $crc = $crc -bxor [int64]$d[$i]
        for ($k = 0; $k -lt 8; $k++) {
            if (($crc -band 1) -ne 0) { $crc = (($crc -shr 1) -bxor 3988292384) -band 4294967295 }
            else { $crc = ($crc -shr 1) -band 4294967295 }
        }
    }
    return [int64](($crc -bxor 4294967295) -band 4294967295)
}

function Get-Be32 { param([byte[]]$b, [int]$o) ([int64]$b[$o] * 16777216 + [int64]$b[$o+1] * 65536 + [int64]$b[$o+2] * 256 + [int64]$b[$o+3]) }

# 自检：任何合法 PNG 结尾都是 49 45 4E 44 AE 42 60 82，即 CRC32("IEND") = 0xAE426082
# 期望值用字节数值算出来，不写字面量（十六进制大数在 PS 5.1 里会被当成负 Int32）
$expected = [int64]174 * 16777216 + [int64]66 * 65536 + [int64]96 * 256 + 130   # 0xAE 42 60 82
$probe = [byte[]](73, 69, 78, 68)                                              # "IEND"
$self = Crc32-Range $probe 0 4
$selfOK = ($self -eq $expected)
Write-Output ("自检 CRC32(IEND): {0}  期望 {1}  {2}" -f $self, $expected, $(if ($selfOK) { 'OK' } else { 'FAIL(自身实现有问题)' }))

$allOK = $true
foreach ($p in $Paths) {
    if (-not (Test-Path $p)) { Write-Output "MISSING  $p"; continue }
    $b = [IO.File]::ReadAllBytes($p)
    $name = Split-Path $p -Leaf
    $sigOK = ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47)
    $bad = @()
    $names = @()
    $off = 8
    while ($off + 12 -le $b.Length) {
        $len = [int](Get-Be32 $b $off)
        $type = [Text.Encoding]::ASCII.GetString($b, $off + 4, 4)
        if ($off + 12 + $len -gt $b.Length) { $bad += "chunk $type 越界"; break }
        $calc = Crc32-Range $b ($off + 4) (4 + $len)
        $rec  = Get-Be32 $b ($off + 8 + $len)
        $names += $type
        if ($calc -ne $rec) { $bad += ("{0}: 计算={1} 记录={2}" -f $type, $calc, $rec) }
        $off += 12 + $len
        if ($type -eq 'IEND') { break }
    }
    $trailing = $b.Length - $off
    $ok = ($bad.Count -eq 0 -and $sigOK -and $trailing -eq 0)
    if (-not $ok) { $allOK = $false }
    Write-Output ("{0}  {1}  {2} B  [{3}]" -f $(if ($ok) { 'OK  ' } else { 'BAD ' }), $name, $b.Length, ($names -join ' '))
    if (-not $sigOK) { Write-Output "      PNG 签名错误" }
    if ($trailing -ne 0) { Write-Output ("      末尾多余 {0} 字节" -f $trailing) }
    foreach ($x in $bad) { Write-Output ("      !! " + $x) }
}
if ($selfOK -and $allOK) { Write-Output "== 全部通过 ==" } else { Write-Output "== 有问题 ==" }
