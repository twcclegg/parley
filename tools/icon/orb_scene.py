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

bpy.ops.mesh.primitive_uv_sphere_add(segments=P.get("segments", 192), ring_count=P.get("segments", 192) // 2, radius=1.0)
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
if P.get("pure_absorb"):
    # coloured glass: colour from absorption only, so it stays clear rather than milky
    lk = nt.nodes["Material Output"].inputs["Volume"].links
    if lk: nt.links.remove(lk[0])
    ab = nt.nodes.new("ShaderNodeVolumeAbsorption")
    ab.inputs["Color"].default_value = P.get("absorb_rgb", [min(1.0, (c / max(T)) ** P.get("absorb_exp", 1.0)) for c in T]) + [1]
    ab.inputs["Density"].default_value = P["pure_absorb"]
    nt.links.new(ab.outputs[0], nt.nodes["Material Output"].inputs["Volume"])

if P.get("halo", 0) > 0:
    # luminous interior: volume emission that falls off from a core point
    out_v = nt.nodes["Material Output"].inputs["Volume"]
    prev = out_v.links[0].from_socket if out_v.links else None
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sub = nt.nodes.new("ShaderNodeVectorMath"); sub.operation = "SUBTRACT"
    sub.inputs[1].default_value = P.get("halo_at", [0.0, -0.1, 0.0])
    nt.links.new(tc.outputs["Object"], sub.inputs[0])
    ln = nt.nodes.new("ShaderNodeVectorMath"); ln.operation = "LENGTH"
    nt.links.new(sub.outputs[0], ln.inputs[0])
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = 0.0
    mr.inputs["From Max"].default_value = P.get("halo_r", 0.9)
    mr.inputs["To Min"].default_value = 1.0
    mr.inputs["To Max"].default_value = 0.0
    nt.links.new(ln.outputs["Value"], mr.inputs["Value"])
    pw = nt.nodes.new("ShaderNodeMath"); pw.operation = "POWER"
    pw.inputs[1].default_value = P.get("halo_pow", 3.0)
    nt.links.new(mr.outputs["Result"], pw.inputs[0])
    st = nt.nodes.new("ShaderNodeMath"); st.operation = "MULTIPLY"
    st.inputs[1].default_value = P["halo"]
    nt.links.new(pw.outputs[0], st.inputs[0])
    # colour runs from hot (near white-amber) at the core to the brand colour at the edge
    cr = nt.nodes.new("ShaderNodeValToRGB")
    cr.color_ramp.elements[0].color = [c ** P.get("halo_edge_exp", 1.0) for c in T] + [1]
    cr.color_ramp.elements[1].color = P.get("halo_hot", [1.0, 0.62, 0.32]) + [1]
    cr.color_ramp.elements[1].position = P.get("halo_hot_pos", 0.85)
    nt.links.new(mr.outputs["Result"], cr.inputs["Fac"])
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(cr.outputs["Color"], em.inputs["Color"])
    nt.links.new(st.outputs[0], em.inputs["Strength"])
    if prev is not None:
        add = nt.nodes.new("ShaderNodeAddShader")
        nt.links.new(prev, add.inputs[0]); nt.links.new(em.outputs[0], add.inputs[1])
        nt.links.new(add.outputs[0], out_v)
    else:
        nt.links.new(em.outputs[0], out_v)

if P.get("filaments", 0) > 0:
    # glowing energy filaments inside the glass: random walks out from the core, with forks
    import random
    rnd = random.Random(P.get("seed", 7))
    fm = bpy.data.materials.new("filament")
    fm.use_nodes = True
    fe = fm.node_tree.nodes.new("ShaderNodeEmission")
    fe.inputs["Color"].default_value = P.get("fil_rgb", [1.0, 0.5, 0.25]) + [1]
    fe.inputs["Strength"].default_value = P.get("fil_glow", 12.0)
    fm.node_tree.links.new(fe.outputs[0], fm.node_tree.nodes["Material Output"].inputs["Surface"])
    core = Vector(P.get("halo_at", [0.0, -0.1, 0.0]))
    rmax = P.get("fil_reach", 0.82)
    def walk(start, d, steps, depth):
        pts = [start.copy()]
        p = start.copy()
        for i in range(steps):
            d = (d + Vector([rnd.gauss(0, P.get("fil_wiggle", 0.45)) for _ in range(3)])).normalized()
            p = p + d * P.get("fil_step", 0.07)
            if p.length > rmax:
                break
            pts.append(p.copy())
            if depth < 2 and rnd.random() < P.get("fil_fork", 0.12):
                walk(p, (d + Vector([rnd.gauss(0, 0.8) for _ in range(3)])).normalized(), steps // 2, depth + 1)
        if len(pts) < 3: return
        cu = bpy.data.curves.new("fil", "CURVE"); cu.dimensions = "3D"
        cu.bevel_depth = P.get("fil_width", 0.006) * (0.55 ** depth)
        cu.bevel_resolution = 2
        sp = cu.splines.new("NURBS"); sp.points.add(len(pts) - 1)
        for i, (q, v) in enumerate(zip(sp.points, pts)):
            q.co = (v.x, v.y, v.z, 1)
            q.radius = max(0.08, 1.0 - i / max(1, P.get("fil_steps", 24))) ** P.get("fil_taper", 1.0)
        sp.use_endpoint_u = True; sp.order_u = 4
        ob = bpy.data.objects.new("fil", cu); ob.data.materials.append(fm)
        scene.collection.objects.link(ob)
    for k in range(P["filaments"]):
        d = Vector([rnd.gauss(0, 1) for _ in range(3)]).normalized()
        walk(core + d * 0.05, d, P.get("fil_steps", 24), 0)
    if P.get("core_r", 0) > 0:
        bpy.ops.mesh.primitive_uv_sphere_add(radius=P["core_r"], location=core)
        cs = bpy.context.active_object
        cm = bpy.data.materials.new("hotcore"); cm.use_nodes = True
        ce = cm.node_tree.nodes.new("ShaderNodeEmission")
        ce.inputs["Color"].default_value = P.get("halo_hot", [1.0, 0.62, 0.32]) + [1]
        ce.inputs["Strength"].default_value = P.get("core_emit", 30.0)
        cm.node_tree.links.new(ce.outputs[0], cm.node_tree.nodes["Material Output"].inputs["Surface"])
        cs.data.materials.append(cm)

if P.get("inner_r", 0) > 0:
    # paperweight: a tinted glass core inside a clear glass shell
    bpy.ops.mesh.primitive_uv_sphere_add(segments=192, ring_count=96, radius=P["inner_r"])
    ic = bpy.context.active_object
    bpy.ops.object.shade_smooth()
    im = bpy.data.materials.new("innercore"); im.use_nodes = True
    it = im.node_tree
    ib = it.nodes["Principled BSDF"]
    ib.inputs["Base Color"].default_value = (1, 1, 1, 1)
    ib.inputs["Transmission Weight"].default_value = 1.0
    ib.inputs["Roughness"].default_value = 0.0
    ib.inputs["IOR"].default_value = P.get("inner_ior", 1.02)
    iab = it.nodes.new("ShaderNodeVolumeAbsorption")
    iab.inputs["Color"].default_value = P.get("inner_rgb", P.get("absorb_rgb", [1, 0.6, 0.4])) + [1]
    iab.inputs["Density"].default_value = P.get("inner_absorb", 3.0)
    it.links.new(iab.outputs[0], it.nodes["Material Output"].inputs["Volume"])
    ic.data.materials.append(im)

orb_only = bpy.data.collections.new("orb only")
orb_only.objects.link(orb)
if P.get("inner_r", 0) > 0: orb_only.objects.link(ic)

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
    if P.get("ring_reflect_only"):
        rmat.cycles.emission_sampling = "NONE"
        rg.visible_diffuse = rg.visible_transmission = rg.visible_volume_scatter = False

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
    # build each arc centred on angle 0 and rotate the object into place, so the
    # feathering's arctan never wraps at 180 degrees mid-arc
    ac = (a0 + a1) / 2
    a0, a1 = a0 - ac, a1 - ac
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
    ao.rotation_euler = (0, 0, math.radians(ac))
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
    if P.get("arc_soft", 0) > 0:
        # feather all four edges so the reflection has no hard cut
        atc = an.nodes.new("ShaderNodeTexCoord")
        asep = an.nodes.new("ShaderNodeSeparateXYZ")
        an.links.new(atc.outputs["Object"], asep.inputs[0])
        at2 = an.nodes.new("ShaderNodeMath"); at2.operation = "ARCTAN2"
        an.links.new(asep.outputs["Y"], at2.inputs[0]); an.links.new(asep.outputs["X"], at2.inputs[1])
        def norm(src, lo, hi):
            r = an.nodes.new("ShaderNodeMapRange")
            r.inputs["From Min"].default_value, r.inputs["From Max"].default_value = lo, hi
            an.links.new(src, r.inputs["Value"]); return r.outputs["Result"]
        def feather(src):
            r = an.nodes.new("ShaderNodeMapRange"); r.interpolation_type = "SMOOTHSTEP"
            r.inputs["From Min"].default_value, r.inputs["From Max"].default_value = 0.0, P["arc_soft"]
            an.links.new(src, r.inputs["Value"]); return r.outputs["Result"]
        def inv(src):
            r = an.nodes.new("ShaderNodeMath"); r.operation = "SUBTRACT"; r.inputs[0].default_value = 1.0
            an.links.new(src, r.inputs[1]); return r.outputs[0]
        u = norm(at2.outputs[0], math.radians(a0), math.radians(a1))
        v = norm(asep.outputs["Z"], z0, z1)
        acc = None
        for f in (feather(u), feather(inv(u)), feather(v), feather(inv(v))):
            if acc is None: acc = f; continue
            mm = an.nodes.new("ShaderNodeMath"); mm.operation = "MULTIPLY"
            an.links.new(acc, mm.inputs[0]); an.links.new(f, mm.inputs[1]); acc = mm.outputs[0]
        aem.inputs["Strength"].default_value = st
        # fade to see-through rather than to black, so the strip never blocks what lies behind it
        tr = an.nodes.new("ShaderNodeBsdfTransparent")
        mx = an.nodes.new("ShaderNodeMixShader")
        an.links.new(acc, mx.inputs["Fac"])
        an.links.new(tr.outputs[0], mx.inputs[1]); an.links.new(aem.outputs[0], mx.inputs[2])
        an.links.new(mx.outputs[0], an.nodes["Material Output"].inputs["Surface"])
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
if P.get("sea"):
    # seascape: physical sky with a low sun over a procedural ocean; the scene's up is +Y
    S = P["sea"]
    for n in list(wn):
        if n.type != "OUTPUT_WORLD" and n.type != "BACKGROUND": wn.remove(n)
    # sky built from the view direction (Y up): deep blue overhead, warm glow at the horizon, a sun
    L = world.node_tree.links
    tc3 = wn.new("ShaderNodeTexCoord")
    sep3 = wn.new("ShaderNodeSeparateXYZ"); L.new(tc3.outputs["Generated"], sep3.inputs[0])
    mr3 = wn.new("ShaderNodeMapRange")
    mr3.inputs["From Min"].default_value, mr3.inputs["From Max"].default_value = -1, 1
    L.new(sep3.outputs["Y"], mr3.inputs["Value"])
    ramp3 = wn.new("ShaderNodeValToRGB")
    el = ramp3.color_ramp.elements
    el[0].position, el[0].color = 0.0, S.get("below", [0.02, 0.03, 0.04]) + [1]
    el[1].position, el[1].color = 1.0, S.get("zenith", [0.05, 0.12, 0.35]) + [1]
    for pos, col in S.get("stops", [[0.5, [1.0, 0.55, 0.3]], [0.53, [0.55, 0.45, 0.5]], [0.62, [0.15, 0.25, 0.5]]]):
        e = el.new(pos); e.color = col + [1]
    L.new(mr3.outputs["Result"], ramp3.inputs["Fac"])
    sd = Vector(S.get("sun_dir", [-0.6, 0.12, -0.8])).normalized()
    dp = wn.new("ShaderNodeVectorMath"); dp.operation = "DOT_PRODUCT"
    dp.inputs[1].default_value = sd
    L.new(tc3.outputs["Generated"], dp.inputs[0])
    sp = wn.new("ShaderNodeMath"); sp.operation = "POWER"; sp.use_clamp = False
    mx0 = wn.new("ShaderNodeMath"); mx0.operation = "MAXIMUM"; mx0.inputs[1].default_value = 0.0
    L.new(dp.outputs["Value"], mx0.inputs[0]); L.new(mx0.outputs[0], sp.inputs[0])
    sp.inputs[1].default_value = S.get("sun_sharp", 800)
    sm = wn.new("ShaderNodeMath"); sm.operation = "MULTIPLY"; sm.inputs[1].default_value = S.get("sun_int", 60)
    L.new(sp.outputs[0], sm.inputs[0])
    gp = wn.new("ShaderNodeMath"); gp.operation = "POWER"; gp.inputs[1].default_value = S.get("glow_sharp", 12)
    L.new(mx0.outputs[0], gp.inputs[0])
    gm = wn.new("ShaderNodeMath"); gm.operation = "MULTIPLY"; gm.inputs[1].default_value = S.get("glow_int", 1.5)
    L.new(gp.outputs[0], gm.inputs[0])
    tot = wn.new("ShaderNodeMath"); tot.operation = "ADD"
    L.new(sm.outputs[0], tot.inputs[0]); L.new(gm.outputs[0], tot.inputs[1])
    sc = wn.new("ShaderNodeMix"); sc.data_type = "RGBA"; sc.blend_type = "ADD"
    sc.inputs["Factor"].default_value = 1.0
    sunc = wn.new("ShaderNodeMix"); sunc.data_type = "RGBA"; sunc.blend_type = "MULTIPLY"
    sunc.inputs["Factor"].default_value = 1.0
    sunc.inputs[6].default_value = S.get("sun_col", [1.0, 0.75, 0.5]) + [1]
    cv = wn.new("ShaderNodeCombineColor")
    for i in range(3): L.new(tot.outputs[0], cv.inputs[i])
    L.new(cv.outputs[0], sunc.inputs[7])
    L.new(ramp3.outputs["Color"], sc.inputs[6]); L.new(sunc.outputs[2], sc.inputs[7])
    L.new(sc.outputs[2], wn["Background"].inputs["Color"])
    wn["Background"].inputs["Strength"].default_value = S.get("strength", 0.15)
    # ocean: a large plane below the orb, rotated so its normal points along +Y
    bpy.ops.mesh.primitive_plane_add(size=2, location=(0, -S.get("depth", 2.5), 0))
    sea = bpy.context.active_object
    sea.rotation_euler = (math.radians(-90), 0, 0)
    oc = sea.modifiers.new("ocean", "OCEAN")
    oc.geometry_mode = "GENERATE"
    oc.size = S.get("size", 6.0)
    oc.spatial_size = S.get("spatial", 40)
    oc.repeat_x = oc.repeat_y = S.get("repeat", 6)
    oc.resolution = S.get("res", 12)
    oc.wave_scale = S.get("wave", 1.5)
    oc.choppiness = S.get("chop", 1.2)
    oc.wind_velocity = S.get("wind", 12)
    oc.random_seed = S.get("seed", 3)
    sea.location = (-oc.size * oc.repeat_x / 2 * 0 , -S.get("depth", 2.5), 0)
    wm = bpy.data.materials.new("water"); wm.use_nodes = True
    wb = wm.node_tree.nodes["Principled BSDF"]
    wb.inputs["Base Color"].default_value = S.get("water", [0.005, 0.03, 0.045]) + [1]
    wb.inputs["Roughness"].default_value = S.get("water_rough", 0.04)
    wb.inputs["IOR"].default_value = 1.33
    sea.data.materials.append(wm)
    sea.visible_camera = False
    bpy.ops.object.shade_smooth()
scene.world = world
for bd in P.get("backdrops", []):
    # an image on a plane, seen only through the glass: [path, z, width, strength, flip]
    path, bz, bw, bst = bd[:4]
    img = bpy.data.images.load(path)
    asp = img.size[1] / img.size[0]
    bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 0, bz))
    bo = bpy.context.active_object
    bo.scale = (bw, bw * asp, 1)
    if bz > 0: bo.rotation_euler = (math.radians(180), 0, 0)
    if len(bd) > 4 and bd[4]: bo.rotation_euler[2] += math.radians(180)
    bm_ = bpy.data.materials.new("backdrop"); bm_.use_nodes = True
    bn = bm_.node_tree
    bn.nodes.remove(bn.nodes["Principled BSDF"])
    ti = bn.nodes.new("ShaderNodeTexImage"); ti.image = img
    be = bn.nodes.new("ShaderNodeEmission"); be.inputs["Strength"].default_value = bst
    bn.links.new(ti.outputs["Color"], be.inputs["Color"])
    bn.links.new(be.outputs[0], bn.nodes["Material Output"].inputs["Surface"])
    bo.data.materials.append(bm_)
    bo.visible_camera = False
    bo.visible_diffuse = False
    bo.visible_glossy = P.get("backdrop_glossy", True)  # False: reflections skip it, only refraction sees it

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
if P.get("glare", 0) > 0:
    # bloom: light from the bright core and filaments spills softly, as in a real lens
    try:
        ng = bpy.data.node_groups.new("comp", "CompositorNodeTree")
        scene.compositing_node_group = ng
        ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        rl = ng.nodes.new("CompositorNodeRLayers")
        gl = ng.nodes.new("CompositorNodeGlare")
        for k, v in (("Type", "Bloom"), ("Quality", "High")):
            if k in gl.inputs: gl.inputs[k].default_value = v
        if "Threshold" in gl.inputs: gl.inputs["Threshold"].default_value = P.get("glare_thresh", 1.0)
        if "Strength" in gl.inputs: gl.inputs["Strength"].default_value = P["glare"]
        if "Size" in gl.inputs: gl.inputs["Size"].default_value = P.get("glare_size", 0.5)
        go = ng.nodes.new("NodeGroupOutput")
        ng.links.new(rl.outputs["Image"], gl.inputs["Image"])
        ng.links.new(gl.outputs["Image"], go.inputs[0])
    except Exception as e:
        print("GLARE FAILED", e)
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
