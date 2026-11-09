// Bloodborne (PS4) asset reader for the Moonlight port, built on SoulsFormatsNEXT (vendored in the Carian
// tools). The game's files are only read; every output stays inside the Moonlight project.
//   bnd      INPUT OUTPUT [NAME_REGEX]   extract a BND4 binder (.dcx is decompressed on read) + binder_index.json
//   fmg      INPUT OUTPUT                text entries as JSON
//   paramraw INPUT OUTPUT                PARAM rows as raw hex (Bloodborne has no paramdef in this workspace)
//   tpf      INPUT OUTPUT                textures as DDS (PS4 tiling removed by SoulsFormats/DrSwizzler) + JSON
//   flver    INPUT OUTPUT                FLVER2 nodes, dummies, materials, buffer layouts and meshes as JSON
//   param    PARAMBND OUTPUT PARAMDEFBND [NAME_REGEX]   params decoded with the game's own paramdefs, as JSON
//   tae      ANIBND OUTPUT [NAME_REGEX]  TAE animation events (type, times, raw parameters) as JSON
// Bloodborne's effect files (FXR version 2) are read by toolchain/bb_sfx/bbfxr.py: SoulsFormats' FXR1 (DS1)
// reader does not fit them (other root, container and node layouts).
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using SF = SoulsFormats;

if (args.Length < 3) throw new ArgumentException("Usage: bnd|fmg|paramraw|tpf|flver|param|tae INPUT OUTPUT [...]");
string input = Path.GetFullPath(args[1]), output = Path.GetFullPath(args[2]);
const string project = @"<仓库根目录>\_moonlight_port\";
if (!output.StartsWith(project, StringComparison.OrdinalIgnoreCase))
    throw new ArgumentException("Output must remain inside the Moonlight project.");
Directory.CreateDirectory(output);
var jsonOptions = new JsonSerializerOptions { WriteIndented = true, IncludeFields = true };
void Json(string path, object value) => File.WriteAllText(path, JsonSerializer.Serialize(value, jsonOptions));
string Hash(byte[] b) => Convert.ToHexString(SHA256.HashData(b));
string Out(string name) => Path.Combine(output, name);

