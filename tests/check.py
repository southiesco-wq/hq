"""Checks a converted file: channels, codec, durations, picture untouched, and sound timing."""
import json, subprocess, sys, wave
import numpy as np

def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)

def mono_samples(path, rate=8000, first_channel=False):
    mix = ["-af", "pan=mono|c0=c0"] if first_channel else ["-ac", "1"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0", *mix, "-ar", str(rate),
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)

def envelope(x, step=40):
    n = len(x) // step
    return np.abs(x[:n * step]).reshape(n, step).mean(1)

def main():
    src, out, want_channels, kind = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    p_in, p_out = probe(src), probe(out)
    a = [s for s in p_out["streams"] if s["codec_type"] == "audio"]
    v_in = [s for s in p_in["streams"] if s["codec_type"] == "video"]
    v_out = [s for s in p_out["streams"] if s["codec_type"] == "video"]
    problems = []
    if len(a) != 1: problems.append(f"expected 1 audio stream, got {len(a)}")
    elif int(a[0]["channels"]) != want_channels: problems.append(f"expected {want_channels} channel(s), got {a[0]['channels']}")
    elif a[0]["codec_name"] != "aac": problems.append(f"audio codec {a[0]['codec_name']}")
    if len(v_out) != len(v_in): problems.append("video stream count changed")
    elif v_out and v_out[0]["codec_name"] != v_in[0]["codec_name"]: problems.append("video codec changed")
    if v_out and v_in and v_out[0].get("nb_frames") != v_in[0].get("nb_frames"):
        problems.append(f"video frames {v_in[0].get('nb_frames')} -> {v_out[0].get('nb_frames')}")
    dur_v = float(v_out[0]["duration"]) if v_out else None
    dur_a = float(a[0]["duration"]) if a else None
    if dur_v and dur_a and abs(dur_v - dur_a) > 0.15: problems.append(f"audio {dur_a:.3f}s vs video {dur_v:.3f}s")

    # Timing: where does the speech start, before vs after (8 kHz envelope, 5 ms steps)?
    x, y = mono_samples(src), mono_samples(out, first_channel=True)
    ex, ey = envelope(x), envelope(y)
    n = min(len(ex), len(ey))
    ex, ey = ex[:n] - ex[:n].mean(), ey[:n] - ey[:n].mean()
    best, lag = -2, 0
    for L in range(-60, 61):  # +-300 ms
        if L >= 0: c = np.dot(ex[:n - L], ey[L:])
        else: c = np.dot(ex[-L:], ey[:n + L])
        if c > best: best, lag = c, L
    lag_ms = lag * 5
    full = mono_samples(out, rate=48000, first_channel=True)
    peak = float(np.max(np.abs(full))) if len(full) else 0
    rms = float(np.sqrt(np.mean(y.astype(np.float64) ** 2))) if len(y) else 0
    # Noise before the speech starts (first 0.8 s) relative to the speech part.
    pre = y[: int(0.8 * 8000)]
    speech = y[int(1.2 * 8000): int(4.0 * 8000)]
    floor_db = 20 * np.log10(np.sqrt(np.mean(pre.astype(np.float64) ** 2)) + 1e-9)
    speech_db = 20 * np.log10(np.sqrt(np.mean(speech.astype(np.float64) ** 2)) + 1e-9)
    if kind != "phase" and abs(lag_ms) > 25: problems.append(f"sound shifted by {lag_ms} ms")
    if peak > 1.02: problems.append(f"clipping, peak {peak:.3f}")
    print(f"  channels={a[0]['channels'] if a else '?'} audio={dur_a} video={dur_v} shift={lag_ms}ms "
          f"peak={peak:.2f} noise_floor={floor_db:.1f}dB speech={speech_db:.1f}dB gap={speech_db - floor_db:.1f}dB")
    if problems:
        print("  PROBLEMS: " + "; ".join(problems))
        sys.exit(1)

main()
