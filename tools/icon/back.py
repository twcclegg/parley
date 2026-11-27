"""Draw the icon's back layer: warm near-black with a sweeping band of light for the glass to bend.

python back.py OUT.png [PARAMS.json] -- writes a 16-bit 1024x1024 PNG (needs ImageMagick).
"""
import json, subprocess, sys, tempfile
import numpy as np

Q = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
N = 1024
y, x = (np.mgrid[:N, :N] + 0.5) / N * 2 - 1          # -1..1, y down
y = -y
img = np.zeros((N, N, 3)) + np.array(Q.get("base", [0.035, 0.022, 0.018]))
# soft vignette lift towards the centre
r = np.hypot(x, y)
img += np.array(Q.get("lift", [0.10, 0.055, 0.04]))[None, None] * np.clip(1 - r / 1.3, 0, 1)[..., None] ** 1.5
# a band of light sweeping behind the bubble: y = c + k x^2, rotated
a = np.radians(Q.get("band_angle", -18))
u, v = x * np.cos(a) - y * np.sin(a), x * np.sin(a) + y * np.cos(a)
d = v - (Q.get("band_y", -0.05) + Q.get("band_curve", -0.25) * u ** 2)
w = Q.get("band_w", 0.10)
core = np.exp(-(d / w) ** 2)
halo = np.exp(-(d / (w * 3.5)) ** 2)
along = np.clip(1 - (u / Q.get("band_len", 1.3)) ** 2, 0, 1)   # fades out towards the ends
hot = np.array(Q.get("band_hot", [1.0, 0.82, 0.66]))
warm = np.array(Q.get("band_warm", [0.85, 0.40, 0.25]))
img += (core[..., None] * hot + halo[..., None] * warm * 0.55) * (along ** 1.5)[..., None] * Q.get("band", 1.0)
# the orb's terracotta glow pooled behind it
ox, oy = Q.get("orb", [0.0, 0.023])
g = np.exp(-np.hypot(x - ox, y - oy) / Q.get("glow_r", 0.35))
img += g[..., None] * np.array([0.85, 0.47, 0.34]) * Q.get("glow", 0.5)
img = np.clip(img, 0, 1)
# linear-ish values -> display gamma, written 16-bit with no banding
img = img ** (1 / Q.get("gamma", 1.0))
with tempfile.NamedTemporaryFile(suffix=".pfm", delete=False) as f:
    f.write(f"PF\n{N} {N}\n-1.0\n".encode())
    f.write(np.ascontiguousarray(img[::-1].astype("<f4")).tobytes())
subprocess.run(["magick", f.name, "-depth", "16", sys.argv[1]], check=True)
