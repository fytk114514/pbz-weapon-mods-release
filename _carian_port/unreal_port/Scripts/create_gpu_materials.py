"""Carian 3.0: GPU playback of every baked FXR particle (see toolchain/bake_gpu.py).

Built by toolchain/build_fx_container.py with create_carian_materials.py, in a NullRHI commandlet with
the captured PBZ uniform profile; cooked with shaders inline (no shader library).

- T_CBA_GPU_<id>: the baked keys, RGBA16F, point sampled, no mips (8 texels per key).
- T_CBA_L<id>: the source particle textures, linear (the source PPO decodes colour itself), <= 1024.
- M_CBA_GPUAdd / M_CBA_GPUBlend: one quad per particle track. The vertex shader finds the track's
  key for the instance time, moves the quad there by World Position Offset (frame axes from the
  runtime; world-anchored particles take the blade frame at their birth from the frame history
  render target) and faces it like the source (camera, vertical axis, blade axis, or a line). The
  pixel shader is the source PPO: three layers with their own UV transform and scroll, flipbook,
  erosion threshold, multiply/add/overlay ladder, rgb = (t x dir)^2 x energy; then 2.x's soft knee
  to PBZ emissive and the hot-core whitening. Soft particles where the source has depthBlend.
  3.2: Streak (the aura comets' trails): a line quad with layer 1 laid along it (U from the comet's
  start to its head), the oldest point's segment fade (Misc.z) towards the tail and the trail's
  fade endpoints (ST2.xy: fractions from its oldest point and from its head).
- M_CBA_FrameWrite: writes one frame of blade axes into the history render target (canvas).
3.6: the values that change per cast or per frame come from the mesh's custom primitive data, one
float4 per engine call for every section of the mesh (gpu_player.lua writes them): 0-2 origin, 3 time,
4-6 x axis, 7 blade scale, 8-10 y axis, 11 cm per source metre, 12-14 z axis, 15 cast start, 16 stop
time, 17 fade, 18 px per cm, 19 size cap, 20 history on. Before, five material parameters per section
and frame cost the game thread up to 20 ms during a slash (about 200 calls).
Static vertex data per track (runtime gpu_player.lua): UV0 corner, UV1 (birth, first key age),
UV2 (offset / 2048, offset % 2048), UV3 (keys, loop period), colour R = previous loop cycle,
G = world-anchored.
"""
from pathlib import Path
import unreal as u

base = '/Game/Mods/CarianFX'
ROOT = Path(r'<仓库根目录>\_carian_port')
DATA = ROOT / 'verification/v3.0/gpu_data'
SRC = ROOT / 'eldenring_source/grandeur/editor_import/Textures'
lib = u.MaterialEditingLibrary
tools = u.AssetToolsHelpers.get_asset_tools()
white = u.load_asset('/Engine/EngineResources/WhiteSquareTexture')


def import_file(path, name):
    task = u.AssetImportTask()
    task.filename = str(path)
    task.destination_path = base + '/Textures'
    task.destination_name = name
    task.automated = True
    task.replace_existing = True
    task.save = True
    tools.import_asset_tasks([task])
    t = u.load_asset(base + '/Textures/' + name)
    assert isinstance(t, u.Texture2D), name
    return t


def save(a):
    assert u.EditorAssetLibrary.save_loaded_asset(a, only_if_is_dirty=False), a.get_name()


# --- data textures ------------------------------------------------------------------------------
data_textures = {}
for dds in sorted(DATA.glob('T_CBA_GPU_*.dds')):
    t = import_file(dds, dds.stem)
    t.set_editor_property('compression_settings', u.TextureCompressionSettings.TC_HDR)
    t.set_editor_property('srgb', False)
    t.set_editor_property('filter', u.TextureFilter.TF_NEAREST)
    t.set_editor_property('mip_gen_settings', u.TextureMipGenSettings.TMGS_NO_MIPMAPS)
    t.set_editor_property('never_stream', True)
    save(t)
    data_textures[dds.stem] = t
u.log('CBA_GPU_DATA ' + ','.join('%s=%dx%d' % (k, v.blueprint_get_size_x(), v.blueprint_get_size_y()) for k, v in data_textures.items()))

