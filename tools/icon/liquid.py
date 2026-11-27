"""Render the speech bubble as clear Liquid Glass over the back layer (visionOS middle layer).

blender -b -P tools/icon/liquid.py -- BACK.png OUT.png [SAMPLES] [RES] [PARAMS.json]
Thick, pillowy clear glass with chromatic dispersion; it refracts BACK.png, which sits
behind it exactly where the back layer will be, so the layers line up.
"""
import bpy, json, math, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
BACK, OUT = argv[0], argv[1]
SAMPLES = int(argv[2]) if len(argv) > 2 else 512
RES = int(argv[3]) if len(argv) > 3 else 1024
Q = json.load(open(argv[4])) if len(argv) > 4 else {}

S, OY = 0.84, 473.3
def P(px, py):
    return ((px - 512) * S / 100 + Q.get("dx", 0), -(py - OY) * S / 100 + Q.get("dy", 0))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- outline (bubble.svg path), corners rounded by corner cutting
def arc(cx, cy, r, a0, a1, n=96):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]
def line(p, q, n=40):
    return [(p[0] + (q[0] - p[0]) * i / n, p[1] + (q[1] - p[1]) * i / n) for i in range(n)]
pts = []
pts += arc(332, 362, 166, 180, 270)
pts += line((332, 196), (692, 196))
pts += arc(692, 362, 166, 270, 360)
pts += line((858, 362), (858, 556))
pts += arc(692, 556, 166, 0, 90)
pts += line((692, 722), (452, 722)) + line((452, 722), (268, 868)) 
a_start = math.degrees(math.atan2(718.9 - 556, 300 - 332))
pts += line((268, 868), (300, 718.9))
pts += arc(332, 556, 166, a_start, 180)
pts += line((166, 556), (166, 362))
def fillet(pts, corner, r, n=24):
    """replace the path within r (in px of path length) of the point nearest `corner` by a smooth curve"""
    i = min(range(len(pts)), key=lambda k: math.dist(pts[k], corner))
    def walk(step):
        k, acc = i, 0.0
        while acc < r:
            k2 = (k + step) % len(pts); acc += math.dist(pts[k], pts[k2]); k = k2
        return k
    a_, b_ = walk(-1), walk(1)
    A, C, B = pts[a_], pts[i], pts[b_]
    curve_ = [((1-t)**2*A[0]+2*(1-t)*t*C[0]+t*t*B[0], (1-t)**2*A[1]+2*(1-t)*t*C[1]+t*t*B[1]) for t in [j/n for j in range(n+1)]]
    if a_ < b_:
        return pts[:a_] + curve_ + pts[b_ + 1:]
    return curve_ + pts[b_ + 1:a_]
for c, r in Q.get("fillets", [((452, 722), 60), ((268, 868), 30), ((300, 718.9), 60)]):
    pts = fillet(pts, c, r)
for _ in range(Q.get("chaikin", 2)):
    n = len(pts); out = []
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        out += [(0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]), (0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1])]
    pts = out
outline = [P(x, y) for x, y in pts]

curve = bpy.data.curves.new("bubble", "CURVE")
curve.dimensions = "2D"
curve.fill_mode = "BOTH"
curve.extrude = Q.get("extrude", 0.10)
curve.bevel_depth = Q.get("bevel", 0.30)
curve.bevel_resolution = 24
curve.offset = Q.get("offset", -0.0)
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
bpy.ops.object.shade_smooth()
bubble.scale.z = Q.get("puff", 1.0)          # >1 makes the edge roll over more steeply

m = bpy.data.materials.new("liquid glass")
m.use_nodes = True
b = m.node_tree.nodes["Principled BSDF"]
b.inputs["Base Color"].default_value = tuple(Q.get("tint", [1, 1, 1])) + (1,)
b.inputs["Transmission Weight"].default_value = 1.0
b.inputs["Roughness"].default_value = Q.get("rough", 0.0)
b.inputs["IOR"].default_value = Q.get("ior", 1.5)
b.inputs["Transmission Dispersion Scale"].default_value = Q.get("dispersion", 1.0)
b.inputs["Transmission Dispersion Abbe Number"].default_value = Q.get("abbe", 20)
bubble.data.materials.append(m)
bubble_only = bpy.data.collections.new("bubble only")
bubble_only.objects.link(bubble)

