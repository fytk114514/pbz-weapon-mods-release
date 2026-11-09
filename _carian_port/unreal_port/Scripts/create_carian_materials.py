"""Carian 2.1 materials: the Elden Ring look drawn with our own shaders, stored inline.

Run by toolchain/build_fx_container.py in a NullRHI commandlet with the captured PBZ uniform
profile (-CBAUniformProfile). The container is cooked with bShareMaterialShaderCode=False, so the
shaders live inside these material packages and no shader library is added to the game (an extra
shader library makes PBZ recompile its pipelines for ~3 min on every launch, see
verification/pso_cache/README.md).

  M_CBA_BladeGlow     additive     Tex x Tint x Emissive                       s88310 glow layer
  M_CBA_BladeBody     translucent  Tex x Tint x Emissive, opacity Tex.a x Opacity  s88300 body; can fade
  M_CBA_FXAdd         additive     atlas x vertex colour x Emissive, hot cores whitened
  M_CBA_FXBlend       translucent  the same, opacity atlas.a x vertex alpha       source blend mode 2
  M_CBA_FXRefraction  translucent  FXBlend + 2D-offset refraction from s64002     the swing's heat haze
  M_CBA_RadialBlur    post process the source GXFfxSoftRadialBlur: 16 taps, RMS, masked by s10011

All are unlit. The runtime imports the PNG textures and sets them as parameters; only the two maps
that need fixed sampling (the distortion normal map and the radial mask) are cooked here.
"""
import unreal as u

base = '/Game/Mods/CarianFX'
SRC = r'<仓库根目录>\_carian_port\eldenring_source\grandeur\editor_import\Textures'
lib = u.MaterialEditingLibrary
tools = u.AssetToolsHelpers.get_asset_tools()
white = u.load_asset('/Engine/EngineResources/WhiteSquareTexture')
assert white


def import_texture(name, source, srgb, normal=False):
    task = u.AssetImportTask()
    task.filename = SRC + '\\' + source
    task.destination_path = base + '/Textures'
    task.destination_name = name
    task.automated = True
    task.replace_existing = True
    task.save = True
    tools.import_asset_tasks([task])
    t = u.load_asset(base + '/Textures/' + name)
    assert isinstance(t, u.Texture2D), name
    t.set_editor_property('srgb', srgb)
    if normal:
        t.set_editor_property('compression_settings', u.TextureCompressionSettings.TC_NORMALMAP)
    assert u.EditorAssetLibrary.save_loaded_asset(t, only_if_is_dirty=False)
    return t


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


def texture(m, name, tex=None, sampler=u.MaterialSamplerType.SAMPLERTYPE_COLOR):
    return node(m, u.MaterialExpressionTextureSampleParameter2D, parameter_name=name, texture=tex or white, sampler_type=sampler)


def scalar(m, name, value):
    return node(m, u.MaterialExpressionScalarParameter, parameter_name=name, default_value=float(value))


def vector(m, name, value):
    return node(m, u.MaterialExpressionVectorParameter, parameter_name=name, default_value=u.LinearColor(*value))


def multiply(m, a, ao, b, bo):
    n = node(m, u.MaterialExpressionMultiply)
    connect(a, ao, n, 'A')
    connect(b, bo, n, 'B')
    return n


def custom(m, code, inputs, kind=u.CustomMaterialOutputType.CMOT_FLOAT3):
    fields = []
    for name, _, _ in inputs:
        f = u.CustomInput()
        f.set_editor_property('input_name', name)
        fields.append(f)
    n = node(m, u.MaterialExpressionCustom, code=code, output_type=kind, inputs=fields)
    for name, src, out in inputs:
        connect(src, out, n, name)
    return n


def exposure(m, src, out, default):
    """Emissive x lerp(1, 1/exposure, ExposureInvariant): 1 keeps the brightness independent of the
    game's eye adaptation (the PBZ FX masters' EyeAdaptionAffect=0 behaviour)."""
    e = node(m, u.MaterialExpressionEyeAdaptationInverse)
    connect_any(src, out, e, ('LightValue', 'Light Value', 'LightValueInput'))
    connect_any(scalar(m, 'ExposureInvariant', default), '', e, ('Alpha', 'AlphaInput'))
    return e