# --- source particle textures ----------------------------------------------------------------------
manifest = (ROOT / 'runtime_v14/CarianBrutalAxe/Scripts/gpu_manifest.lua').read_text(encoding='utf-8')
ids = [int(x) for x in manifest.split('textures={')[1].split('}')[0].split(',') if x.strip()]
for i in ids:
    t = import_file(SRC / ('s%05d_a.png' % i), 'T_CBA_L%d' % i)
    t.set_editor_property('srgb', False)
    t.set_editor_property('max_texture_size', 1024)
    save(t)
u.log('CBA_GPU_LAYERS ' + ','.join(str(i) for i in ids))


def node(m, cls, **props):
    n = lib.create_material_expression(m, cls, 0, 0)
    for k, v in props.items():
        n.set_editor_property(k, v)
    return n


def connect(src, out, dst, pin):
    assert lib.connect_material_expressions(src, out, dst, pin), (src.get_name(), out, dst.get_name(), pin)


def connect_any(src, out, dst, pins):
    for pin in pins:
        if lib.connect_material_expressions(src, out, dst, pin):
            return
    raise AssertionError(('no input matched', dst.get_name(), pins))


def output(src, out, m, prop):
    assert lib.connect_material_property(src, out, prop), (src.get_name(), out, str(prop))


def scalar(m, name, value):
    return node(m, u.MaterialExpressionScalarParameter, parameter_name=name, default_value=float(value))


def vector(m, name, value):
    return node(m, u.MaterialExpressionVectorParameter, parameter_name=name, default_value=u.LinearColor(*value))


# 3.6: per-mesh values (see the docstring)
CPD = {'OriginAbs': 0, 'Time': 3, 'AxX': 4, 'AxisK': 7, 'AxY': 8, 'S': 11, 'AxZ': 12, 'InstStart': 15,
       'StopT': 16, 'Fade': 17, 'PxPerCm': 18, 'RigMax': 19, 'HistOn': 20}


def cpd_scalar(m, name, value):
    n = scalar(m, name, value)
    n.set_editor_property('use_custom_primitive_data', True)
    n.set_editor_property('primitive_data_index', CPD[name])
    return n


def cpd_vector(m, name, value):
    n = vector(m, name, value)
    n.set_editor_property('use_custom_primitive_data', True)
    n.set_editor_property('primitive_data_index', CPD[name])
    return n


def texobj(m, name, tex):
    return node(m, u.MaterialExpressionTextureObjectParameter, parameter_name=name, texture=tex)


def custom(m, code, inputs, kind=u.CustomMaterialOutputType.CMOT_FLOAT3, extra=()):
    fields = []
    for name, _, _ in inputs:
        f = u.CustomInput()
        f.set_editor_property('input_name', name)
        fields.append(f)
    n = node(m, u.MaterialExpressionCustom, code=code, output_type=kind, inputs=fields)
    outs = []
    for name, t in extra:
        o = u.CustomOutput()
        o.set_editor_property('output_name', name)
        o.set_editor_property('output_type', t)
        outs.append(o)
    if outs:
        n.set_editor_property('additional_outputs', outs)
    for name, src, out in inputs:
        connect(src, out, n, name)
    return n


def material(name, blend):
    m = u.load_asset(base + '/Materials/' + name)
    if m:
        lib.delete_all_material_expressions(m)
    else:
        m = tools.create_asset(name, base + '/Materials', u.Material, u.MaterialFactoryNew())
    assert m, name
    m.set_editor_property('shading_model', u.MaterialShadingModel.MSM_UNLIT)
    m.set_editor_property('blend_mode', blend)
    m.set_editor_property('two_sided', True)
    return m


