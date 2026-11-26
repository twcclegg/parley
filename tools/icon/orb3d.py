"""Ray-traced glass orb: terracotta glass with studio reflections. render(size, ss) -> RGBA float array."""
import numpy as np

T = np.array([0xD9, 0x77, 0x57]) / 255.0          # base colour
CREAM = np.array([0.97, 0.965, 0.95])

def norm(v): return v / np.linalg.norm(v, axis=-1, keepdims=True)
def dot(a, b): return np.sum(a * b, axis=-1, keepdims=True)
def ss(e0, e1, v): t = np.clip((v - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)

def rect(az, el, a0, a1, e0, e1, soft):
    return ss(a0 - soft, a0 + soft, az) * (1 - ss(a1 - soft, a1 + soft, az)) * \
           ss(e0 - soft, e0 + soft, el) * (1 - ss(e1 - soft, e1 + soft, el))

def env(d):
    """Studio around the orb. +z faces the viewer; -z is the bubble the orb sits on."""
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    az = np.degrees(np.arctan2(x, z)); el = np.degrees(np.arcsin(np.clip(y, -1, 1)))
    c = np.zeros(d.shape) + np.array([0.025, 0.022, 0.02])
    # behind: the cream bubble face, brighter towards its top
    behind = ss(-0.55, -0.85, z)
    bub = CREAM * 0.8 * (0.6 + 0.4 * ss(-1, 1, y))[..., None]
    c = c * (1 - behind[..., None]) + bub * behind[..., None]
    # key softbox, upper left, with a cross bar like a window frame
    key = rect(az, el, -100, -52, 22, 72, 2.0)
    bar = 1 - 0.9 * (np.exp(-((az + 72) / 1.4) ** 2) * (el > 22) * (el < 72))
    c = c + (key * bar)[..., None] * np.array([22.0, 21.5, 21.0])
    # fill window, upper right, smaller
    fill = rect(az, el, 58, 92, 8, 46, 2.0)
    c = c + fill[..., None] * np.array([12.0, 11.7, 11.4])
    # long thin strip light low down: gives the bright lower rim
    return c

def refract(i, n, eta):
    cosi = -dot(n, i)
    k = 1 - eta * eta * (1 - cosi * cosi)
    t = eta * i + (eta * cosi - np.sqrt(np.clip(k, 0, None))) * n
    return norm(t), (k < 0)[..., 0]

def render(size, ss_=4):
    N = size * ss_
    u = (np.arange(N) + 0.5) / N * 2 - 1
    X, Y = np.meshgrid(u, -u)
    r2 = X * X + Y * Y
    inside = r2 < 1
    Z = np.sqrt(np.clip(1 - r2, 0, 1))
    n = np.dstack([X, Y, Z])
    d = np.zeros_like(n); d[..., 2] = -1
    # reflection with Fresnel (Schlick, glass)
    r = d - 2 * dot(d, n) * n
    cos = np.clip(Z, 0, 1)[..., None]
    F = 0.05 + 0.95 * (1 - cos) ** 5
    refl = env(r)
    # refraction through the ball
    t1, _ = refract(d, n, 1 / 1.5)
    s = -2 * dot(n, t1)                        # chord length (unit sphere)
    p2 = n + t1 * s
    t2, tir = refract(t1, -p2, 1.5)
    t2 = np.where(tir[..., None], t1 - 2 * dot(t1, -p2) * (-p2), t2)
    trans = env(t2)
    # terracotta glass: absorption by path length, plus light scattered in the body
    sigma = -np.log(np.clip(T, 1e-3, 1)) * 0.95
    absorb = np.exp(-sigma * s)
    key_dir = norm(np.array([-0.55, 0.62, 0.55]))
    lit = np.clip(dot(n, key_dir), 0, 1)
    body = T * (0.62 + 0.25 * lit + 0.30 * ss(-0.2, 0.8, -Y)[..., None])  # glows low, like light pooling
    # caustic: the key light focused to the lower right inside the ball
    cx, cy = 0.30, -0.42
    caus = np.exp(-(((X - cx) / 0.30) ** 2 + ((Y - cy) / 0.20) ** 2))[..., None]
    body = body + caus * np.array([1.0, 0.78, 0.6]) * 0.8
    inner = 0.62 * body + 0.38 * trans * absorb * 1.1
    col = F * refl + (1 - F) * inner
    # tone map: soft shoulder so highlights stay white without banding
    col = 1 - np.exp(-col * 1.35)
    col = col / (1 - np.exp(-1.35))
    col = np.clip(col, 0, 1)
    # edge alpha: exact circle, antialiased
    rr = np.sqrt(r2)
    alpha = np.clip((1 - rr) * N / 2 + 0.5, 0, 1)
    img = np.dstack([col * alpha[..., None], alpha])    # premultiplied for downsampling
    img = img.reshape(size, ss_, size, ss_, 4).mean(axis=(1, 3))
    a = img[..., 3:4]
    rgb = np.where(a > 0, img[..., :3] / np.maximum(a, 1e-6), 0)
    return np.dstack([rgb, a[..., 0]])

if __name__ == "__main__":
    import sys
    from PIL import Image
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 800
    o = render(size)
    Image.fromarray((np.clip(o, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(sys.argv[1])
