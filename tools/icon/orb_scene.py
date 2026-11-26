"""Blender scene for the Parley orb, driven by a JSON file of parameters.

blender -b -P tools/icon/orb_scene.py -- PARAMS.json OUT.png [SIZE] [SAMPLES]
Renders the orb alone, on a transparent background.
"""
import bpy, json, math, sys, glob
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
P = json.load(open(argv[0]))
OUT = argv[1]
SIZE = int(argv[2]) if len(argv) > 2 else 640
SAMPLES = int(argv[3]) if len(argv) > 3 else 256

def lin(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [(v / 12.92) if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
T = lin(P.get("colour", "D97757"))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

bpy.ops.mesh.primitive_uv_sphere_add(segments=192, ring_count=96, radius=1.0)
orb = bpy.context.active_object
bpy.ops.object.shade_smooth()
m = bpy.data.materials.new("orb")
m.use_nodes = True
nt = m.node_tree
b = nt.nodes["Principled BSDF"]
b.inputs["Base Color"].default_value = [c ** P["base_exp"] for c in T] + [1]
b.inputs["Transmission Weight"].default_value = P["transmission"]
b.inputs["Roughness"].default_value = P["roughness"]
b.inputs["IOR"].default_value = P["ior"]
b.inputs["Transmission Dispersion Scale"].default_value = P.get("dispersion", 0.0)
b.inputs["Coat Weight"].default_value = P.get("coat", 0.0)
b.inputs["Coat Roughness"].default_value = 0.0
b.inputs["Subsurface Weight"].default_value = P.get("subsurface", 0.0)
b.inputs["Subsurface Radius"].default_value = (1.0, 0.4, 0.25)
b.inputs["Subsurface Scale"].default_value = P.get("subsurface_scale", 0.3)
vol = nt.nodes.new("ShaderNodeVolumePrincipled")
vol.inputs["Color"].default_value = [c ** P.get("scatter_exp", 1.0) for c in T] + [1]
vol.inputs["Density"].default_value = P["scatter"]
vol.inputs["Absorption Color"].default_value = [c ** P.get("absorb_exp", 1.0) for c in T] + [1]
vol.inputs["Emission Color"].default_value = T + [1]
vol.inputs["Emission Strength"].default_value = P["glow"]
nt.links.new(vol.outputs[0], nt.nodes["Material Output"].inputs["Volume"])
orb.data.materials.append(m)

orb_only = bpy.data.collections.new("orb only")
orb_only.objects.link(orb)

if P.get("mode") in ("sss", "glass"):
    # light-filled coloured glass: translucent body under a clear glass coat
    lk = nt.nodes["Material Output"].inputs["Volume"].links
    if lk: nt.links.remove(lk[0])
    b.inputs["Transmission Weight"].default_value = 0.0
    b.inputs["Base Color"].default_value = [c ** P.get("body_exp", 1.0) for c in T] + [1]
    b.inputs["Subsurface Weight"].default_value = 1.0
    b.inputs["Subsurface Radius"].default_value = tuple(P.get("sss_radius", [1.0, 0.45, 0.3]))
    b.inputs["Subsurface Scale"].default_value = P.get("sss_scale", 0.8)
    b.inputs["Roughness"].default_value = P.get("body_rough", 0.25)
    b.inputs["Coat Weight"].default_value = 1.0
    b.inputs["Coat Roughness"].default_value = 0.0
    b.inputs["Coat IOR"].default_value = P.get("coat_ior", 1.5)
    b.inputs["Emission Color"].default_value = T + [1]
    b.inputs["Emission Strength"].default_value = P.get("body_glow", 0.0)
    b.inputs["Specular IOR Level"].default_value = 0.0   # only the clear coat reflects: crisp, no halo
    if P.get("mode") == "glass":
        b.inputs["Transmission Weight"].default_value = 1.0
        b.inputs["Subsurface Weight"].default_value = 0.0
        b.inputs["Roughness"].default_value = 0.0
        b.inputs["Specular IOR Level"].default_value = 0.5
        b.inputs["Coat Weight"].default_value = 0.0
        ab = nt.nodes.new("ShaderNodeVolumeAbsorption")
        ab.inputs["Color"].default_value = P.get("absorb_rgb", [min(1.0, (c / max(T)) ** P.get("absorb_exp", 1.0)) for c in T]) + [1]   # red passes; green and blue are absorbed
        ab.inputs["Density"].default_value = P.get("absorb", 1.0)
        nt.links.new(ab.outputs[0], nt.nodes["Material Output"].inputs["Volume"])
    # deeper colour towards the edges, as thick glass is
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = P.get("edge_blend", 0.35)
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = [c ** P.get("body_exp", 1.0) for c in T] + [1]
    ramp.color_ramp.elements[0].position = P.get("edge_start", 0.0)
    ramp.color_ramp.elements[1].position = P.get("edge_pos", 0.85)
    ramp.color_ramp.elements[1].color = [c ** P.get("edge_exp", 2.2) for c in T] + [1]
    nt.links.new(lw.outputs["Facing"], ramp.inputs["Fac"])
    tcv = nt.nodes.new("ShaderNodeTexCoord")
    sepv = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tcv.outputs["Object"], sepv.inputs[0])
    vr = nt.nodes.new("ShaderNodeMapRange")
    vr.inputs["From Min"].default_value = -1
    vr.inputs["From Max"].default_value = 1
    vr.inputs["To Min"].default_value = 1.0
    vr.inputs["To Max"].default_value = P.get("top_dark", 1.0)
    nt.links.new(sepv.outputs["Y"], vr.inputs["Value"])
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(ramp.outputs["Color"], mul.inputs[6])
    nt.links.new(vr.outputs["Result"], mul.inputs[7])
    nt.links.new(mul.outputs[2], b.inputs["Base Color"])

    # light gathered inside the bottom: a crescent glow, plus a fine refracted line inside the edge
    def math_node(op, a=None, b_=None):
        n = nt.nodes.new("ShaderNodeMath"); n.operation = op
        if a is not None: n.inputs[0].default_value = a
        if b_ is not None: n.inputs[1].default_value = b_
        return n
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    # crescent: low on the ball (y < ...) and towards its outer part, seen face-on
    low = nt.nodes.new("ShaderNodeMapRange")
    low.inputs["From Min"].default_value = -P.get("cres_top", 0.35)
    low.inputs["From Max"].default_value = -P.get("cres_bottom", 0.85)
    nt.links.new(sep.outputs["Y"], low.inputs["Value"])
    xoff = math_node("SUBTRACT", None, P.get("cres_x", 0.0))
    nt.links.new(sep.outputs["X"], xoff.inputs[0])
    xs = math_node("ABSOLUTE")
    nt.links.new(xoff.outputs[0], xs.inputs[0])
    narrow = nt.nodes.new("ShaderNodeMapRange")
    narrow.inputs["From Min"].default_value = P.get("cres_half_width", 0.55)
    narrow.inputs["From Max"].default_value = 0.0
    nt.links.new(xs.outputs[0], narrow.inputs["Value"])
    cres = math_node("MULTIPLY")
    nt.links.new(low.outputs["Result"], cres.inputs[0])
    nt.links.new(narrow.outputs["Result"], cres.inputs[1])
    cpow = math_node("POWER", None, P.get("cres_sharp", 2.0))
    nt.links.new(cres.outputs[0], cpow.inputs[0])
    cstr = math_node("MULTIPLY", None, P.get("cres_glow", 3.0))
    nt.links.new(cpow.outputs[0], cstr.inputs[0])
    # refracted line just inside the silhouette
    lw2 = nt.nodes.new("ShaderNodeLayerWeight")
    lw2.inputs["Blend"].default_value = 0.5
    band = nt.nodes.new("ShaderNodeMapRange")
    band.interpolation_type = "SMOOTHSTEP"
    lo, hi = P.get("line_pos", 0.80), P.get("line_pos", 0.80) + P.get("line_width", 0.05)
    band.inputs["From Min"].default_value = lo
    band.inputs["From Max"].default_value = hi
    nt.links.new(lw2.outputs["Facing"], band.inputs["Value"])
    band2 = nt.nodes.new("ShaderNodeMapRange")
    band2.interpolation_type = "SMOOTHSTEP"
    band2.inputs["From Min"].default_value = hi + P.get("line_width", 0.05)
    band2.inputs["From Max"].default_value = hi
    nt.links.new(lw2.outputs["Facing"], band2.inputs["Value"])
    line = math_node("MULTIPLY")
    nt.links.new(band.outputs["Result"], line.inputs[0])
    nt.links.new(band2.outputs["Result"], line.inputs[1])
    lstr = math_node("MULTIPLY", None, P.get("line_glow", 1.5))
    nt.links.new(line.outputs[0], lstr.inputs[0])
    total = math_node("ADD")
    nt.links.new(cstr.outputs[0], total.inputs[0])
    nt.links.new(lstr.outputs[0], total.inputs[1])
    amber = [min(1.0, c ** P.get("glow_exp", 0.6)) for c in T]
    b.inputs["Emission Color"].default_value = amber + [1]
    nt.links.new(total.outputs[0], b.inputs["Emission Strength"])

# a solid terracotta core inside clear glass, like a paperweight
if P.get("core", 0) > 0:
    nt.nodes["Material Output"].inputs["Volume"].links and nt.links.remove(nt.nodes["Material Output"].inputs["Volume"].links[0])
    b.inputs["Base Color"].default_value = [c ** P.get("shell_tint", 0.08) for c in T] + [1]
    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=P["core"])
    core = bpy.context.active_object
    bpy.ops.object.shade_smooth()
    cm = bpy.data.materials.new("core")
    cm.use_nodes = True
    cb = cm.node_tree.nodes["Principled BSDF"]
    cb.inputs["Base Color"].default_value = [c ** P.get("core_exp", 1.0) for c in T] + [1]
    cb.inputs["Roughness"].default_value = P.get("core_rough", 0.35)
    cb.inputs["Subsurface Weight"].default_value = P.get("core_sss", 0.5)
    cb.inputs["Subsurface Radius"].default_value = (1.0, 0.35, 0.2)
    cb.inputs["Subsurface Scale"].default_value = 0.2
    cb.inputs["Emission Color"].default_value = T + [1]
    cb.inputs["Emission Strength"].default_value = P.get("core_glow", 0.2)
    core.data.materials.append(cm)
    orb_only.objects.link(core)