# ---------- the back layer, seen only through the glass, aligned 1:1 with the camera frame
FRAME = 10.24
bpy.ops.mesh.primitive_plane_add(size=FRAME, location=(0, 0, -Q.get("depth", 0.8)))
bk = bpy.context.active_object
bk.scale = (3, 3, 1)
bm = bpy.data.materials.new("back"); bm.use_nodes = True
nt = bm.node_tree; nt.nodes.remove(nt.nodes["Principled BSDF"])
tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = bpy.data.images.load(BACK); tex.extension = "EXTEND"
mp = nt.nodes.new("ShaderNodeMapping")
mp.inputs["Scale"].default_value = (3, 3, 1); mp.inputs["Location"].default_value = (-1, -1, 0)
tc = nt.nodes.new("ShaderNodeTexCoord")
nt.links.new(tc.outputs["UV"], mp.inputs["Vector"]); nt.links.new(mp.outputs[0], tex.inputs["Vector"])
em = nt.nodes.new("ShaderNodeEmission"); em.inputs["Strength"].default_value = 1.0
nt.links.new(tex.outputs["Color"], em.inputs["Color"])
nt.links.new(em.outputs[0], nt.nodes["Material Output"].inputs["Surface"])
bk.data.materials.append(bm)
bk.visible_camera = False; bk.visible_diffuse = False; bk.visible_shadow = False
bk.visible_glossy = Q.get("back_in_reflections", False)

# ---------- reflections: dark world, a few feathered panels for the rim highlights
world = bpy.data.worlds.new("w"); world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = tuple(Q.get("world", [0.02, 0.015, 0.013])) + (1,)
if Q.get("horizon"):
    # light only near the horizon: the flat face (looking up) sees black, the rolled edge
    # looks sideways and catches it, splitting it into a rainbow through the dispersion
    wn = world.node_tree
    wtc = wn.nodes.new("ShaderNodeTexCoord"); wsx = wn.nodes.new("ShaderNodeSeparateXYZ")
    wn.links.new(wtc.outputs["Generated"], wsx.inputs[0])
    wab = wn.nodes.new("ShaderNodeMath"); wab.operation = "ABSOLUTE"
    wsub = wn.nodes.new("ShaderNodeMath"); wsub.operation = "SUBTRACT"; wsub.inputs[0].default_value = 1.0
    wpw = wn.nodes.new("ShaderNodeMath"); wpw.operation = "POWER"; wpw.inputs[1].default_value = Q.get("horizon_pow", 8)
    wn.links.new(wsx.outputs["Z"], wab.inputs[0]); wn.links.new(wab.outputs[0], wsub.inputs[1]); wn.links.new(wsub.outputs[0], wpw.inputs[0])
    bg = wn.nodes["Background"]
    wn.links.new(wpw.outputs[0], bg.inputs["Strength"])
    bg.inputs["Color"].default_value = (Q["horizon"],) * 3 + (1,)
if Q.get("rainbow"):
    # a spectrum around the horizon (hue follows the compass direction), added to the world;
    # the rim, facing every way around the bubble, picks up a different hue all the way round
    wn = world.node_tree
    tc2 = wn.nodes.new("ShaderNodeTexCoord"); sx2 = wn.nodes.new("ShaderNodeSeparateXYZ")
    wn.links.new(tc2.outputs["Generated"], sx2.inputs[0])
    at = wn.nodes.new("ShaderNodeMath"); at.operation = "ARCTAN2"
    wn.links.new(sx2.outputs["Y"], at.inputs[0]); wn.links.new(sx2.outputs["X"], at.inputs[1])
    hu = wn.nodes.new("ShaderNodeMath"); hu.operation = "MULTIPLY_ADD"
    hu.inputs[1].default_value = 1 / (2 * math.pi); hu.inputs[2].default_value = 0.5 + Q.get("rainbow_phase", 0.0)
    wn.links.new(at.outputs[0], hu.inputs[0])
    hsv = wn.nodes.new("ShaderNodeCombineColor"); hsv.mode = "HSV"
    wn.links.new(hu.outputs[0], hsv.inputs[0]); hsv.inputs[1].default_value = Q.get("rainbow_sat", 1.0); hsv.inputs[2].default_value = 1.0
    ab2 = wn.nodes.new("ShaderNodeMath"); ab2.operation = "ABSOLUTE"
    sb2 = wn.nodes.new("ShaderNodeMath"); sb2.operation = "SUBTRACT"; sb2.inputs[0].default_value = 1.0
    pw2 = wn.nodes.new("ShaderNodeMath"); pw2.operation = "POWER"; pw2.inputs[1].default_value = Q.get("rainbow_pow", 6)
    wn.links.new(sx2.outputs["Z"], ab2.inputs[0]); wn.links.new(ab2.outputs[0], sb2.inputs[1]); wn.links.new(sb2.outputs[0], pw2.inputs[0])
    em2 = wn.nodes.new("ShaderNodeEmission")
    wn.links.new(hsv.outputs[0], em2.inputs["Color"])
    sc2 = wn.nodes.new("ShaderNodeMath"); sc2.operation = "MULTIPLY"; sc2.inputs[1].default_value = Q["rainbow"]
    wn.links.new(pw2.outputs[0], sc2.inputs[0]); wn.links.new(sc2.outputs[0], em2.inputs["Strength"])
    add = wn.nodes.new("ShaderNodeAddShader")
    out = wn.nodes["World Output"]; bg_ = wn.nodes["Background"]
    wn.links.new(bg_.outputs[0], add.inputs[0]); wn.links.new(em2.outputs[0], add.inputs[1])
    wn.links.new(add.outputs[0], out.inputs["Surface"])
