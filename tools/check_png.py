#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 app/src/main/res 下所有 PNG 的结构是否正确（标准库实现，无需装依赖）。

为什么需要它：
    曾经出过一次事故——图标 PNG 由脚本生成，文件名、尺寸、字节数、MD5 全都对，
    但每个 chunk 的 CRC32 写错了。Android 用 libpng 系解码器，CRC 校验不过就当图片损坏，
    于是桌面启动器退回系统默认图标（绿底网格 + 白色安卓机器人），
    而 in-app 的 logo 图也渲染成空白。只比对 MD5 完全抓不到这类问题。

用法：
    python3 tools/check_png.py            # 扫默认目录
    python3 tools/check_png.py a.png b/   # 只看指定文件/目录

返回码：0 全部通过，1 有文件损坏。
"""
import binascii
import pathlib
import struct
import sys

PNG_SIG = b'\x89PNG\r\n\x1a\n'
IEND_CRC = 0xAE426082


def check_one(path: pathlib.Path):
    """返回错误描述；没问题返回 None。"""
    data = path.read_bytes()
    if data[:8] != PNG_SIG:
        return 'PNG 签名错误'

    off = 8
    ended = False
    while off + 12 <= len(data):
        length = struct.unpack('>I', data[off:off + 4])[0]
        ctype = data[off + 4:off + 8]
        body = data[off + 4:off + 8 + length]
        calc = binascii.crc32(body) & 0xFFFFFFFF
        recorded = struct.unpack('>I', data[off + 8 + length:off + 12 + length])[0]
        if calc != recorded:
            name = ctype.decode('ascii', 'replace')
            return '%s 的 CRC 不符（计算 %d，记录 %d）' % (name, calc, recorded)
        off += 12 + length
        if ctype == b'IEND':
            ended = True
            if recorded != IEND_CRC:
                return 'IEND 的 CRC 不是标准值 0xAE426082'
            break

    if not ended:
        return '缺少 IEND 或数据被截断'
    if off != len(data):
        return '末尾多出 %d 字节' % (len(data) - off)
    return None


def main(argv):
    root = pathlib.Path(__file__).resolve().parent.parent
    targets = argv[1:]
    if targets:
        files = []
        for t in targets:
            p = pathlib.Path(t)
            files.extend(sorted(p.rglob('*.png')) if p.is_dir() else [p])
    else:
        files = sorted((root / 'app' / 'src' / 'main' / 'res').rglob('*.png'))

    if not files:
        print('没找到 PNG，检查一下路径')
        return 1

    bad = []
    for f in files:
        err = check_one(f)
        if err:
            bad.append((f, err))

    print('检查 PNG：%d 个' % len(files))
    for f, err in bad:
        print('  [坏] %s  ->  %s' % (f, err))
    if bad:
        print('')
        print('这些图 Android 解不出来，装到手机上会显示系统默认图标（绿底机器人）。')
        print('处理：跑 tools/make_icons.ps1 重新生成图标后再打包。')
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
