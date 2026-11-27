"""Render a procedural seascape as an equirectangular panorama, used to light the orb.

blender -b -P tools/icon/seascape.py -- OUT.exr [WIDTH] [SAMPLES] [PARAMS.json]
Physical sky with a low sun over a wind-blown ocean; Z is up.
"""
import bpy, json, math, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = argv[0]
W = int(argv[1]) if len(argv) > 1 else 4096
SAMPLES = int(argv[2]) if len(argv) > 2 else 128
P = json.load(open(argv[3])) if len(argv) > 3 else {}

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

world = bpy.data.worlds.new("sky")
world.use_nodes = True
wn = world.node_tree.nodes
sky = wn.new("ShaderNodeTexSky")
sky.sky_type = "MULTIPLE_SCATTERING"
sky.sun_elevation = math.radians(P.get("sun_elev", 6))
sky.sun_rotation = math.radians(P.get("sun_rot", 0))
sky.sun_intensity = P.get("sun_int", 1.0)
sky.sun_size = math.radians(P.get("sun_size", 1.0))
sky.aerosol_density = P.get("haze", 1.0)
sky.air_density = P.get("air", 1.0)
world.node_tree.links.new(sky.outputs["Color"], wn["Background"].inputs["Color"])
wn["Background"].inputs["Strength"].default_value = P.get("sky_strength", 1.0)
scene.world = world

bpy.ops.mesh.primitive_plane_add(size=2, location=(0, 0, 0))
sea = bpy.context.active_object
oc = sea.modifiers.new("ocean", "OCEAN")
oc.geometry_mode = "GENERATE"
oc.size = P.get("size", 1.0)
oc.spatial_size = P.get("spatial", 60)
oc.repeat_x = oc.repeat_y = P.get("repeat", 40)
oc.resolution = P.get("res", 16)
oc.wave_scale = P.get("wave", 1.0)
oc.choppiness = P.get("chop", 1.0)
oc.wind_velocity = P.get("wind", 10)
oc.random_seed = P.get("seed", 3)
bpy.ops.object.shade_smooth()
# centre the tiled ocean under the camera
span = oc.spatial_size * oc.repeat_x
sea.location = (-span / 2, -span / 2, 0)
wm = bpy.data.materials.new("water")
wm.use_nodes = True
wb = wm.node_tree.nodes["Principled BSDF"]
wb.inputs["Base Color"].default_value = P.get("water", [0.0, 0.015, 0.03]) + [1]
wb.inputs["Roughness"].default_value = P.get("rough", 0.03)
wb.inputs["IOR"].default_value = 1.33
sea.data.materials.append(wm)

cam = bpy.data.cameras.new("pano")
cam.type = "PANO"
cam.panorama_type = "EQUIRECTANGULAR"
co = bpy.data.objects.new("pano", cam)
co.location = (0, 0, P.get("height", 2.0))
co.rotation_euler = (math.radians(90), 0, math.radians(P.get("yaw", 0)))
scene.collection.objects.link(co)
scene.camera = co

scene.render.engine = "CYCLES"
scene.cycles.device = "GPU"
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"
prefs.get_devices()
for d in prefs.devices:
    d.use = True
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.render.resolution_x = W
scene.render.resolution_y = W // 2
if OUT.endswith(".exr"):
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_depth = "32"
else:
    scene.render.image_settings.file_format = "PNG"
    scene.view_settings.view_transform = "AgX"
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