def emitter(name, size, loc, strength, colour=(1, 1, 1), reflect_only=False):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    o = bpy.context.active_object
    o.scale = (size[0], size[1], 1)
    o.rotation_euler = (Vector((0, 0, 0)) - o.location).to_track_quat("Z", "Y").to_euler()
    e = bpy.data.materials.new(name)
    e.use_nodes = True
    n = e.node_tree
    n.nodes.remove(n.nodes["Principled BSDF"])
    em = n.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = list(colour) + [1]
    em.inputs["Strength"].default_value = strength
    n.links.new(em.outputs[0], n.nodes["Material Output"].inputs["Surface"])
    o.data.materials.append(e)
    o.visible_camera = False
    o.light_linking.receiver_collection = orb_only
    if reflect_only:
        # seen in reflections only: doesn't light the body
        e.cycles.emission_sampling = "NONE"
        o.visible_diffuse = False
        o.visible_transmission = False
        o.visible_volume_scatter = False
    return o

# windows: [x, y, z, width, height, strength]; a frame bar splits each when "bar" is set
for w in P["windows"]:
    x, y, z, wd, ht, st = w[:6]
    if len(w) > 6 and w[6] == 4:
        gx, gy = wd * 0.05, ht * 0.05
        pw, ph = (wd - gx) / 2, (ht - gy) / 2
        o = Vector((x, y, z))
        fwd = (-o).normalized()
        right = fwd.cross(Vector((0, 0, 1))).normalized()
        up = right.cross(fwd).normalized()
        for sx in (-1, 1):
            for sy in (-1, 1):
                c = o + right * sx * (pw + gx) / 2 + up * sy * (ph + gy) / 2
                emitter("pane", (pw, ph), tuple(c), st, reflect_only=True)
    elif len(w) > 6 and w[6]:
        gap = wd * 0.04
        half = (wd - gap) / 2
        right = Vector((y, -x, 0)).normalized() if (x or y) else Vector((1, 0, 0))
        for sgn in (-1, 1):
            off = right * sgn * (half + gap) / 2
            emitter("pane", (half, ht), (x + off.x, y + off.y, z), st, reflect_only=True)
    else:
        emitter("window", (wd, ht), (x, y, z), st, reflect_only=True)

