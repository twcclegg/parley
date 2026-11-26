"""Blender scene for Parley's visionOS icon layers.

blender -b -P tools/icon/scene.py -- OUT_DIR [SAMPLES]
Renders OUT_DIR/middle.png (glass bubble), OUT_DIR/front.png (orb) and OUT_DIR/all.png
(both, for previews), each 1024x1024 with a transparent background.
"""
import bpy, math, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = argv[0]
SAMPLES = int(argv[1]) if len(argv) > 1 else 384
RES = int(argv[2]) if len(argv) > 2 else 1024
ROT_X, ROT_Z, HDRI_STRENGTH = 70, 140, 1.6

S = 0.84                      # icon scale of the original 1024-point artwork
OY = 473.3                    # artwork y that lands at the icon's centre
def P(px, py):                # artwork point -> Blender units (100 px = 1 unit), y up
    return ((px - 512) * S / 100, -(py - OY) * S / 100)

def srgb(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple((v / 12.92) if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c) + (1,)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- bubble outline (same path as Icon/Parley.icon/Assets/bubble.svg)
def arc(cx, cy, r, a0, a1, n=24):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]
pts = []
pts += arc(332, 362, 166, 180, 270)            # top left
pts += arc(692, 362, 166, 270, 360)            # top right
pts += arc(692, 556, 166, 0, 90)               # bottom right
pts += [(452, 722), (268, 868)]                # tail
a_start = math.degrees(math.atan2(718.9 - 556, 300 - 332))
pts += arc(332, 556, 166, a_start, 180)        # bottom left, from where the tail rejoins
outline = [P(x, y) for x, y in pts]

curve = bpy.data.curves.new("bubble", "CURVE")
curve.dimensions = "2D"
curve.fill_mode = "BOTH"
curve.extrude = 0.035
curve.bevel_depth = 0.11                     # a thin, rounded glass edge
curve.bevel_resolution = 10
sp = curve.splines.new("POLY")
sp.points.add(len(outline) - 1)
for p, (x, y) in zip(sp.points, outline):
    p.co = (x, y, 0, 1)
sp.use_cyclic_u = True
bubble = bpy.data.objects.new("bubble", curve)
scene.collection.objects.link(bubble)
bpy.context.view_layer.objects.active = bubble
bubble.select_set(True)
bpy.ops.object.convert(target="MESH")
bubble = bpy.context.active_object
bpy.ops.object.shade_auto_smooth(angle=math.radians(50))

m = bpy.data.materials.new("smoked glass")
m.use_nodes = True
b = m.node_tree.nodes["Principled BSDF"]
b.inputs["Base Color"].default_value = (1, 1, 1, 1)
b.inputs["Transmission Weight"].default_value = 1.0
b.inputs["Roughness"].default_value = 0.0
b.inputs["IOR"].default_value = 1.5
b.inputs["Thin Film Thickness"].default_value = 0.0
b.inputs["Thin Film IOR"].default_value = 1.33
# a faint smoky tint inside
smoke = m.node_tree.nodes.new("ShaderNodeVolumeAbsorption")
smoke.inputs["Color"].default_value = (0.55, 0.55, 0.57, 1)
smoke.inputs["Density"].default_value = 4.0
m.node_tree.links.new(smoke.outputs[0], m.node_tree.nodes["Material Output"].inputs["Volume"])
bubble.data.materials.append(m)

# ---------- orb: terracotta glass
R = 64 * S / 100
cx, cy = P(512, 459)
top = curve.extrude + curve.bevel_depth
bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=R, location=(cx, cy, top + R + 0.02))
orb = bpy.context.active_object
bpy.ops.object.shade_smooth()
om = bpy.data.materials.new("terracotta glass")
om.use_nodes = True
ob = om.node_tree.nodes["Principled BSDF"]
T = srgb("D97757")
ob.inputs["Base Color"].default_value = tuple(c ** 0.8 for c in T[:3]) + (1,)   # light passes through twice
ob.inputs["Transmission Weight"].default_value = 1.0
ob.inputs["Roughness"].default_value = 0.0
ob.inputs["IOR"].default_value = 1.52
absorb = om.node_tree.nodes.new("ShaderNodeVolumeAbsorption")
absorb.inputs["Color"].default_value = T
absorb.inputs["Density"].default_value = 0.3
om.node_tree.links.new(absorb.outputs[0], om.node_tree.nodes["Material Output"].inputs["Volume"])
orb.data.materials.append(om)

# ---------- studio: Blender's bundled interior HDRI (windows) for reflections and light
import glob
hdri = glob.glob(bpy.utils.resource_path("LOCAL") + "/datafiles/studiolights/world/interior.exr")[0]
world = bpy.data.worlds.new("world")
world.use_nodes = True
wn = world.node_tree.nodes
env = wn.new("ShaderNodeTexEnvironment")
env.image = bpy.data.images.load(hdri)
mapping = wn.new("ShaderNodeMapping")
coord = wn.new("ShaderNodeTexCoord")
mapping.inputs["Rotation"].default_value = (math.radians(ROT_X), 0, math.radians(ROT_Z))
world.node_tree.links.new(coord.outputs["Generated"], mapping.inputs["Vector"])
world.node_tree.links.new(mapping.outputs[0], env.inputs["Vector"])
world.node_tree.links.new(env.outputs[0], wn["Background"].inputs["Color"])
wn["Background"].inputs["Strength"].default_value = HDRI_STRENGTH
scene.world = world

