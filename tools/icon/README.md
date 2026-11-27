# visionOS icon layers

`Icon/Assets.xcassets/AppIcon.solidimagestack` has three layers, each 1024x1024:

- **Back**: `python back.py back.png back-final.json` draws the dark warm background with the orb's glow.
- **Middle**: `blender -b -P liquid.py -- back.png middle.png 1024 1024 bubble-final.json` renders the speech bubble as clear glass. It refracts `back.png`, so render the back first.
- **Front**: the terracotta glass orb, 144 px across, centred at (512, 500). `blender -b -P orb_scene.py -- orb-final.json orb.png 1024 1024` renders it at full size. Then crop the orb to its edge and scale it to 144 px.

`orb-final.json` refers to two images that aren't in the repo:

- `build/sea.exr`, a sea panorama. Make it with `blender -b -P seascape.py -- build/sea.exr`.
- `build/orb-backdrop.png`, the beach scene seen inside the orb.

`orb_colour.py` checks a render's main colour against #D97757. `scene.py`, `glass.py` and `orb3d.py` made earlier versions of the icon.

The Python scripts need NumPy and Pillow, and `back.py` also needs ImageMagick. The iPhone icon is `Icon/Parley.icon`; edit it in Icon Composer.
