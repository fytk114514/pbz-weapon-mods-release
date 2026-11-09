using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Coremats;

if (args.Length > 0 && args[0] != "extract" && args[0] != "find-effect") { FormatCommands.Run(args); return; }

// Archive reading follows Nuxe's UnpackOperation (GPL-3.0). The installed game
// is opened read-only and output is restricted to the Carian project's staging.
if ((args.Length != 4 && args.Length != 5) || (args[0] != "extract" && args[0] != "find-effect"))
    throw new ArgumentException("Usage: extract GAME_DIR OUTPUT_DIR PATH_REGEX [ARCHIVES, e.g. sd/sd,sd/sd_dlc02]");
string game = Path.GetFullPath(args[1]);
string output = Path.GetFullPath(args[2]);
string project = @"<仓库根目录>\_carian_port";
if (!output.StartsWith(project + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
    throw new ArgumentException("Output must remain in the Carian project.");
Directory.CreateDirectory(output);
string keys = Path.Combine(project, @"tools\Nuxe\dist\res\BinderKeys\EldenRing_PC");
bool probe = args[0] == "find-effect";
var query = new Regex(args[3], RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
var filter = probe ? new Regex(@"^/sfx/.*\.ffxbnd\.dcx$", RegexOptions.IgnoreCase) : query;
if (probe) SoulsFormats.Oodle.SearchPaths.Add(game);
var inventory = new List<object>();
var extracted = new List<object>();
int searched = 0;
// Optional 5th argument: archives relative to the game folder (the sound
// archives live in sd/: sd/sd, sd/sd_dlc02). Keys and name lists use the base name.
string[] archives = args.Length == 5 ? args[4].Split(',', StringSplitOptions.RemoveEmptyEntries) : new[] { "Data0", "Data1", "Data2", "Data3", "DLC" };
foreach (string archivePath in archives)
{
    string archive = Path.GetFileName(archivePath);
    string headerPath = Path.Combine(game, archivePath + ".bhd");
    string dataPath = Path.Combine(game, archivePath + ".bdt");
    if (!File.Exists(headerPath) || !File.Exists(dataPath))
        throw new FileNotFoundException("Missing source archive pair: " + archive);
    byte[] headerBytes = File.ReadAllBytes(headerPath);
    var originalHeaderHash = Convert.ToHexString(SHA256.HashData(headerBytes));
    if (!BHD5.Is(headerBytes))
        headerBytes = Coremats.Crypto.Binder5.DecryptBhd(headerBytes, File.ReadAllText(Path.Combine(keys, "Key", archive + ".pem")));
    var header = BHD5.Read(headerBytes, BHD5.Bhd5Format.EldenRing);
    var names = new Dictionary<ulong, string>();
    foreach (string line in File.ReadLines(Path.Combine(keys, "Hash", archive + ".txt")))
    {
        if (string.IsNullOrWhiteSpace(line)) continue;
        string name = line.Trim().Replace('\\', '/').ToLowerInvariant();
        if (!name.StartsWith('/')) name = '/' + name;
        ulong hash = 0;
        unchecked { foreach (char c in name) hash = hash * 133 + c; }
        names[hash] = name;
    }
    int known = 0, total = 0;
    using var data = File.OpenRead(dataPath);
    foreach (var file in header.Buckets.SelectMany(b => b).OrderBy(f => f.DataOffset))
    {
        total++;
        if (!names.TryGetValue(file.PathHash, out string? name)) continue;
        known++;
        inventory.Add(new { Archive = archive, Path = name, Bytes = file.DataLength, Offset = file.DataOffset });
        if (!filter.IsMatch(name)) continue;
        string target = Path.GetFullPath(Path.Combine(output, name.TrimStart('/').Replace('/', Path.DirectorySeparatorChar)));
        if (!target.StartsWith(output + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Unsafe source name: " + name);
        byte[] bytes = new byte[file.DataLength];
        data.Position = file.DataOffset;
        data.ReadExactly(bytes);
        if (file.Encryption != null)
        {
            using var aes = Aes.Create();
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            aes.Key = file.Encryption.Key;
            foreach (var range in file.Encryption.Ranges.Where(r => r.Start != -1 && r.End != -1 && r.Start != r.End))
            {
                var span = bytes.AsSpan(checked((int)range.Start), checked((int)(range.End - range.Start)));
                aes.DecryptEcb(span, span, PaddingMode.None);
            }
        }
        int length = file.UnpaddedDataLength != 0 ? file.UnpaddedDataLength : file.DataLength;
        var final = bytes.AsSpan(0, length);
        string digest = Convert.ToHexString(SHA256.HashData(final));
        if (probe)
        {
            var binder = SoulsFormats.BND4.Read(final.ToArray());
            searched++;
            foreach (var match in binder.Files.Where(f => query.IsMatch(f.Name)))
            {
                string pack = Path.GetFileNameWithoutExtension(Path.GetFileNameWithoutExtension(name));
                string matchTarget = Path.Combine(output, "effect_search", pack, Path.GetFileName(match.Name.Replace('\\', '/')));
                Directory.CreateDirectory(Path.GetDirectoryName(matchTarget)!);
                File.WriteAllBytes(matchTarget, match.Bytes);
                extracted.Add(new { Package = name, Entry = match.Name, Bytes = match.Bytes.Length,
                    SHA256 = Convert.ToHexString(SHA256.HashData(match.Bytes)), Output = matchTarget });
                Console.WriteLine($"FOUND {name} -> {match.Name}");
            }
            continue;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        if (File.Exists(target))
        {
            if (Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(target))) != digest)
                throw new IOException("Existing extraction differs: " + target);
        }
        else File.WriteAllBytes(target, final);
        extracted.Add(new { Archive = archive, Path = name, Bytes = length, SHA256 = digest });
        Console.WriteLine($"EXTRACT {archive} {name} {length:N0} bytes");
    }
    Console.WriteLine($"INDEX {archive}: {known}/{total} names; BHD SHA256 {originalHeaderHash}");
}
var options = new JsonSerializerOptions { WriteIndented = true };
File.WriteAllText(Path.Combine(output, "archive_index.json"), JsonSerializer.Serialize(inventory, options));
string manifest = Path.Combine(output, (probe ? "effect_search_" : "extraction_") + DateTime.UtcNow.ToString("yyyyMMdd_HHmmss") + ".json");
if (probe) File.WriteAllText(manifest, JsonSerializer.Serialize(new { Query = args[3], SearchedBinders = searched, Matches = extracted }, options));
else File.WriteAllText(manifest, JsonSerializer.Serialize(extracted, options));
Console.WriteLine($"DONE {extracted.Count} extracted files; manifest {manifest}");
