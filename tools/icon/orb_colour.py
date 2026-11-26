"""Report an orb render's main colour: the median of its body pixels (not highlights or the dark rim)."""
import sys, colorsys
import numpy as np
from PIL import Image
im = np.asarray(Image.open(sys.argv[1]).convert("RGBA")).astype(float) / 255
h, w = im.shape[:2]
yy, xx = np.mgrid[0:h, 0:w]
r = np.hypot((xx - w / 2) / (w / 2), (yy - h / 2) / (h / 2))
body = im[(r < 0.75) & (im[..., 3] > 0.99)][:, :3]
lum = body @ [0.2126, 0.7152, 0.0722]
body = body[(lum > np.percentile(lum, 20)) & (lum < np.percentile(lum, 80))]
med = np.median(body, axis=0)
hexc = "".join(f"{int(round(c * 255)):02X}" for c in med)
t = np.array([0xD9, 0x77, 0x57]) / 255
d = np.abs(np.array(colorsys.rgb_to_hsv(*med)) - np.array(colorsys.rgb_to_hsv(*t)))
print(f"main colour #{hexc}  target #D97757  hue diff {d[0]*360:.1f} deg  sat diff {d[1]:.2f}  value diff {d[2]:.2f}")
