#!/usr/bin/env python3
"""Generate the app icons required by app.json5 / module.json5.

HarmonyOS "鸿蒙生态规则检测"（应用图标规范）要求：

* 图标必须分 **前景图 / 背景图两层**，各 1024px * 1024px，由
  ``layered_image.json`` 引用（``$media:layered_image``）；
* 背景图必须**实色不透明**，前景图透明背景，两者都**不允许自行裁圆角、
  不允许在资源内加内间距**（圆角/padding 由系统蒙版生成）；
* 前景主体须落在中心安全区（约中心 66%），系统会叠加形状蒙版；
* **禁止使用 DevEco 模板默认图标**（旧版生成的 216px 纯色方块 /
  114px 蓝色四方格模板图标会被判「使用系统默认图标」而驳回）；
* ``app.json5`` 与 ``module.json5`` 里 EntryAbility 的 icon 都应指向
  同一个分层图标，避免 module 级 icon 覆盖 app 级导致配置冲突。

用法： ``python3 scripts/gen_icons.py app``
产物（均在版本库内，构建脚本无需再生成）：

    app/AppScope/resources/base/media/layered_image.json
    app/AppScope/resources/base/media/background.png   1024 实色
    app/AppScope/resources/base/media/foreground.png  1024 透明 + 标志
    app/AppScope/resources/base/media/app_icon.png    1024 合成图（兜底）
    app/entry/src/main/resources/base/media/icon.png  1024 合成图（启动图）

仅用标准库，无第三方依赖。
"""

import math
import os
import struct
import sys
import zlib

SIZE = 1024
BG = (16, 24, 32)             # #101820，与 start_window_background 一致
FG_TOP = (94, 234, 212)       # #5EEAD4
FG_BOTTOM = (56, 189, 248)    # #38BDF8

# 标志：三节点折线（"V" / 代理链路），全部落在中心安全区。
NODES = ((342.0, 372.0), (512.0, 662.0), (682.0, 372.0))
SEGMENTS = ((NODES[0], NODES[1]), (NODES[1], NODES[2]))
LINE_HALF = 17.0
NODE_R = 46.0
AA = 3.0

# 只需在标志外接矩形内逐像素计算，其余区域 alpha=0（快速路径）
BOX = (260, 764, 290, 740)  # x0, x1, y0, y1


def _chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))


def write_png(path, buf):
    ihdr = struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0)
    raw = b''.join(b'\x00' + bytes(buf[y * SIZE * 4:(y + 1) * SIZE * 4])
                   for y in range(SIZE))
    blob = (b'\x89PNG\r\n\x1a\n'
            + _chunk(b'IHDR', ihdr)
            + _chunk(b'IDAT', zlib.compress(raw, 9))
            + _chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(blob)


def _coverage(dist, radius):
    t = (radius + AA - dist) / (2 * AA)
    return 0.0 if t <= 0.0 else (1.0 if t >= 1.0 else t * t * (3 - 2 * t))


def _seg_dist(px, py, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = ((px - a[0]) * dx + (py - a[1]) * dy) / (dx * dx + dy * dy)
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy))


def build_mark():
    """返回 SIZE*SIZE 的 alpha 字节表（标志覆盖率）。"""
    mark = bytearray(SIZE * SIZE)
    x0, x1, y0, y1 = BOX
    for y in range(y0, y1):
        py = y + 0.5
        row = y * SIZE
        for x in range(x0, x1):
            px = x + 0.5
            a = 0.0
            for s, e in SEGMENTS:
                a = max(a, _coverage(_seg_dist(px, py, s, e), LINE_HALF))
                if a >= 1.0:
                    break
            if a < 1.0:
                for nx, ny in NODES:
                    a = max(a, _coverage(math.hypot(px - nx, py - ny), NODE_R))
                    if a >= 1.0:
                        break
            if a > 0.0:
                mark[row + x] = int(round(a * 255))
    return mark


def _lerp(a, b, t):
    return (int(a[0] + (b[0] - a[0]) * t),
            int(a[1] + (b[1] - a[1]) * t),
            int(a[2] + (b[2] - a[2]) * t))


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else 'app'
    app_media = os.path.join(base, 'AppScope', 'resources', 'base', 'media')
    entry_media = os.path.join(base, 'entry', 'src', 'main', 'resources',
                               'base', 'media')
    os.makedirs(app_media, exist_ok=True)
    os.makedirs(entry_media, exist_ok=True)

    mark = build_mark()

    # 背景图：实色不透明，无圆角/内间距/透明像素
    write_png(os.path.join(app_media, 'background.png'),
              bytearray(bytes((*BG, 255)) * (SIZE * SIZE)))

    # 前景图：透明底 + 标志
    fg = bytearray(SIZE * SIZE * 4)
    for y in range(SIZE):
        col = _lerp(FG_TOP, FG_BOTTOM, y / (SIZE - 1))
        row = y * SIZE
        row4 = row * 4
        for x in range(SIZE):
            a = mark[row + x]
            if a:
                i = row4 + x * 4
                fg[i] = col[0]
                fg[i + 1] = col[1]
                fg[i + 2] = col[2]
                fg[i + 3] = a
    write_png(os.path.join(app_media, 'foreground.png'), fg)

    # 合成图：app_icon（兜底）与 icon（startWindowIcon 启动图）
    # 两层都是全尺寸、不透明，避免「未配置前景/背景图」误判。
    full = bytearray(SIZE * SIZE * 4)
    for y in range(SIZE):
        col = _lerp(FG_TOP, FG_BOTTOM, y / (SIZE - 1))
        row = y * SIZE
        row4 = row * 4
        for x in range(SIZE):
            a = mark[row + x] / 255.0
            i = row4 + x * 4
            full[i] = int(BG[0] + (col[0] - BG[0]) * a)
            full[i + 1] = int(BG[1] + (col[1] - BG[1]) * a)
            full[i + 2] = int(BG[2] + (col[2] - BG[2]) * a)
            full[i + 3] = 255
    write_png(os.path.join(app_media, 'app_icon.png'), full)
    write_png(os.path.join(entry_media, 'icon.png'), full)

    with open(os.path.join(app_media, 'layered_image.json'), 'w',
              encoding='utf-8') as f:
        f.write('{\n'
                '  "layered-image": {\n'
                '    "background": "$media:background",\n'
                '    "foreground": "$media:foreground"\n'
                '  }\n'
                '}\n')

    print('icons written: layered_image.json + background/foreground/'
          'app_icon/icon (1024x1024)')


if __name__ == '__main__':
    main()
