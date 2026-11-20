# 重新生成 tools/icon_checksums.txt（图标 PNG 指纹清单）
# 用途：云编译第 2 步「校验图标资源」用 md5sum -c 逐个比对，
#      防止仓库里的 res/mipmap-* 被 Android Studio 默认图标覆盖后还打出包。
# 只收 PNG（二进制，哈希稳定）；自适应图标的 2 个 XML 由工作流按内容判断，
# 免得 Windows/Linux 换行符差异造成误报。
# 用法：换过 logo / 重新跑过 make_icons.ps1 之后，在工程根目录执行：
#      powershell -ExecutionPolicy Bypass -File tools/make_icon_checksums.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$res  = Join-Path $root 'app\src\main\res'
if (-not (Test-Path $res)) { throw "找不到资源目录：$res" }

$files = Get-ChildItem $res -Recurse -File |
    Where-Object { $_.Extension -eq '.png' -and $_.Directory.Name -match 'mipmap|drawable-nodpi' } |
    Sort-Object FullName

if ($files.Count -eq 0) { throw "在 $res 下没找到图标资源，先跑 tools/make_icons.ps1" }

$lines = foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    $md5 = (Get-FileHash $f.FullName -Algorithm MD5).Hash.ToLower()
    "$md5  $rel"
}

# md5sum 要求 LF 换行 + 两个空格分隔，且不能有 BOM
$out = Join-Path $PSScriptRoot 'icon_checksums.txt'
[IO.File]::WriteAllText($out, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

"已写入 $out"
"共 $($files.Count) 个文件："
$lines