VS = r'''
float3 wpo = float3(0, 0, 0);
O_Col = float4(0, 0, 0, 0); O_Misc = float4(0, 0, 0, 0);
O_ST1 = float4(1, 1, 0, 0); O_ST2 = O_ST1; O_ST3 = O_ST1;
float nKeys = UV3.x;
if (nKeys < 0.5) return wpo;
float period = UV3.y, birth = UV1.x, k0 = UV1.y;
float cyc = VC.r > 0.5 ? 1.0 : 0.0;
float b0 = birth;
if (period > 0.0) {
    if (Time < birth) return wpo;
    float kk = floor((Time - birth) / period) - cyc;
    if (kk < 0.0) return wpo;
    b0 = birth + kk * period;
} else if (cyc > 0.5) return wpo;
if (b0 > StopT) return wpo;
float age = Time - b0;
if (age < k0 || age > k0 + (nKeys - 1.0) / Rate) return wpo;
float f = (age - k0) * Rate;
float i0 = clamp(floor(f), 0.0, max(nKeys - 2.0, 0.0));
float fr = nKeys > 1.5 ? saturate(f - i0) : 0.0;
int W = 2048;
int base0 = (int)(UV2.x * 2048.0 + UV2.y + 0.5) + (int)i0 * 8;
int base1 = nKeys > 1.5 ? base0 + 8 : base0;
float4 A[8], Bk[8];
for (int j = 0; j < 8; j++) {
    int o = base0 + j; A[j] = Data.Load(int3(o % W, o / W, 0));
    o = base1 + j; Bk[j] = Data.Load(int3(o % W, o / W, 0));
}
float4 K0 = lerp(A[0], Bk[0], fr), K1 = lerp(A[1], Bk[1], fr), col = lerp(A[2], Bk[2], fr);
float4 K6 = lerp(A[6], Bk[6], fr);
float3 X = AxX, Y = AxY, Z = AxZ, O = float3(0, 0, 0);
if (VC.g > 0.5 && HistOn > 0.5) {
    // world-anchored: the blade frame when the particle first showed (the CPU path copies it then)
    float slot = floor((InstStart + b0 + k0) * HistRate);
    slot = slot - HistSize * floor(slot / HistSize);
    int sx = (int)slot;
    // emissive cannot be negative, so the writer stores origin + 1e6 and axes + 2 (0 = never written)
    float4 h1 = Hist.Load(int3(sx, 1, 0));
    if (dot(h1.xyz, h1.xyz) > 1.0) {
        O = Hist.Load(int3(sx, 0, 0)).xyz - 1000000.0 - OriginAbs;
        X = h1.xyz - 2.0; Y = (Hist.Load(int3(sx, 2, 0)).xyz - 2.0) * AxisK; Z = Hist.Load(int3(sx, 3, 0)).xyz - 2.0;
    }
}
float3 rel = O + S * (K0.x * X + K0.y * Y + K0.z * Z);
float3 toP = CamRel + rel;
float dist = max(1.0, dot(toP, CamFwd));
float w = K0.w * S, h = K1.x * S;
float ca = col.a * Fade;
float kf = saturate((dist - NearFade.x) / max(1.0, NearFade.y - NearFade.x));
if (IsLine < 0.5) {
    float cover = sqrt(max(w * h, 0.0)) / dist;
    if (cover > Coverage.x) kf *= max(0.0, 1.0 - (cover - Coverage.x) / max(0.001, Coverage.y - Coverage.x));
}
if (RigMax > 0.0) { float mx = max(w, h); if (mx > RigMax) { float sc = RigMax / mx; w *= sc; h *= sc; } }
float energy = 1.0;
float px = min(w, h) * PxPerCm / dist;
if (px < MinPx && px > 0.0) {
    float grow = MinPx / px;
    if (IsLine > 0.5) { w *= grow; energy = 1.0 / grow; } else { w *= grow; h *= grow; energy = 1.0 / (grow * grow); }
}
ca *= kf;
if (ca <= 0.002 || w <= 0.01 || h <= 0.01) return wpo;
float3 R, U;
if (IsLine > 0.5) {
    U = normalize(K6.x * X + K6.y * Y + K6.z * Z + float3(0, 0, 1e-6));
    R = cross(toP, U);
} else if (Orient > 3.5 && Orient < 7.5 && abs(Orient - 5.0) > 0.5 && abs(Orient - 6.0) > 0.5) {
    U = Orient > 6.5 ? normalize(K6.x * X + K6.y * Y + K6.z * Z + float3(0, 0, 1e-6)) : float3(0, 0, 1);
    R = CamRight - U * dot(CamRight, U);
} else {
    float an = radians(K1.y); float c0 = cos(an), s0 = sin(an);
    R = CamRight * c0 + CamUp * s0; U = CamUp * c0 - CamRight * s0;
}
float rl = length(R); R = rl > 1e-6 ? R / rl : float3(0, 0, 1);
wpo = rel + R * (UV0.x * 0.5 * w) + U * (UV0.y * 0.5 * h);
O_Col = float4(col.rgb, ca * energy);
O_Misc = float4(A[1].z, K1.w, K6.w, lerp(A[7].x, Bk[7].x, fr));
O_ST1 = lerp(A[3], Bk[3], fr); O_ST2 = lerp(A[4], Bk[4], fr); O_ST3 = lerp(A[5], Bk[5], fr);
return wpo;
'''