def material(name, blend, domain=None):
    path = base + '/Materials/' + name
    m = u.load_asset(path)
    if m:
        lib.delete_all_material_expressions(m)
    else:
        m = tools.create_asset(name, base + '/Materials', u.Material, u.MaterialFactoryNew())
    assert m, name
    m.set_editor_property('shading_model', u.MaterialShadingModel.MSM_UNLIT)
    m.set_editor_property('blend_mode', blend)
    if domain is None:
        m.set_editor_property('two_sided', True)
    else:
        m.set_editor_property('material_domain', domain)
    return m


def finish(m):
    lib.recompile_material(m)
    assert u.EditorAssetLibrary.save_loaded_asset(m, only_if_is_dirty=False), m.get_name()


normal_map = import_texture('T_CBA_DistortNormal', 's64002_n.png', False, normal=True)
radial_mask = import_texture('T_CBA_RadialMask', 's10011_a.png', True)

# --- the sword: two layers on the s88310 mesh -------------------------------------------------
for name, blend in (('M_CBA_BladeGlow', u.BlendMode.BLEND_ADDITIVE), ('M_CBA_BladeBody', u.BlendMode.BLEND_TRANSLUCENT)):
    m = material(name, blend)
    t = texture(m, 'Tex')
    colour = multiply(m, t, 'RGB', vector(m, 'Tint', (1, 1, 1, 1)), 'RGB')
    colour = multiply(m, colour, '', scalar(m, 'Emissive', 0), '')
    output(exposure(m, colour, '', 0), '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
    if blend == u.BlendMode.BLEND_TRANSLUCENT:
        output(multiply(m, t, 'A', scalar(m, 'Opacity', 1), ''), '', m, u.MaterialProperty.MP_OPACITY)
    finish(m)

# --- baked FXR particles and trails: colour and alpha per vertex --------------------------------
# Vertex RGB is the particle's own FXR colour direction (the runtime squares it like the source PPO,
# rgb = (t x dir)^2 x energy) times its brightness within the batch's emissive level; vertex alpha is
# its opacity. Elden Ring's tonemapper turns the hottest blues white; PBZ's pushes them towards cyan,
# so cores above WhitenStart blend towards white at the same peak.
FX = '''
float3 c = TexRGB * VC * Emissive;
float m = max(c.r, max(c.g, c.b));
float w = Whiten * smoothstep(WhitenStart, max(WhitenEnd, WhitenStart + 0.001), m);
return lerp(c, float3(m, m, m), w);
'''


def fx_material(name, blend, refraction=False):
    m = material(name, blend)
    t = texture(m, 'Tex')
    vc = node(m, u.MaterialExpressionVertexColor)
    if refraction:
        # The source's heat-haze trails only bend the scene behind them. PBZ runs with
        # r.Distortion=0, so UE's distortion pass never draws; instead the trail shows the scene
        # colour behind it (the translucency copy), shifted by the s64002 normal map, over the
        # trail texture's alpha. Its own faint grey is not drawn (in game it became a black sheet).
        # The strip's UVs address the trail's atlas cell; map them back to 0..1 for the normal map.
        uv = custom(m, 'return (UV - Cell.xy) / max(Cell.zw, float2(0.00001, 0.00001)) * Tiling.xy;',
                    [('UV', node(m, u.MaterialExpressionTextureCoordinate), ''), ('Cell', vector(m, 'CellRect', (0, 0, 1, 1)), 'RGBA'),
                     ('Tiling', vector(m, 'NormalTiling', (1, 1, 0, 0)), 'RGBA')], u.CustomMaterialOutputType.CMOT_FLOAT2)
        n = texture(m, 'Normal', normal_map, u.MaterialSamplerType.SAMPLERTYPE_NORMAL)
        connect(uv, '', n, 'UVs')
        offset = custom(m, 'return N.xy * Scale;', [('N', n, 'RGB'), ('Scale', scalar(m, 'RefractionScale', .008), '')],
                        u.CustomMaterialOutputType.CMOT_FLOAT2)
        behind = node(m, u.MaterialExpressionSceneColor, input_mode=u.MaterialSceneAttributeInputMode.OFFSET_FRACTION)
        connect_any(offset, '', behind, ('Offset Fraction', 'OffsetFraction', 'Input', 'UV'))
        rgb = node(m, u.MaterialExpressionComponentMask, r=True, g=True, b=True, a=False)
        connect(behind, '', rgb, '')
        output(rgb, '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
        opacity = custom(m, 'return saturate(A * Mask * Haze);', [('A', vc, 'A'), ('Mask', t, 'A'), ('Haze', scalar(m, 'HazeOpacity', 1), '')],
                         u.CustomMaterialOutputType.CMOT_FLOAT1)
        output(opacity, '', m, u.MaterialProperty.MP_OPACITY)
        finish(m)
        return
    c = custom(m, FX, [('TexRGB', t, 'RGB'), ('VC', vc, ''), ('Emissive', scalar(m, 'Emissive', 0), ''),
                       ('Whiten', scalar(m, 'Whiten', .7), ''), ('WhitenStart', scalar(m, 'WhitenStart', .6), ''),
                       ('WhitenEnd', scalar(m, 'WhitenEnd', 3), '')])
    output(exposure(m, c, '', 1), '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
    if blend == u.BlendMode.BLEND_TRANSLUCENT:
        output(multiply(m, t, 'A', vc, 'A'), '', m, u.MaterialProperty.MP_OPACITY)
    finish(m)


fx_material('M_CBA_FXAdd', u.BlendMode.BLEND_ADDITIVE)
fx_material('M_CBA_FXBlend', u.BlendMode.BLEND_TRANSLUCENT)
fx_material('M_CBA_FXRefraction', u.BlendMode.BLEND_TRANSLUCENT, refraction=True)

# --- radial blur (FXR RadialBlur): post process, after tonemapping ------------------------------
m = material('M_CBA_RadialBlur', u.BlendMode.BLEND_OPAQUE, u.MaterialDomain.MD_POST_PROCESS)
scene = node(m, u.MaterialExpressionSceneTexture, scene_texture_id=u.SceneTextureId.PPI_POST_PROCESS_INPUT0)
blur = custom(m, '''
float2 uv = GetDefaultSceneTextureUV(Parameters, 14);
float2 local = (uv - Center.xy) / max(Extent.xy, float2(0.00001, 0.00001)) + .5;
float alpha = Texture2DSample(Mask, MaskSampler, local).a;
alpha *= step(0.0, local.x) * step(local.x, 1.0) * step(0.0, local.y) * step(local.y, 1.0);
float2 delta = (Center.xy - uv) * Radius;
float3 total = float3(0, 0, 0);
// Source GXFfxSoftRadialBlur_ppo: eight hashed sample positions reused across sixteen taps,
// then sqrt(mean(square(scene colour))).
for (int i = 0; i < 16; i++) {
    float2 start = uv + float(i & 7) * delta * .0625;
    float h = frac(dot(frac(dot(start, float2(630.067138671875, -340.005828857422))).xx, float2(630.067138671875, -340.005828857422)));
    float3 colour = SceneTextureLookup(saturate(uv + h * delta), 14, false).rgb;
    total += colour * colour;
}
float3 blurred = sqrt(total * .0625) * Tint.rgb;
return lerp(Scene.rgb, blurred, saturate(alpha * Strength * Tint.a));
''', [('Scene', scene, 'Color'), ('Center', vector(m, 'Center', (.5, .5, 0, 0)), 'RGBA'),
      ('Extent', vector(m, 'Extent', (.25, .25, 0, 0)), 'RGBA'), ('Radius', scalar(m, 'Radius', .075), ''),
      ('Strength', scalar(m, 'Strength', 0), ''), ('Tint', vector(m, 'Tint', (1, 1, 1, 1)), 'RGBA'),
      ('Mask', node(m, u.MaterialExpressionTextureObjectParameter, parameter_name='Mask', texture=radial_mask), '')])
output(blur, '', m, u.MaterialProperty.MP_EMISSIVE_COLOR)
finish(m)

u.log('CBA_CARIAN_MATERIALS_CREATED')
