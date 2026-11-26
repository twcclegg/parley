# visionOS icon layers

- `glass.py OUT_DIR` draws the bubble (`middle.png`) from signed distance fields: bevelled white glass with a rainbow edge.
- `orb3d.py OUT.png SIZE` ray-traces the orb: terracotta glass (#D97757) with Fresnel reflections of two softboxes, refraction and a caustic.

Needs Python with NumPy and Pillow. The iPhone icon is `Icon/Parley.icon`; edit it in Icon Composer.