PS = r'''
float2 UV = float2(UV0.x * 0.5 + 0.5, 0.5 - UV0.y * 0.5);
// 3.2: a comet trail: the source trail texture runs along the quad (U from the comet's start to its
// head), V across it
if (Streak > 0.5) UV = float2(UV0.y * 0.5 + 0.5, UV0.x * 0.5 + 0.5);
float Frame = Misc.x, Threshold = Misc.y;
float4 st1 = ST1, st2 = ST2, st3 = ST3;
float columns = max(Grid.x, 1.0), rows = max(Grid.y, 1.0);
float index = clamp(floor(Frame), 0.0, max(Grid.z - 1.0, 0.0));
float2 tile = float2(fmod(index, columns), floor(index / columns));
float2 uv1 = ((UV * st1.xy + st1.zw) + tile) / float2(columns, rows);
float4 t1 = Texture2DSample(Tex1, Tex1Sampler, uv1);
if (Grid.w > 0.5) {
    float next = min(index + 1.0, max(Grid.z - 1.0, 0.0));
    float2 nextTile = float2(fmod(next, columns), floor(next / columns));
    t1 = lerp(t1, Texture2DSample(Tex1, Tex1Sampler, ((UV * st1.xy + st1.zw) + nextTile) / float2(columns, rows)), frac(Frame));
}
t1.rgb *= Tint1.rgb;
// QuadLines and untextured sprites: the 2.x fx_line profile (Gaussian across, tapered ends) instead
// of the source's 4x4 white texture; its square root, because the PPO below squares the colour
if (LineProfile > 0.5) t1.rgb *= exp(-0.5 * (UV0.x / 0.45) * (UV0.x / 0.45)) * sqrt(saturate(1.15 - pow(abs(UV0.y), 4.0)));
float erosion = clamp(Threshold / 255.0, 0.0, 0.99999);
t1.a = saturate((t1.a - erosion) / (1.0 - erosion)) * Tint1.a;
if (PreAlpha > 0.5) t1.rgb *= t1.a;
if (Multi > 0.5) {
    float4 t2 = Texture2DSample(Tex2, Tex2Sampler, UV * st2.xy + st2.zw);
    float4 t3 = Texture2DSample(Tex3, Tex3Sampler, UV * st3.xy + st3.zw);
    t2.rgb *= Tint2.rgb; t3.rgb *= Tint3.rgb;
    t2.a = saturate((t2.a - erosion) / (1.0 - erosion)) * Misc.z;
    t3.a = saturate((t3.a - erosion) / (1.0 - erosion)) * Misc.w;
    if (PreAlpha > 0.5) { t2.rgb *= t2.a; t3.rgb *= t3.a; }
    for (int layer = 2; layer <= 3; layer++) {
        float4 t = layer == 2 ? t2 : t3; float mode = layer == 2 ? BlendTypes.y : BlendTypes.z;
        bool alphaLayer = layer == 2 ? (abs(BlendTypes.x - 1.0) < 0.5 || abs(BlendTypes.x - 2.0) < 0.5) : (abs(BlendTypes.x - 1.0) < 0.5);
        if (alphaLayer) {
            float gray = saturate(dot(t.rgb, float3(0.333333333, 0.333333333, 0.333333333)));
            float b = mode < 0.5 ? t1.a * gray : mode < 1.5 ? t1.a + gray : (t1.a < .5 ? 2 * t1.a * gray : 1 - 2 * (1 - t1.a) * (1 - gray));
            t1.a = lerp(t1.a, b, t.a);
        } else {
            float3 overlay = lerp(2 * t1.rgb * t.rgb, 1 - 2 * (1 - t1.rgb) * (1 - t.rgb), step(.5, t1.rgb));
            float3 b = mode < .5 ? t1.rgb * t.rgb : mode < 1.5 ? t1.rgb + t.rgb : overlay;
            t1.rgb = lerp(t1.rgb, b, t.a);
        }
    }
}
float energySrc = length(Col.rgb);
float3 direction = energySrc > 0.00001 ? Col.rgb / energySrc : float3(0, 0, 0);
float3 mixed = t1.rgb * direction;
if (abs(BlendTypes.w - 2.0) < 0.5) {
    float3 baseColor = t1.rgb * t1.a;
    mixed = lerp(2 * baseColor * direction, 1 - 2 * (1 - baseColor) * (1 - direction), step(.5, baseColor));
}
float3 rgb = mixed * mixed * energySrc;
if (abs(BlendTypes.w) > 0.5 && abs(BlendTypes.w - 2.0) > 0.5) rgb = t1.rgb;
float alphaRaw = t1.a * max(Col.a, 0.0);
// 3.2: the trail's oldest point has faded by its share of the segment time (v1.3 renderer), the head
// not; and the source's fade endpoints: in over the first ST2.x of the trail, out over the last ST2.y
if (Streak > 0.5) {
    alphaRaw *= lerp(saturate(Misc.z), 1.0, UV.x);
    if (ST2.x > 0.001) alphaRaw *= saturate(UV.x / ST2.x);
    if (ST2.y > 0.001) alphaRaw *= saturate((1.0 - UV.x) / ST2.y);
}
float alpha = saturate(alphaRaw);
// source HDR -> PBZ emissive: the 2.x soft knee on the peak channel, then whiten the hottest cores.
// Additive: the FXR alpha is an intensity (up to 50 on the glints), multiplied in unclamped as on
// the 2.x path. Translucent: coverage is clamped, and as in the source PPO the alpha above 1
// brightens the colour instead (the stage-up sigil reaches 4.9)
float3 e = max(rgb, 0.0) * (Additive > 0.5 ? alphaRaw : max(alphaRaw, 1.0));
float m = max(e.r, max(e.g, e.b));
e *= m > 1e-6 ? Emax * (1.0 - exp(-Exposure * m / Emax)) / m : 0.0;
float m2 = max(e.r, max(e.g, e.b));
e = lerp(e, float3(m2, m2, m2), Whiten * smoothstep(WhitenStart, max(WhitenEnd, WhitenStart + 0.001), m2));
return float4(e, alpha);
'''