# a bright floor under the orb: gives the lit base and the reflected ring at the bottom
if P.get("floor", 0) > 0:
    emitter("floor", (8, 8), (0, -1.6, -2.2), P["floor"], (1.0, 0.95, 0.9))

if P.get("ring", 0) > 0:
    bpy.ops.mesh.primitive_cylinder_add(vertices=128, radius=6.0, depth=P.get("ring_depth", 1.0), end_fill_type="NOTHING", location=(0, 0, P.get("ring_z", -0.6)))
    rg = bpy.context.active_object
    rmat = bpy.data.materials.new("ring")
    rmat.use_nodes = True
    rn = rmat.node_tree
    rn.nodes.remove(rn.nodes["Principled BSDF"])
    rem = rn.nodes.new("ShaderNodeEmission")
    rem.inputs["Strength"].default_value = P["ring"]
    rn.links.new(rem.outputs[0], rn.nodes["Material Output"].inputs["Surface"])
    rg.data.materials.append(rmat)
    rg.visible_camera = False
    rg.light_linking.receiver_collection = orb_only

# extra lights: [x, y, z, width, height, strength]; they light the orb but aren't seen in it
for e in P.get("lights", []):
    lo = emitter("light", (e[3], e[4]), (e[0], e[1], e[2]), e[5])
    lo.visible_glossy = False
    lo.visible_transmission = False