scene.world = world
def panel(loc, size, strength, colour=(1, 1, 1)):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    o = bpy.context.active_object; o.scale = (size[0], size[1], 1)
    o.rotation_euler = (Vector((0, 0, 0)) - o.location).to_track_quat("Z", "Y").to_euler()
    e = bpy.data.materials.new("panel"); e.use_nodes = True; n = e.node_tree
    n.nodes.remove(n.nodes["Principled BSDF"])
    es = n.nodes.new("ShaderNodeEmission"); es.inputs["Color"].default_value = tuple(colour) + (1,)
    t = n.nodes.new("ShaderNodeTexCoord"); sx = n.nodes.new("ShaderNodeSeparateXYZ")
    n.links.new(t.outputs["UV"], sx.inputs[0])
    def edge(o_):
        pp = n.nodes.new("ShaderNodeMath"); pp.operation = "PINGPONG"; pp.inputs[1].default_value = 0.5
        n.links.new(o_, pp.inputs[0]); return pp.outputs[0]
    mn = n.nodes.new("ShaderNodeMath"); mn.operation = "MINIMUM"
    n.links.new(edge(sx.outputs["X"]), mn.inputs[0]); n.links.new(edge(sx.outputs["Y"]), mn.inputs[1])
    mr = n.nodes.new("ShaderNodeMapRange"); mr.interpolation_type = "SMOOTHSTEP"; mr.inputs["From Max"].default_value = 0.5
    n.links.new(mn.outputs[0], mr.inputs["Value"])
    sc = n.nodes.new("ShaderNodeMath"); sc.operation = "MULTIPLY"; sc.inputs[1].default_value = strength
    n.links.new(mr.outputs["Result"], sc.inputs[0]); n.links.new(sc.outputs[0], es.inputs["Strength"])
    n.links.new(es.outputs[0], n.nodes["Material Output"].inputs["Surface"])
    o.data.materials.append(e)
    o.visible_camera = False; o.visible_diffuse = False; o.visible_shadow = False
    o.light_linking.receiver_collection = bubble_only
for pl in Q.get("panels", [[[-5, 6, 6], [14, 5], 6.0], [[6, -4, 5], [10, 4], 2.0]]):
    panel(*pl)

cam = bpy.data.cameras.new("cam"); cam.type = "ORTHO"; cam.ortho_scale = FRAME
co = bpy.data.objects.new("cam", cam); co.location = (0, 0, 30)
scene.collection.objects.link(co); scene.camera = co

scene.render.engine = "CYCLES"
scene.cycles.device = "GPU"
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"; prefs.get_devices()
for d in prefs.devices: d.use = True
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.cycles.max_bounces = scene.cycles.transmission_bounces = 24
scene.render.resolution_x = scene.render.resolution_y = RES
scene.render.film_transparent = True
scene.cycles.film_transparent_glass = False
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.image_settings.color_depth = "16"
scene.view_settings.view_transform = "Standard"     # glass shows the back layer exactly as drawn
scene.view_settings.look = "None"
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