F3, F4 = u.CustomMaterialOutputType.CMOT_FLOAT3, u.CustomMaterialOutputType.CMOT_FLOAT4
first_data = next(iter(data_textures.values()))
layer_default = u.load_asset(base + '/Textures/T_CBA_L1')


def gpu_material(name, blend):
    m = material(name, blend)
    additive = blend == u.BlendMode.BLEND_ADDITIVE
    uv = [node(m, u.MaterialExpressionTextureCoordinate, coordinate_index=i) for i in range(4)]
    vc = node(m, u.MaterialExpressionVertexColor)
    cam_rel = node(m, u.MaterialExpressionWorldPosition)
    wpt = next(getattr(u.WorldPositionIncludedOffsets, k) for k in ('WPT_CAMERA_RELATIVE_NO_OFFSETS', 'WPT_CAMERA_RELATIVE_NOOFFSETS')
               if hasattr(u.WorldPositionIncludedOffsets, k))
    cam_rel.set_editor_property('world_position_shader_offset', wpt)
    axes = []
    for v in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
        c = node(m, u.MaterialExpressionConstant3Vector, constant=u.LinearColor(v[0], v[1], v[2], 0))
        t = node(m, u.MaterialExpressionTransform, transform_source_type=u.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_VIEW,
                 transform_type=u.MaterialVectorCoordTransform.TRANSFORM_WORLD)
        connect(c, '', t, '')
        axes.append(t)
    vin = [('UV0', uv[0], ''), ('UV1', uv[1], ''), ('UV2', uv[2], ''), ('UV3', uv[3], ''), ('VC', vc, ''),
           ('Data', texobj(m, 'Data', first_data), ''), ('Hist', texobj(m, 'Hist', white), ''),
           ('CamRel', cam_rel, ''), ('CamRight', axes[0], ''), ('CamUp', axes[1], ''), ('CamFwd', axes[2], '')]
    for n, d in (('Time', 0), ('StopT', 1e6), ('Fade', 1), ('Rate', 30), ('S', 150), ('Orient', 1), ('IsLine', 0), ('RigMax', 0), ('MinPx', 2.5),
                 ('PxPerCm', 1371), ('HistOn', 0), ('HistRate', 30), ('HistSize', 256), ('InstStart', 0), ('AxisK', 1)):
        vin.append((n, (cpd_scalar if n in CPD else scalar)(m, n, d), ''))
    for n, d in (('AxX', (1, 0, 0, 0)), ('AxY', (0, 1, 0, 0)), ('AxZ', (0, 0, 1, 0)), ('OriginAbs', (0, 0, 0, 0)), ('NearFade', (40, 160, 0, 0)),
                 ('Coverage', (.8, 2.5, 0, 0))):
        vin.append((n, (cpd_vector if n in CPD else vector)(m, n, d), 'RGB' if n.startswith(('Ax', 'Origin')) else 'RGBA'))
    outs = [('O_Col', F4), ('O_Misc', F4), ('O_ST1', F4), ('O_ST2', F4), ('O_ST3', F4)]
    vs = custom(m, VS, vin, F3, outs)
    output(vs, '', m, u.MaterialProperty.MP_WORLD_POSITION_OFFSET)
    interp = {}
    for o, _ in outs:
        i = node(m, u.MaterialExpressionVertexInterpolator)
        connect(vs, o, i, 'VS')
        interp[o] = i
    pin = [('UV0', uv[0], ''), ('Col', interp['O_Col'], ''), ('Misc', interp['O_Misc'], ''), ('ST1', interp['O_ST1'], ''),
           ('ST2', interp['O_ST2'], ''), ('ST3', interp['O_ST3'], '')]
    for i in (1, 2, 3):
        pin.append(('Tex%d' % i, texobj(m, 'Layer%d' % i, layer_default), ''))
        pin.append(('Tint%d' % i, vector(m, 'Tint%d' % i, (1, 1, 1, 1)), 'RGBA'))
    pin += [('Grid', vector(m, 'Grid', (1, 1, 1, 0)), 'RGBA'), ('BlendTypes', vector(m, 'BlendTypes', (0, 0, 0, 0)), 'RGBA'),
            ('Multi', scalar(m, 'Multi', 0), ''), ('PreAlpha', scalar(m, 'PreAlpha', 0), ''), ('Additive', scalar(m, 'AdditiveMode', 1 if additive else 0), ''),
            ('LineProfile', scalar(m, 'LineProfile', 0), ''), ('Streak', scalar(m, 'Streak', 0), ''),
            ('Exposure', scalar(m, 'Exposure', .035), ''), ('Emax', scalar(m, 'Emax', 3.2), ''), ('Whiten', scalar(m, 'Whiten', .7), ''),
            ('WhitenStart', scalar(m, 'WhitenStart', .6), ''), ('WhitenEnd', scalar(m, 'WhitenEnd', 3), '')]
    ps = custom(m, PS, pin, F4)
    rgb = node(m, u.MaterialExpressionComponentMask, r=True, g=True, b=True, a=False)
    connect(ps, '', rgb, '')
    alpha = node(m, u.MaterialExpressionComponentMask, r=False, g=False, b=False, a=True)
    connect(ps, '', alpha, '')
    # soft particles (source depthBlend): SoftDistance in cm, 0 = off
    soft_d = scalar(m, 'SoftDistance', 0)
    depth = node(m, u.MaterialExpressionDepthFade)
    connect(custom(m, 'return max(SoftDistance, 1.0);', [('SoftDistance', soft_d, '')], u.CustomMaterialOutputType.CMOT_FLOAT1), '', depth, 'FadeDistance')
    soft = custom(m, 'return SoftDistance > 0.5 ? D : 1.0;', [('D', depth, ''), ('SoftDistance', soft_d, '')], u.CustomMaterialOutputType.CMOT_FLOAT1)
    if additive:
        e = custom(m, 'return E * Soft;', [('E', rgb, ''), ('Soft', soft, '')], F3)
        ex = node(m, u.MaterialExpressionEyeAdaptationInverse)
        connect_any(e, '', ex, ('LightValue', 'Light Value', 'LightValueInput'))
        connect_any(scalar(m, 'ExposureInvariant', 1), '', ex, ('Alpha', 'AlphaInput'))
        output(ex, '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
    else:
        ex = node(m, u.MaterialExpressionEyeAdaptationInverse)
        connect_any(rgb, '', ex, ('LightValue', 'Light Value', 'LightValueInput'))
        connect_any(scalar(m, 'ExposureInvariant', 1), '', ex, ('Alpha', 'AlphaInput'))
        output(ex, '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
        op = custom(m, 'return A * Soft;', [('A', alpha, ''), ('Soft', soft, '')], u.CustomMaterialOutputType.CMOT_FLOAT1)
        output(op, '', m, u.MaterialProperty.MP_OPACITY)
    lib.recompile_material(m)
    save(m)


gpu_material('M_CBA_GPUAdd', u.BlendMode.BLEND_ADDITIVE)
gpu_material('M_CBA_GPUBlend', u.BlendMode.BLEND_TRANSLUCENT)

# --- development only: where does the vertex shader drop a quad? ---------------------------------
# Same inputs as the GPU materials; every quad that fails a check is drawn as a small square at a
# fixed spot by the component, coloured by the first check it failed (1 red: no keys, 2 orange:
# loop window, 3 yellow: previous-cycle copy of a one-shot, 4 green: after StopT, 5 cyan: before
# its first key, 6 blue: after its last key, 7 magenta: alpha, 8 grey: size); passing quads are
# drawn as the particle, white. Not shipped (build_fx_container.py leaves it out of the container
# unless CBA_GPU_DEBUG is set).
VS_DEBUG = r'''
float3 wpo = float3(0, 0, 0);
O_Col = float4(1, 1, 1, 1); O_Misc = float4(0, 0, 0, 0); O_ST1 = float4(1, 1, 0, 0); O_ST2 = O_ST1; O_ST3 = O_ST1;
float code = 0.0;
float nKeys = UV3.x, period = UV3.y, birth = UV1.x, k0 = UV1.y;
float cyc = VC.r > 0.5 ? 1.0 : 0.0;
[loop] do {
    if (nKeys < 0.5) { code = 1.0; break; }
    float b0 = birth;
    if (period > 0.0) {
        if (Time < birth) { code = 2.0; break; }
        float kk = floor((Time - birth) / period) - cyc;
        if (kk < 0.0) { code = 2.0; break; }
        b0 = birth + kk * period;
    } else if (cyc > 0.5) { code = 3.0; break; }
    if (b0 > StopT) { code = 4.0; break; }
    float age = Time - b0;
    if (age < k0) { code = 5.0; break; }
    if (age > k0 + (nKeys - 1.0) / Rate) { code = 6.0; break; }
    float f = (age - k0) * Rate;
    float i0 = clamp(floor(f), 0.0, max(nKeys - 2.0, 0.0));
    int W = 2048;
    int base0 = (int)(UV2.x * 2048.0 + UV2.y + 0.5) + (int)i0 * 8;
    float4 K0 = Data.Load(int3(base0 % W, base0 / W, 0));
    float4 K1 = Data.Load(int3((base0 + 1) % W, (base0 + 1) / W, 0));
    float4 col = Data.Load(int3((base0 + 2) % W, (base0 + 2) / W, 0));
    if (col.a * Fade <= 0.002) { code = 7.0; break; }
    float w = K0.w * S, h = K1.x * S;
    if (w <= 0.01 || h <= 0.01) { code = 8.0; break; }
    float3 rel = S * (K0.x * AxX + K0.y * AxY + K0.z * AxZ);
    wpo = rel + CamRight * (UV0.x * 0.5 * w) + CamUp * (UV0.y * 0.5 * h);
    O_Col = float4(1, 1, 1, 1);
    code = 9.0;
} while (false);
if (code < 8.5) {
    wpo = float3(0, 0, 150) + CamRight * (code * 30.0 - 135.0) + (CamRight * UV0.x + CamUp * UV0.y) * 10.0;
    float3 c = code < 1.5 ? float3(1, 0, 0) : code < 2.5 ? float3(1, .5, 0) : code < 3.5 ? float3(1, 1, 0) : code < 4.5 ? float3(0, 1, 0) :
               code < 5.5 ? float3(0, 1, 1) : code < 6.5 ? float3(0, 0, 1) : code < 7.5 ? float3(1, 0, 1) : float3(.5, .5, .5);
    O_Col = float4(c, 1);
}
return wpo;
'''
import os
if os.environ.get('CBA_GPU_DEBUG'):
    m = material('M_CBA_GPUDebug', u.BlendMode.BLEND_ADDITIVE)
    uv = [node(m, u.MaterialExpressionTextureCoordinate, coordinate_index=i) for i in range(4)]
    axes = []
    for v in ((1, 0, 0), (0, 1, 0)):
        c = node(m, u.MaterialExpressionConstant3Vector, constant=u.LinearColor(v[0], v[1], v[2], 0))
        t = node(m, u.MaterialExpressionTransform, transform_source_type=u.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_VIEW,
                 transform_type=u.MaterialVectorCoordTransform.TRANSFORM_WORLD)
        connect(c, '', t, '')
        axes.append(t)
    vin = [('UV0', uv[0], ''), ('UV1', uv[1], ''), ('UV2', uv[2], ''), ('UV3', uv[3], ''), ('VC', node(m, u.MaterialExpressionVertexColor), ''),
           ('Data', texobj(m, 'Data', first_data), ''), ('CamRight', axes[0], ''), ('CamUp', axes[1], '')]
    for n, d in (('Time', 0), ('StopT', 1e6), ('Fade', 1), ('Rate', 30), ('S', 150)):
        vin.append((n, scalar(m, n, d), ''))
    for n, d in (('AxX', (1, 0, 0, 0)), ('AxY', (0, 1, 0, 0)), ('AxZ', (0, 0, 1, 0))):
        vin.append((n, vector(m, n, d), 'RGB'))
    outs = [('O_Col', F4), ('O_Misc', F4), ('O_ST1', F4), ('O_ST2', F4), ('O_ST3', F4)]
    vs = custom(m, VS_DEBUG, vin, F3, outs)
    output(vs, '', m, u.MaterialProperty.MP_WORLD_POSITION_OFFSET)
    i = node(m, u.MaterialExpressionVertexInterpolator)
    connect(vs, 'O_Col', i, 'VS')
    rgb = node(m, u.MaterialExpressionComponentMask, r=True, g=True, b=True, a=False)
    connect(i, '', rgb, '')
    bright = custom(m, 'return C * 3.0;', [('C', rgb, '')], F3)
    output(bright, '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
    lib.recompile_material(m)
    save(m)
    u.log('CBA_GPU_DEBUG_CREATED')

# --- frame history writer (canvas into an RGBA32F render target, 4 rows: origin, x, y, z) ---------
m = u.load_asset(base + '/Materials/M_CBA_FrameWrite')
if m:
    lib.delete_all_material_expressions(m)
else:
    m = tools.create_asset('M_CBA_FrameWrite', base + '/Materials', u.Material, u.MaterialFactoryNew())
m.set_editor_property('shading_model', u.MaterialShadingModel.MSM_UNLIT)
m.set_editor_property('blend_mode', u.BlendMode.BLEND_OPAQUE)
# Ping-pong (DrawMaterialToRenderTarget redraws the whole target): columns Slot .. Slot+Count-1
# (wrapping) get this frame, every other texel is copied from Prev. Count 0 is a plain copy.
row = custom(m, '''
int x = (int)floor(saturate(UV.x) * Size - 0.001);
int y = (int)floor(saturate(UV.y) * 4.0 - 0.001);
int d = x - (int)(Slot + 0.5);
if (d < 0) d += (int)(Size + 0.5);
if (d < (int)(Count + 0.5)) return y == 0 ? V0.xyz : y == 1 ? V1.xyz : y == 2 ? V2.xyz : V3.xyz;
return Prev.Load(int3(x, y, 0)).xyz;
''', [('UV', node(m, u.MaterialExpressionTextureCoordinate), ''), ('Prev', texobj(m, 'Prev', white), ''),
      ('Slot', scalar(m, 'Slot', 0), ''), ('Count', scalar(m, 'Count', 0), ''), ('Size', scalar(m, 'Size', 256), '')] +
    [('V%d' % i, vector(m, 'V%d' % i, (0, 0, 0, 0)), 'RGB') for i in range(4)], F3)
output(row, '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
lib.recompile_material(m)
save(m)
u.log('CBA_GPU_MATERIALS_CREATED')
