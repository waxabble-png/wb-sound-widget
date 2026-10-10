#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯标准库 PNG(RGBA) 读写：检查/去除白色背景，输出带透明通道的 PNG。

不做色彩管理，只处理 8bit RGBA / RGB 两种常见情况。
"""
import struct
import sys
import zlib


def read_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos = 8
    idat = b''
    w = h = bitdepth = colortype = None
    while pos < len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b'IHDR':
            w, h, bitdepth, colortype, comp, filt, interlace = struct.unpack('>IIBBBBB', chunk)
            assert bitdepth == 8 and interlace == 0, 'unsupported png format'
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'IEND':
            break
        pos += 12 + length

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    raw = zlib.decompress(idat)
    stride = w * channels
    out = bytearray(w * h * channels)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa = abs(b - c)
                pb = abs(a - c)
                pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, channels, out


def write_png(path, w, h, rgba):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)

    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', zlib.compress(bytes(raw), 9)))
        f.write(chunk(b'IEND', b''))


def to_rgba(w, h, channels, buf):
    if channels == 4:
        return bytearray(buf)
    out = bytearray(w * h * 4)
    for i in range(w * h):
        o = i * 4
        if channels == 3:
            out[o:o + 3] = buf[i * 3:i * 3 + 3]
            out[o + 3] = 255
        elif channels == 2:
            out[o] = out[o + 1] = out[o + 2] = buf[i * 2]
            out[o + 3] = buf[i * 2 + 1]
        else:
            v = buf[i]
            out[o] = out[o + 1] = out[o + 2] = v
            out[o + 3] = 255
    return out


def stats(w, h, rgba):
    tot = w * h
    transparent = 0
    for i in range(tot):
        if rgba[i * 4 + 3] < 8:
            transparent += 1
    corners = []
    for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w // 2, 0)]:
        o = (y * w + x) * 4
        corners.append((x, y, rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]))
    return transparent, tot, corners


def strip_white(w, h, rgba, tol=16):
    """把与四角同色的、且彼此连通的近白区域变成透明（BFS 泛洪，只吃背景不动角色内部）。"""
    from collections import deque
    # 以四角像素的平均色作为背景色
    samples = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    br = sum(rgba[(y * w + x) * 4] for x, y in samples) // 4
    bg = sum(rgba[(y * w + x) * 4 + 1] for x, y in samples) // 4
    bb = sum(rgba[(y * w + x) * 4 + 2] for x, y in samples) // 4

    def near_bg(i):
        o = i * 4
        return (abs(rgba[o] - br) <= tol and abs(rgba[o + 1] - bg) <= tol
                and abs(rgba[o + 2] - bb) <= tol)

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not seen[i] and near_bg(i):
                seen[i] = 1
                q.append(i)
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not seen[i] and near_bg(i):
                seen[i] = 1
                q.append(i)
    while q:
        i = q.popleft()
        y, x = divmod(i, w)
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h:
                j = ny * w + nx
                if not seen[j] and near_bg(j):
                    seen[j] = 1
                    q.append(j)
    cleared = 0
    for i in range(w * h):
        if seen[i]:
            rgba[i * 4 + 3] = 0
            cleared += 1
    # 半透明边缘柔化：让紧贴透明区的像素按距离衰减一点，避免锯齿
    alpha = [rgba[i * 4 + 3] for i in range(w * h)]
    for i in range(w * h):
        y, x = divmod(i, w)
        if seen[i]:
            continue
        edge = False
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h and seen[ny * w + nx]:
                edge = True
                break
        if edge:
            rgba[i * 4 + 3] = int(alpha[i] * 0.72)
    return cleared


if __name__ == '__main__':
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else None
    w, h, ch, buf = read_png(src)
    rgba = to_rgba(w, h, ch, buf)
    t, tot, corners = stats(w, h, rgba)
    print('%s  %dx%d  channels=%d  全透明像素=%.1f%%' % (src, w, h, ch, 100.0 * t / tot))
    for c in corners:
        print('   角点 x=%d y=%d  rgba=(%d,%d,%d,%d)' % c)
    if dst:
        n = strip_white(w, h, rgba)
        write_png(dst, w, h, rgba)
        t2, _, _ = stats(w, h, rgba)
        print('   → 抠掉背景 %d 像素，写入 %s（现在全透明 %.1f%%）' % (n, dst, 100.0 * t2 / tot))