# window-shaped softboxes, seen only in reflections, for crisp highlights on the glass
orb_only = bpy.data.collections.new("orb only")
orb_only.objects.link(orb)
bubble_only = bpy.data.collections.new("bubble only")
bubble_only.objects.link(bubble)
def softbox(name, size, loc, strength, receivers=None, aim=None):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    o = bpy.context.active_object
    o.scale = (size[0], size[1], 1)
    target = Vector(aim) if aim else Vector((cx, cy, top + R))
    o.rotation_euler = (target - o.location).to_track_quat("Z", "Y").to_euler()
    e = bpy.data.materials.new(name)
    e.use_nodes = True
    nt = e.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = strength
    nt.links.new(em.outputs[0], nt.nodes["Material Output"].inputs["Surface"])
    o.data.materials.append(e)
    o.visible_camera = False
    o.visible_diffuse = False
    o.visible_shadow = False
    # light only the orb, so the softboxes don't throw shapes onto the bubble
    o.light_linking.receiver_collection = receivers or orb_only
    return o
# panes either side of a frame bar, upper left; a smaller one upper right
softbox("key a", (1.6, 3.6), (-2.5, 2.4, 2.8), 30)
softbox("key b", (1.6, 3.6), (-0.8, 2.9, 3.1), 30)
softbox("fill", (1.6, 2.6), (2.6, 1.0, 2.4), 20)
# long bars around the bubble that its bevelled edge reflects: bright along the top, dim below
softbox("edge top", (16, 6), (0, 7.5, 6.0), 70, bubble_only, (0, 0, 0))
softbox("edge left", (16, 6), (-7.5, 0, 6.0), 45, bubble_only, (0, 0, 0))
softbox("edge right", (16, 6), (7.5, 0, 6.0), 25, bubble_only, (0, 0, 0))
sheen = softbox("sheen", (14, 14), (0, 0, 14.0), 1.0, bubble_only, (0, 0, 0))
sn = sheen.active_material.node_tree
grad = sn.nodes.new("ShaderNodeTexGradient")
ramp = sn.nodes.new("ShaderNodeValToRGB")
gtc = sn.nodes.new("ShaderNodeTexCoord")
gmap = sn.nodes.new("ShaderNodeMapping")
gmap.inputs["Rotation"].default_value = (0, 0, math.radians(90))
sn.links.new(gtc.outputs["Generated"], gmap.inputs["Vector"])
sn.links.new(gmap.outputs[0], grad.inputs["Vector"])
sn.links.new(grad.outputs["Fac"], ramp.inputs["Fac"])
ramp.color_ramp.elements[0].color = (0, 0, 0, 1)
ramp.color_ramp.elements[1].position = 0.75
ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
emis = [n for n in sn.nodes if n.type == "EMISSION"][0]
sn.links.new(ramp.outputs["Color"], emis.inputs["Color"])
emis.inputs["Strength"].default_value = 28.0
softbox("edge bottom", (16, 6), (0, -7.5, 6.0), 30, bubble_only, (0, 0, 0))

# a dark backing seen only through the glass: black above, a soft glow low down
bpy.ops.mesh.primitive_plane_add(size=9, location=(0, 0, -0.6))
back = bpy.context.active_object
bkm = bpy.data.materials.new("backing")
bkm.use_nodes = True
bk = bkm.node_tree
bk.nodes.remove(bk.nodes["Principled BSDF"])
bem = bk.nodes.new("ShaderNodeEmission")
btc = bk.nodes.new("ShaderNodeTexCoord")
bsep = bk.nodes.new("ShaderNodeSeparateXYZ")
bramp = bk.nodes.new("ShaderNodeValToRGB")
bk.links.new(btc.outputs["Generated"], bsep.inputs[0])
bk.links.new(bsep.outputs["Y"], bramp.inputs["Fac"])
bramp.color_ramp.interpolation = "EASE"
bramp.color_ramp.elements[0].position = 0.05
bramp.color_ramp.elements[0].color = (0.22, 0.215, 0.21, 1)
bramp.color_ramp.elements[1].position = 0.75
bramp.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1)
bk.links.new(bramp.outputs["Color"], bem.inputs["Color"])
bem.inputs["Strength"].default_value = 1.0
bk.links.new(bem.outputs[0], bk.nodes["Material Output"].inputs["Surface"])
back.data.materials.append(bkm)
back.visible_camera = False
back.visible_diffuse = False
back.visible_glossy = False
back.visible_shadow = False

# ---------- camera and render settings
cam = bpy.data.cameras.new("cam")
cam.type = "ORTHO"
cam.ortho_scale = 10.24
co = bpy.data.objects.new("cam", cam)
co.location = (0, 0, 30)
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
scene.cycles.max_bounces = 24
scene.cycles.transmission_bounces = 24
scene.cycles.volume_bounces = 4
scene.cycles.caustics_refractive = True
scene.cycles.caustics_reflective = True
scene.render.resolution_x = scene.render.resolution_y = RES
scene.render.film_transparent = True
scene.cycles.film_transparent_glass = False
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "None"

def render(name, show_bubble, show_orb):
    bubble.visible_camera = show_bubble
    orb.visible_camera = show_orb
    orb.hide_render = not show_orb and name == "middle"   # no orb caustics on the bubble layer
    scene.render.filepath = f"{OUT}/{name}.png"
    bpy.ops.render.render(write_still=True)

render("all", True, True)
render("middle", True, False)
render("front", False, True)