# small, very bright point lights seen only as sharp specular pinpoints: [x, y, z, radius, strength]
for px_, py_, pz_, pr, pst in P.get("pins", []):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=pr, location=(px_, py_, pz_))
    po = bpy.context.active_object
    pm = bpy.data.materials.new("pin")
    pm.use_nodes = True
    pnt = pm.node_tree
    pnt.nodes.remove(pnt.nodes["Principled BSDF"])
    pe = pnt.nodes.new("ShaderNodeEmission")
    pe.inputs["Strength"].default_value = pst
    pnt.links.new(pe.outputs[0], pnt.nodes["Material Output"].inputs["Surface"])
    pm.cycles.emission_sampling = "NONE"
    po.data.materials.append(pm)
    po.visible_camera = False
    po.visible_diffuse = False
    po.visible_transmission = False

# curved windows: sections of a cylinder around the camera axis, so they reflect as arcs
# [angle_from_deg, angle_to_deg, z_from, z_to, radius, strength]
import bmesh
for a0, a1, z0, z1, rad, st in P.get("arcs", []):
    me = bpy.data.meshes.new("arc")
    bm = bmesh.new()
    n = 48
    verts = []
    for i in range(n + 1):
        a = math.radians(a0 + (a1 - a0) * i / n)
        verts.append((bm.verts.new((rad * math.cos(a), rad * math.sin(a), z0)),
                      bm.verts.new((rad * math.cos(a), rad * math.sin(a), z1))))
    for i in range(n):
        bm.faces.new((verts[i][0], verts[i + 1][0], verts[i + 1][1], verts[i][1]))
    bm.to_mesh(me); bm.free()
    ao = bpy.data.objects.new("arc", me)
    scene.collection.objects.link(ao)
    am = bpy.data.materials.new("arc")
    am.use_nodes = True
    an = am.node_tree
    an.nodes.remove(an.nodes["Principled BSDF"])
    aem = an.nodes.new("ShaderNodeEmission")
    aem.inputs["Strength"].default_value = st
    an.links.new(aem.outputs[0], an.nodes["Material Output"].inputs["Surface"])
    if P.get("arc_fade", 0) > 0:
        atc = an.nodes.new("ShaderNodeTexCoord")
        asep = an.nodes.new("ShaderNodeSeparateXYZ")
        an.links.new(atc.outputs["Object"], asep.inputs[0])
        amr = an.nodes.new("ShaderNodeMapRange")
        amr.inputs["From Min"].default_value = z0
        amr.inputs["From Max"].default_value = z1
        amr.inputs["To Min"].default_value = st
        amr.inputs["To Max"].default_value = st * (1 - P["arc_fade"])
        an.links.new(asep.outputs["Z"], amr.inputs["Value"])
        an.links.new(amr.outputs["Result"], aem.inputs["Strength"])
    am.cycles.emission_sampling = "NONE"
    ao.data.materials.append(am)
    ao.visible_camera = False
    ao.visible_diffuse = False
    ao.visible_transmission = False
    ao.visible_volume_scatter = False