switch (args[0])
{
    case "bnd":
    {
        var bnd = SF.BND4.Read(input);
        var filter = new Regex(args.Length > 3 ? args[3] : ".*", RegexOptions.IgnoreCase);
        var index = new List<object>();
        foreach (var file in bnd.Files)
        {
            string basename = Path.GetFileName(file.Name.Replace('\\', '/'));
            bool selected = filter.IsMatch(file.Name);
            index.Add(new { file.ID, file.Name, Bytes = file.Bytes.Length, Extracted = selected, SHA256 = Hash(file.Bytes) });
            if (!selected) continue;
            string target = Out(basename);
            if (File.Exists(target) && Hash(File.ReadAllBytes(target)) != Hash(file.Bytes))
                throw new IOException("Binder basename collision: " + target);
            File.WriteAllBytes(target, file.Bytes);
        }
        Json(Out("binder_index.json"), index);
        Console.WriteLine($"BND {Path.GetFileName(input)}: {bnd.Files.Count} files, {index.Count(i => ((dynamic)i).Extracted)} extracted");
        break;
    }
    case "fmg":
    {
        var fmg = SF.FMG.Read(input);
        Json(Out(Path.GetFileName(input) + ".json"), fmg.Entries.Select(e => new { e.ID, e.Text }));
        Console.WriteLine($"FMG {Path.GetFileName(input)}: {fmg.Entries.Count} entries");
        break;
    }
    case "paramraw":
    {
        var param = SF.PARAM.Read(input);
        var reader = (SF.BinaryReaderEx)typeof(SF.PARAM).GetField("RowReader", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(param)!;
        var offset = typeof(SF.PARAM.Row).GetField("DataOffset", BindingFlags.NonPublic | BindingFlags.Instance)!;
        long size = param.DetectedSize;
        if (size <= 0) throw new InvalidDataException("row size not detected: " + size);
        Json(Out(Path.GetFileName(input) + ".json"), new {
            param.ParamType, RowSize = size, BigEndian = param.BigEndian, Format2D = param.Format2D.ToString(),
            Rows = param.Rows.Select(r => new { r.ID, r.Name, Data = Convert.ToHexString(reader.GetBytes((long)offset.GetValue(r)!, (int)size)) })
        });
        Console.WriteLine($"PARAM {param.ParamType}: {param.Rows.Count} rows of {size} bytes");
        break;
    }
    case "tpf":
    {
        var tpf = SF.TPF.Read(input);
        var list = new List<object>();
        foreach (var tex in tpf.Textures)
        {
            byte[] dds = tex.HeaderizeExt(out string extension);
            File.WriteAllBytes(Out(tex.Name + extension), dds);
            list.Add(new { tex.Name, tex.Format, Type = tex.Type.ToString(), tex.Mipmaps, Platform = tpf.Platform.ToString(),
                Width = tex.Header?.Width, Height = tex.Header?.Height, Bytes = tex.Bytes.Length, Output = tex.Name + extension });
        }
        Json(Out(Path.GetFileName(input) + ".json"), list);
        Console.WriteLine($"TPF {Path.GetFileName(input)}: {tpf.Textures.Count} textures, platform {tpf.Platform}");
        break;
    }
    case "flver":
    {
        var model = SF.FLVER2.Read(input);
        Json(Out(Path.GetFileName(input) + ".json"), new {
            Header = model.Header,
            Nodes = model.Nodes,
            Dummies = model.Dummies,
            Materials = model.Materials,
            BufferLayouts = model.BufferLayouts.Select(l => l.Select(m => new { Type = m.Type.ToString(), Semantic = m.Semantic.ToString(), m.Index })),
            Meshes = model.Meshes.Select(m => new {
                m.MaterialIndex, m.NodeIndex, m.UseBoneWeights, m.BoneIndices, m.Dynamic,
                VertexBuffers = m.VertexBuffers.Select(b => b.LayoutIndex),
                Vertices = m.Vertices.Select(v => new { v.Position, v.Normal, v.NormalW, v.UVs, v.Tangents, v.Bitangent, v.Colors, v.BoneIndices, v.BoneWeights }),
                FaceSets = m.FaceSets.Select(f => new { Flags = f.Flags.ToString(), f.CullBackfaces, f.TriangleStrip, Triangles = f.Triangulate(true) })
            })
        });
        Console.WriteLine($"FLVER {Path.GetFileName(input)}: {model.Meshes.Count} meshes, {model.Meshes.Sum(m => m.Vertices.Count)} vertices, {model.Materials.Count} materials, {model.Dummies.Count} dummies");
        break;
    }
    case "param":
    {
        if (args.Length < 4) throw new ArgumentException("param PARAMBND OUTPUT PARAMDEFBND [NAME_REGEX]");
        var defs = new List<SF.PARAMDEF>();
        foreach (var f in SF.BND4.Read(Path.GetFullPath(args[3])).Files)
        {
            try { defs.Add(SF.PARAMDEF.Read(f.Bytes)); } catch (Exception e) { Console.WriteLine("paramdef skipped: " + f.Name + " " + e.Message); }
        }
        var filter = new Regex(args.Length > 4 ? args[4] : ".*", RegexOptions.IgnoreCase);
        int written = 0;
        foreach (var file in SF.BND4.Read(input).Files)
        {
            if (!filter.IsMatch(file.Name)) continue;
            var param = SF.PARAM.Read(file.Bytes);
            if (!param.ApplyParamdefCarefully(defs)) { Console.WriteLine($"no matching paramdef: {file.Name} ({param.ParamType})"); continue; }
            Json(Out(Path.GetFileName(file.Name.Replace('\\', '/')) + ".json"), new {
                param.ParamType,
                Rows = param.Rows.Select(r => new { r.ID, r.Name, Cells = r.Cells.ToDictionary(c => c.Def.InternalName, c => c.Value) })
            });
            written++;
        }
        Console.WriteLine($"PARAM: {written} params decoded with {defs.Count} paramdefs");
        break;
    }
    case "tae":
    {
        var filter = new Regex(args.Length > 3 ? args[3] : @"\.tae$", RegexOptions.IgnoreCase);
        int written = 0, events = 0;
        foreach (var file in SF.BND4.Read(input).Files)
        {
            if (!filter.IsMatch(file.Name)) continue;
            var tae = SF.TAE.Read(file.Bytes);
            Json(Out(Path.GetFileName(file.Name.Replace('\\', '/')) + ".json"), new {
                tae.ID, Format = tae.Format.ToString(), tae.BigEndian,
                Animations = tae.Animations.Select(a => new {
                    a.ID, a.AnimFileName,
                    Events = a.Events.Select(e => new { e.Type, e.StartTime, e.EndTime, Params = Convert.ToHexString(e.GetParameterBytes(tae.BigEndian)) })
                })
            });
            written++; events += tae.Animations.Sum(a => a.Events.Count);
        }
        Console.WriteLine($"TAE: {written} files, {events} events");
        break;
    }
    default: throw new ArgumentException("Unknown command: " + args[0]);
}
