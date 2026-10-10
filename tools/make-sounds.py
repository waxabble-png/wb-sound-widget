#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wb-sound-widget 提示音生成器
----------------------------
纯标准库（wave / math / struct / array）合成三枚 16bit / 44.1kHz / 单声道 WAV，
不依赖任何第三方包，也不含任何有版权的采样素材。

  1) task-done.wav      任务完成：上行大调琶音 + 空气感泛音尾（明亮、收束感）
  2) need-attention.wav 需要你回答 / 授权：两声下行的"叮-咚"，带轻微颤音（有催促感）
  3) notify.wav         普通提醒：单声轻柔的 ping

用法： python make-sounds.py [输出目录]
"""
import array
import math
import os
import struct
import sys
import wave

SR = 44100


# ---------------------------------------------------------------- 基础工具
def note(freq, dur, amp=1.0, kind="sine", attack=0.004, decay=None,
         vibrato=None, harmonics=((1.0, 1.0),)):
    """生成单个音符的浮点采样序列。

    freq      基频 Hz
    dur       时长 秒
    amp       振幅
    kind      波形：sine / tri / sq
    attack    起振时间 秒（线性淡入，避免爆音）
    decay     指数衰减的时间常数 秒，None 表示用 dur*0.35
    vibrato   (速率Hz, 深度比例) 让声音更"铃"一点
    harmonics (倍频, 权重) 列表，叠加泛音让音色更饱满
    """
    if decay is None:
        decay = dur * 0.35
    n = int(SR * dur)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        # 包络：线性起振 + 指数衰减 + 结尾 5ms 淡出
        env = min(1.0, t / attack) if attack > 0 else 1.0
        env *= math.exp(-t / decay)
        tail = n - i
        if tail < int(SR * 0.005):
            env *= tail / (SR * 0.005)
        # 瞬时频率（含颤音）
        f = freq
        if vibrato:
            f *= 1.0 + vibrato[1] * math.sin(2 * math.pi * vibrato[0] * t)
        phase = 2 * math.pi * f * t
        s = 0.0
        for mult, weight in harmonics:
            p = phase * mult
            if kind == "sine":
                v = math.sin(p)
            elif kind == "tri":
                v = 2.0 / math.pi * math.asin(math.sin(p))
            else:  # sq：用有限项傅里叶近似，避免过分刺耳
                v = (math.sin(p) + math.sin(3 * p) / 3.0 + math.sin(5 * p) / 5.0) * 0.75
            s += v * weight
        out[i] = s * env * amp
    return out


def mix_into(buf, samples, at):
    """把 samples 叠加进 buf 的 at 位置（自动扩展长度）。"""
    need = at + len(samples)
    if need > len(buf):
        buf.extend([0.0] * (need - len(buf)))
    for i, v in enumerate(samples):
        buf[at + i] += v


def lowpass(buf, cutoff):
    """一阶低通，削掉合成波形的高频毛刺，听感更柔和。"""
    alpha = 1.0 - math.exp(-2.0 * math.pi * cutoff / SR)
    y = 0.0
    for i, x in enumerate(buf):
        y += alpha * (x - y)
        buf[i] = y


def normalize(buf, peak=0.86):
    m = max((abs(v) for v in buf), default=0.0)
    if m <= 0:
        return buf
    k = peak / m
    return [v * k for v in buf]


def write_wav(path, buf):
    data = array.array("h")
    for v in buf:
        s = int(max(-1.0, min(1.0, v)) * 32767)
        data.append(s)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


# ---------------------------------------------------------------- 三枚音效
def make_task_done():
    """完成音：C6-E6-G6-C7 上行琶音，最后一音拖长并带泛音尾。"""
    step = int(SR * 0.085)          # 相邻音符间隔
    buf = []
    # (频率, 时长, 振幅, 是否加颤音)
    plan = [
        (1046.50, 0.30, 0.72, None),   # C6
        (1318.51, 0.30, 0.72, None),   # E6
        (1567.98, 0.34, 0.72, None),   # G6
        (2093.00, 0.80, 0.90, (5.5, 0.006)),  # C7 收尾，带一点点"铃"的颤音
    ]
    for i, (f, dur, amp, vib) in enumerate(plan):
        h = ((1.0, 1.0), (2.0, 0.30), (3.0, 0.10))
        mix_into(buf, note(f, dur, amp=amp, decay=dur * 0.30, vibrato=vib, harmonics=h),
                 i * step)
    lowpass(buf, 9000)
    return normalize(buf, 0.88)


def make_need_attention():
    """提醒音：A6 -> E6 两声下行，方波味 + 颤音，明显区别于"完成音"。"""
    buf = []
    # 两声"叮-咚"
    mix_into(buf, note(1760.00, 0.22, amp=0.80, kind="tri",
                       decay=0.055, vibrato=(28.0, 0.030),
                       harmonics=((1.0, 1.0), (2.0, 0.45), (3.0, 0.20))), 0)
    mix_into(buf, note(1174.66, 0.55, amp=0.88, kind="tri",
                       decay=0.150, vibrato=(22.0, 0.028),
                       harmonics=((1.0, 1.0), (2.0, 0.45), (3.0, 0.20))),
             int(SR * 0.20))
    lowpass(buf, 8000)
    return normalize(buf, 0.88)


def make_notify():
    """普通提醒：单声轻柔 ping。"""
    buf = note(1318.51, 0.42, amp=0.80, decay=0.13,
               harmonics=((1.0, 1.0), (2.0, 0.22)))
    lowpass(buf, 11000)
    return normalize(buf, 0.72)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "sounds")
    outdir = os.path.abspath(outdir)
    os.makedirs(outdir, exist_ok=True)

    jobs = [
        ("task-done.wav", make_task_done),
        ("need-attention.wav", make_need_attention),
        ("notify.wav", make_notify),
    ]
    for name, fn in jobs:
        path = os.path.join(outdir, name)
        write_wav(path, fn())
        print("生成 %-20s %7d bytes" % (name, os.path.getsize(path)))


if __name__ == "__main__":
    main()