# a modelled room around the orb, hidden from the camera: its reflections and light do the work.
# +Y is up in the picture; the camera looks along -Z from +Z.
def surface(name, verts, colour, emit=0.0, rough=0.6):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], [list(range(len(verts)))])
    o = bpy.data.objects.new(name, me)
    scene.collection.objects.link(o)
    mt = bpy.data.materials.new(name)
    mt.use_nodes = True
    bn = mt.node_tree.nodes["Principled BSDF"]
    bn.inputs["Base Color"].default_value = list(colour) + [1]
    bn.inputs["Roughness"].default_value = rough
    if emit:
        bn.inputs["Emission Color"].default_value = (1, 0.98, 0.95, 1)
        bn.inputs["Emission Strength"].default_value = emit
    o.data.materials.append(mt)
    o.visible_camera = False
    return o

if P.get("room_geo"):
    G = P["room_geo"]
    W, H, D, F = G.get("half_width", 6), G.get("ceiling", 6), G.get("depth", 6), -1.0
    wall = G.get("wall", [0.18, 0.17, 0.16])
    floor = G.get("floor", [0.55, 0.45, 0.36])
    surface("floor", [(-W, F, -D), (W, F, -D), (W, F, D + 4), (-W, F, D + 4)], floor, rough=G.get("floor_rough", 0.35))
    surface("ceiling", [(-W, H, -D), (-W, H, D + 4), (W, H, D + 4), (W, H, -D)], G.get("ceiling_colour", [0.25, 0.25, 0.25]))
    surface("back", [(-W, F, -D), (-W, H, -D), (W, H, -D), (W, F, -D)], wall)
    surface("left", [(-W, F, -D), (-W, F, D + 4), (-W, H, D + 4), (-W, H, -D)], wall)
    surface("right", [(W, F, -D), (W, H, -D), (W, H, D + 4), (W, F, D + 4)], wall)
    surface("front", [(-W, F, D + 4), (W, F, D + 4), (W, H, D + 4), (-W, H, D + 4)], wall)
    # windows: [wall, centre_u, centre_v, width, height, cols, rows, strength]; mullions are the gaps
    for wn_ in G.get("windows", []):
        wallname, cu, cv, ww, wh, cols, rows, st = wn_
        mull = G.get("mullion", 0.08)
        pw, ph = (ww - mull * (cols - 1)) / cols, (wh - mull * (rows - 1)) / rows
        for i in range(cols):
            for j in range(rows):
                u0 = cu - ww / 2 + i * (pw + mull); v0 = cv - wh / 2 + j * (ph + mull)
                if wallname == "front":
                    z = D + 4 - 0.01
                    vs = [(u0, v0, z), (u0 + pw, v0, z), (u0 + pw, v0 + ph, z), (u0, v0 + ph, z)]
                elif wallname == "left":
                    x = -W + 0.01
                    vs = [(x, v0, u0), (x, v0, u0 + pw), (x, v0 + ph, u0 + pw), (x, v0 + ph, u0)]
                elif wallname == "right":
                    x = W - 0.01
                    vs = [(x, v0, u0), (x, v0 + ph, u0), (x, v0 + ph, u0 + pw), (x, v0, u0 + pw)]
                else:  # back
                    z = -D + 0.01
                    vs = [(u0, v0, z), (u0, v0 + ph, z), (u0 + pw, v0 + ph, z), (u0 + pw, v0, z)]
                surface("pane", vs, [1, 1, 1], emit=st, rough=1.0)

