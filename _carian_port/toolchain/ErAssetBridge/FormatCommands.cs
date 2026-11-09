using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using SF = SoulsFormats;

static class FormatCommands
{
    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, IncludeFields = true };
    static void Json(string path, object value) => File.WriteAllText(path, JsonSerializer.Serialize(value, JsonOptions));
    static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    public static void Run(string[] args)
    {
        if (args.Length < 3) throw new ArgumentException("Usage: COMMAND INPUT OUTPUT [FILTER/DEFS]");
        SF.Oodle.SearchPaths.Add(@"<ELDEN RING 安装目录>\Game");
        string input = Path.GetFullPath(args[1]), output = Path.GetFullPath(args[2]);
        if (!output.StartsWith(@"<仓库根目录>\_carian_port\", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Output must remain inside the Carian project.");
        Directory.CreateDirectory(output);
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
                    string category = Path.GetExtension(basename).TrimStart('.');
                    if (category == "") category = "other";
                    string relative = category + "/" + basename;
                    bool selected = filter.IsMatch(file.Name);
                    index.Add(new { file.ID, file.Name, Bytes = file.Bytes.Length, Output = relative, Extracted = selected, SHA256 = Hash(file.Bytes) });
                    if (!selected) continue;
                    string target = Path.Combine(output, relative);
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    if (File.Exists(target) && Hash(File.ReadAllBytes(target)) != Hash(file.Bytes))
                        throw new IOException("Binder basename collision: " + target);
                    File.WriteAllBytes(target, file.Bytes);
                }
                Json(Path.Combine(output, "binder_index.json"), index);
                Console.WriteLine($"BND {input}: {bnd.Files.Count} files indexed");
                break;
            }
            case "tae":
            {
                var tae = SF.TAE.Read(input);
                var animations = tae.Animations.Select(a => new {
                    a.ID, a.AnimFileName, Events = a.Events.Select(e => {
                        var bytes = e.GetParameterBytes(tae.BigEndian);
                        return new { e.Type, e.StartTime, e.EndTime, Hex = Convert.ToHexString(bytes),
                            Ints = Enumerable.Range(0, bytes.Length / 4).Select(i => BitConverter.ToInt32(bytes, i * 4)).ToArray() };
                    }).ToArray()
                }).ToArray();
                Json(Path.Combine(output, Path.GetFileName(input) + ".json"), new { tae.ID, Format = tae.Format.ToString(), Animations = animations });
                Console.WriteLine($"TAE {input}: {animations.Length} animations");
                break;
            }
            case "fmg":
            {
                var fmg = SF.FMG.Read(input);
                Json(Path.Combine(output, Path.GetFileName(input) + ".json"), fmg.Entries.Select(e => new { e.ID, e.Text }));
                Console.WriteLine($"FMG {input}: {fmg.Entries.Count} entries");
                break;
            }
            case "regulation":
            {
                var bnd = SF.Cryptography.RegulationDecryptor.DecryptERRegulation(input);
                var filter = new Regex(args.Length > 3 ? args[3] : ".*", RegexOptions.IgnoreCase);
                foreach (var file in bnd.Files.Where(f => filter.IsMatch(f.Name)))
                    File.WriteAllBytes(Path.Combine(output, Path.GetFileName(file.Name.Replace('\\', '/'))), file.Bytes);
                Json(Path.Combine(output, "regulation_index.json"), bnd.Files.Select(f => new { f.Name, Bytes = f.Bytes.Length, SHA256 = Hash(f.Bytes) }));
                Console.WriteLine($"REGULATION {bnd.Version}: {bnd.Files.Count} parameters");
                break;
            }
            case "param":
            {
                if (args.Length != 4) throw new ArgumentException("param requires a PARAMDEF XML path");
                var param = SF.PARAM.Read(input);
                var def = SF.PARAMDEF.XmlDeserialize(args[3]);
                if (!param.ApplyParamdefCarefully(def)) throw new InvalidDataException("PARAMDEF mismatch: " + input);
                Json(Path.Combine(output, Path.GetFileName(input) + ".json"), new { param.ParamType, Rows = param.Rows.Select(r => new {
                    r.ID, r.Name, Values = r.Cells.ToDictionary(c => c.Def.InternalName, c => c.Value)
                }) });
                Console.WriteLine($"PARAM {input}: {param.Rows.Count} rows");
                break;
            }
            case "tpf":
            {
                var tpf = SF.TPF.Read(input);
                foreach (var tex in tpf.Textures)
                {
                    byte[] dds = tex.HeaderizeExt(out string extension);
                    File.WriteAllBytes(Path.Combine(output, tex.Name + extension), dds);
                }
                Json(Path.Combine(output, Path.GetFileName(input) + ".json"), tpf.Textures.Select(t => new { t.Name, t.Format, Bytes = t.Bytes.Length }));
                Console.WriteLine($"TPF {input}: {tpf.Textures.Count} textures");
                break;
            }
            case "flver":
            {
                var model = SF.FLVER2.Read(input);
                Json(Path.Combine(output, Path.GetFileName(input) + ".json"), new {
                    Header = model.Header,
                    Nodes = model.Nodes,
                    Materials = model.Materials,
                    Meshes = model.Meshes.Select(m => new {
                        m.MaterialIndex, m.NodeIndex, m.UseBoneWeights, m.BoneIndices,
                        Vertices = m.Vertices.Select(v => new { v.Position, v.Normal, v.NormalW, v.UVs, v.Tangents, v.Colors }),
                        FaceSets = m.FaceSets.Select(f => new { Flags = f.Flags.ToString(), f.CullBackfaces, Triangles = f.Triangulate(true) })
                    })
                });
                Console.WriteLine($"FLVER {input}: {model.Meshes.Count} meshes, {model.Meshes.Sum(m=>m.Vertices.Count)} vertices");
                break;
            }
            case "matbin":
                Json(Path.Combine(output, Path.GetFileName(input) + ".json"), SF.MATBIN.Read(input));
                Console.WriteLine("MATBIN " + input);
                break;
            default: throw new ArgumentException("Unknown format command: " + args[0]);
        }
    }
}