hdri = P["hdri_path"] if P.get("hdri_path") else glob.glob(bpy.utils.resource_path("LOCAL") + "/datafiles/studiolights/world/" + P["hdri"] + ".exr")[0]
world = bpy.data.worlds.new("world")
world.use_nodes = True
wn = world.node_tree.nodes
env = wn.new("ShaderNodeTexEnvironment")
env.image = bpy.data.images.load(hdri)
mp = wn.new("ShaderNodeMapping")
tc = wn.new("ShaderNodeTexCoord")
mp.inputs["Rotation"].default_value = (math.radians(P["rot_x"]), math.radians(P.get("rot_y", 0)), math.radians(P["rot_z"]))
world.node_tree.links.new(tc.outputs["Generated"], mp.inputs["Vector"])
world.node_tree.links.new(mp.outputs[0], env.inputs["Vector"])
world.node_tree.links.new(env.outputs[0], wn["Background"].inputs["Color"])
wn["Background"].inputs["Strength"].default_value = P["hdri_strength"]
if P.get("room"):
    # dark ceiling, a bright horizon band, a warm lit floor
    for n in list(wn):
        if n.type in ("TEX_ENVIRONMENT", "MAPPING", "TEX_COORD"): wn.remove(n)
    tc2 = wn.new("ShaderNodeTexCoord")
    sp = wn.new("ShaderNodeSeparateXYZ")
    world.node_tree.links.new(tc2.outputs["Generated"], sp.inputs[0])
    rr = wn.new("ShaderNodeValToRGB")
    el = rr.color_ramp.elements
    R = P["room"]
    el[0].position, el[0].color = 0.0, R["floor"] + [1]
    el[1].position, el[1].color = 1.0, R["ceiling"] + [1]
    for pos, col in R.get("stops", []):
        e = el.new(pos); e.color = col + [1]
    # Generated z runs -1..1 for directions; map to 0..1
    mr = wn.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = -1
    mr.inputs["From Max"].default_value = 1
    world.node_tree.links.new(sp.outputs["Y"], mr.inputs["Value"])
    world.node_tree.links.new(mr.outputs["Result"], rr.inputs["Fac"])
    world.node_tree.links.new(rr.outputs["Color"], wn["Background"].inputs["Color"])
    wn["Background"].inputs["Strength"].default_value = R.get("strength", 1.0)
scene.world = world

cam = bpy.data.cameras.new("cam")
cam.type = "ORTHO"
cam.ortho_scale = 2.0 * P.get("frame", 1.06)
co = bpy.data.objects.new("cam", cam)
co.location = (0, 0, 20)
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
scene.cycles.max_bounces = 32
scene.cycles.transmission_bounces = 32
scene.cycles.volume_bounces = 8
scene.render.resolution_x = scene.render.resolution_y = SIZE
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = P.get("look", "None")
scene.view_settings.exposure = P.get("exposure", 0.0)
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
