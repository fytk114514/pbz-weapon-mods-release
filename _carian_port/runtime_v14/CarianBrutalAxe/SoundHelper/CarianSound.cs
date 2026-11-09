// CarianSound: plays the Elden Ring "Carian Grandeur" clips for the
// CarianBrutalAxe mod (2.0.1).
//
// Phantom Blade Zero plays all of its audio through Wwise and keeps Unreal's
// own audio device switched off, so a script mod cannot play new sounds inside
// the game. This small helper is started by the mod, loads the decoded clips
// (Sounds\*.wav next to this program), mixes them in software and plays them
// with the Windows waveOut API (48 kHz stereo, 4 x 10 ms buffers, woken by the
// device, MMCSS "Pro Audio" priority). The clips are rendered at 48 kHz too, so
// every sample is played as it is, with no interpolation and no resampling by
// Windows. The mod sends one text command per line over the named
// pipe \\.\pipe\CarianSound_PBZ:
//   P <voice> <clip> <volume> <pan> [rate [seconds [loop]]]  start a clip (pan -1 left .. 1 right;
//                                     rate 1 = as recorded, other rates only in the optional
//                                     Wwise-pitch mode; seconds > 0 ends the clip there; loop 1 =
//                                     repeat between the WAV's smpl loop points until faded out,
//                                     like a Wwise sound with Loop set)
//   V <voice> <volume> <pan>          update a playing voice (smoothed)
//   F <voice> <seconds>               fade a voice out and drop it
//   X <seconds>                       fade every voice out
//   M <volume>                        master volume
// It exits when no PBZ.exe process is left, and only one instance runs.
// Build: %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize CarianSound.cs
//
// 2.2: the same source also runs without the program: CarianSound.ps1 has Windows' own
// PowerShell compile this file at start (Add-Type) and call Main with --host-script, so a
// package may leave CarianSound.exe out (audio.lua then starts CarianSound.vbs, which starts
// the script hidden). Hosted, the files are found next to the script (--base), and the copies
// that hung while PowerShell started are found by their command line and ended.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class CarianSound
{
    // 48 kHz: the shared-mode mix rate of Windows audio devices, so Windows does
    // not resample the stream again (the clips are rendered at 48 kHz offline)
    const int Rate = 48000, Block = 480, Buffers = 4;
    const string PipeName = "CarianSound_PBZ";
    static readonly double Sqrt2 = Math.Sqrt(2);          // constant-power pan: unity gain per side at centre
    const int CALLBACK_EVENT = 0x00050000;
    [DllImport("winmm.dll")] static extern int timeBeginPeriod(int ms);
    [DllImport("winmm.dll")] static extern int timeEndPeriod(int ms);
    [DllImport("avrt.dll", CharSet = CharSet.Unicode)] static extern IntPtr AvSetMmThreadCharacteristics(string task, ref int index);
    [DllImport("avrt.dll")] static extern bool AvRevertMmThreadCharacteristics(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    struct WaveFormat { public short Tag, Channels; public int SamplesPerSec, AvgBytesPerSec; public short BlockAlign, BitsPerSample, Size; }
    [StructLayout(LayoutKind.Sequential)]
    struct WaveHeader { public IntPtr Data; public int BufferLength, BytesRecorded; public IntPtr User; public int Flags, Loops; public IntPtr Next, Reserved; }
    [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr handle, int device, ref WaveFormat format, IntPtr callback, IntPtr instance, int flags);
    [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr handle, IntPtr header, int size);
    [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr handle, IntPtr header, int size);
    [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr handle, IntPtr header, int size);
    [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr handle);
    const int WHDR_DONE = 1;

    // LoopStart / LoopEnd: first smpl loop, inclusive, in clip samples (whole clip if none)
    class Clip { public float[] Samples; public double Step; public int Rate, LoopStart, LoopEnd; }
    class Voice
    {
        public Clip Clip; public double Pos, Step, Limit = double.MaxValue; public bool Loop;
        public float Volume, Target, Pan, PanTarget, Gain = 1, Fade;
    }

    static readonly Dictionary<string, Clip> clips = new Dictionary<string, Clip>();
    static readonly Dictionary<int, Voice> voices = new Dictionary<int, Voice>();
    static readonly ConcurrentQueue<string> commands = new ConcurrentQueue<string>();
    // master follows masterTarget smoothly (in-game slider changes never click);
    // the first M of a session applies at once
    static float master = 1, masterTarget = 1;
    static bool masterSet;
    static volatile bool running = true;
    static string logPath;

    static void Log(string s)
    {
        if (logPath == null) return;                         // --render
        try { File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + s + Environment.NewLine); } catch { }
    }

    static Clip LoadWav(string path)
    {
        byte[] b = File.ReadAllBytes(path);
        int channels = 1, rate = 44100, bits = 16, data = -1, length = 0, loopStart = -1, loopEnd = -1;
        for (int o = 12; o + 8 <= b.Length;)
        {
            string id = System.Text.Encoding.ASCII.GetString(b, o, 4);
            int size = BitConverter.ToInt32(b, o + 4);
            if (id == "fmt ") { channels = BitConverter.ToInt16(b, o + 10); rate = BitConverter.ToInt32(b, o + 12); bits = BitConverter.ToInt16(b, o + 22); }
            else if (id == "data") { data = o + 8; length = Math.Min(size, b.Length - data); }
            else if (id == "smpl" && size >= 60 && BitConverter.ToInt32(b, o + 8 + 28) > 0)
            {
                loopStart = BitConverter.ToInt32(b, o + 8 + 44);      // first loop: start, end (inclusive)
                loopEnd = BitConverter.ToInt32(b, o + 8 + 48);
            }
            o += 8 + size + (size & 1);
        }
        if (data < 0 || bits != 16) throw new InvalidDataException("16-bit PCM WAV expected: " + path);
        int frames = length / (2 * channels);
        var s = new float[frames];
        for (int i = 0; i < frames; i++)
        {
            float sum = 0;
            for (int c = 0; c < channels; c++) sum += BitConverter.ToInt16(b, data + (i * channels + c) * 2) / 32768f;
            s[i] = sum / channels;
        }
        if (loopStart < 0 || loopEnd <= loopStart || loopEnd >= frames) { loopStart = 0; loopEnd = frames - 1; }
        return new Clip { Samples = s, Step = rate / (double)Rate, Rate = rate, LoopStart = loopStart, LoopEnd = loopEnd };
    }

    static float F(string s) { return float.Parse(s, CultureInfo.InvariantCulture); }

    static void Apply(string line)
    {
        string[] a = line.Split(' ');
        if (a.Length == 0) return;
        switch (a[0])
        {
            case "P":
                if (a.Length >= 5)
                {
                    Clip c;
                    if (clips.TryGetValue(a[2], out c))
                    {
                        float v = F(a[3]), p = F(a[4]);
                        double rate = a.Length >= 6 ? Math.Max(0.1, Math.Min(4, F(a[5]))) : 1;
                        double seconds = a.Length >= 7 ? F(a[6]) : 0;
                        var voice = new Voice { Clip = c, Step = c.Step * rate, Volume = v, Target = v, Pan = p, PanTarget = p,
                            Loop = a.Length >= 8 && a[7] == "1" };
                        if (seconds > 0) voice.Limit = seconds * c.Rate;     // in clip samples
                        voices[int.Parse(a[1])] = voice;
                    }
                }
                break;
            case "V":
                if (a.Length >= 4)
                {
                    Voice v;
                    if (voices.TryGetValue(int.Parse(a[1]), out v)) { v.Target = F(a[2]); v.PanTarget = F(a[3]); }
                }
                break;
            case "F":
                if (a.Length >= 3)
                {
                    Voice v;
                    if (voices.TryGetValue(int.Parse(a[1]), out v)) v.Fade = 1f / Math.Max(1, F(a[2]) * Rate);
                }
                break;
            case "X":
                if (a.Length >= 2)
                {
                    float rate = 1f / Math.Max(1, F(a[1]) * Rate);
                    foreach (var v in voices.Values) v.Fade = rate;
                }
                break;
            case "M":
                if (a.Length >= 2)
                {
                    masterTarget = Math.Max(0, F(a[1]));
                    if (!masterSet) { master = masterTarget; masterSet = true; }
                }
                break;
            case "Q":
                running = false;
                break;
        }
    }

    static void Mix(short[] output, float[] left, float[] right)
    {
        // nothing playing (most of the time): a silent block, no per-sample work
        if (voices.Count == 0)
        {
            Array.Clear(output, 0, output.Length);
            master = masterTarget;
            return;
        }
        Array.Clear(left, 0, Block); Array.Clear(right, 0, Block);
        var done = new List<int>();
        foreach (var kv in voices)
        {
            var v = kv.Value;
            var c = v.Clip;
            float[] s = c.Samples;
            bool exact = v.Step == 1.0;          // as recorded: sample for sample
            int loopLength = c.LoopEnd + 1 - c.LoopStart;
            for (int i = 0; i < Block; i++)
            {
                // smoothed volume and pan, constant-power pan law
                v.Volume += (v.Target - v.Volume) * 0.002f;
                v.Pan += (v.PanTarget - v.Pan) * 0.002f;
                if (v.Pos >= v.Limit && v.Fade == 0) v.Fade = 1f / (0.02f * Rate);   // requested length reached
                if (v.Fade > 0) { v.Gain -= v.Fade; if (v.Gain <= 0) { v.Gain = 0; break; } }
                int k = (int)v.Pos;
                if (k >= s.Length) break;
                float x;
                if (exact) x = s[k];
                else
                {
                    // other rates (optional Wwise-pitch mode): Catmull-Rom interpolation,
                    // reading across the loop seam when the voice loops
                    float t = (float)(v.Pos - k);
                    float p0 = At(v, k - 1), p1 = s[k], p2 = At(v, k + 1), p3 = At(v, k + 2);
                    x = p1 + 0.5f * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
                }
                x *= v.Volume * v.Gain;
                double angle = (Math.Max(-1, Math.Min(1, v.Pan)) + 1) * Math.PI / 4;
                left[i] += x * (float)(Math.Cos(angle) * Sqrt2);
                right[i] += x * (float)(Math.Sin(angle) * Sqrt2);
                v.Pos += v.Step;
                if (v.Loop && v.Pos >= c.LoopEnd + 1) v.Pos -= loopLength;      // Wwise-style loop
            }
            if (v.Gain <= 0 || v.Pos >= s.Length) done.Add(kv.Key);
        }
        foreach (int id in done) voices.Remove(id);
        for (int i = 0; i < Block; i++)
        {
            master += (masterTarget - master) * 0.002f;
            output[2 * i] = Limit(left[i] * master); output[2 * i + 1] = Limit(right[i] * master);
        }
    }

    // sample k of a voice's clip: wraps into the loop when the voice loops, silence past the ends
    static float At(Voice v, int k)
    {
        var c = v.Clip;
        if (v.Loop && k > c.LoopEnd) k = c.LoopStart + (k - c.LoopEnd - 1) % (c.LoopEnd + 1 - c.LoopStart);
        return k >= 0 && k < c.Samples.Length ? c.Samples[k] : 0;
    }

    // Master bus: untouched up to 0.8 of full scale (no colouring at normal
    // levels); above that a smooth knee keeps layered peaks from clipping.
    static short Limit(float x)
    {
        float a = Math.Abs(x);
        if (a > 0.8f) a = 0.8f + 0.2f * (float)Math.Tanh((a - 0.8f) / 0.2f);
        double v = Math.Round(Math.Sign(x) * a * 32768.0);
        return (short)Math.Max(-32768, Math.Min(32767, v));
    }

    static void PipeLoop()
    {
        while (running)
        {
            try
            {
                using (var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte))
                {
                    server.WaitForConnection();
                    Log("mod connected");
                    using (var reader = new StreamReader(server))
                    {
                        string line;
                        while (running && (line = reader.ReadLine()) != null)
                            if (line.Length > 0) commands.Enqueue(line);
                    }
                    Log("mod disconnected");
                    commands.Enqueue("X 0.2");
                }
            }
            catch (Exception e) { Log("pipe: " + e.Message); Thread.Sleep(500); }
        }
    }

    static void LoadClips(string dir)
    {
        foreach (string f in Directory.GetFiles(dir, "*.wav"))
        {
            try { clips[Path.GetFileNameWithoutExtension(f)] = LoadWav(f); }
            catch (Exception e) { Log("clip " + f + ": " + e.Message); }
        }
    }

    // QA only: mix a timed command script offline into a 16-bit stereo WAV, with
    // the same mixer and no audio device, pipe or game check.
    //   CarianSound.exe --render <out.wav> <seconds> <script.txt> [--dir <Sounds>]
    // Script lines: "<time in seconds> <command>", applied at 10 ms block
    // boundaries like the live helper.
    static int Render(string outPath, double seconds, string scriptPath)
    {
        var script = new List<KeyValuePair<double, string>>();
        foreach (string line in File.ReadAllLines(scriptPath))
        {
            string l = line.Trim();
            if (l.Length == 0 || l[0] == '#') continue;
            int sp = l.IndexOf(' ');
            script.Add(new KeyValuePair<double, string>(double.Parse(l.Substring(0, sp), CultureInfo.InvariantCulture), l.Substring(sp + 1)));
        }
        script.Sort((x, y) => x.Key.CompareTo(y.Key));
        int blocks = (int)Math.Ceiling(seconds * Rate / Block), next = 0;
        var output = new short[Block * 2];
        var left = new float[Block]; var right = new float[Block];
        using (var f = new BinaryWriter(File.Create(outPath)))
        {
            int bytes = blocks * Block * 4;
            f.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); f.Write(36 + bytes);
            f.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); f.Write(16);
            f.Write((short)1); f.Write((short)2); f.Write(Rate); f.Write(Rate * 4); f.Write((short)4); f.Write((short)16);
            f.Write(System.Text.Encoding.ASCII.GetBytes("data")); f.Write(bytes);
            for (int b = 0; b < blocks; b++)
            {
                double t = b * (double)Block / Rate;
                while (next < script.Count && script[next].Key <= t + 1e-9) Apply(script[next++].Value);
                Mix(output, left, right);
                foreach (short s in output) f.Write(s);
            }
        }
        return 0;
    }

    [STAThread]
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    // Executable path of a process at any stage (module lists are empty while it is still starting).
    static string ImagePath(Process p)
    {
        var name = new StringBuilder(1024);
        int size = name.Capacity;
        return QueryFullProcessImageName(p.Handle, 0, name, ref size) ? name.ToString(0, size) : null;
    }

    // Copies of the PowerShell host (powershell.exe running hostScript) other than this process:
    // a copy that hung while PowerShell started never ran any code, so its command line is all
    // there is to recognise it by.
    static int EndHungHosts(string hostScript)
    {
        int ended = 0, me = Process.GetCurrentProcess().Id;
        using (var q = new System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'"))
        {
            foreach (System.Management.ManagementBaseObject o in q.Get())
            {
                int pid = Convert.ToInt32(o["ProcessId"]);
                string line = o["CommandLine"] as string;
                if (pid == me || line == null || line.IndexOf(hostScript, StringComparison.OrdinalIgnoreCase) < 0) continue;
                try { Process.GetProcessById(pid).Kill(); ended++; } catch { }
            }
        }
        return ended;
    }

    public static int Main(string[] args)
    {
        // --base <folder>: where this program's files are (default: the program's own folder);
        // --host-script <CarianSound.ps1>: run by the PowerShell host (base = the script's folder)
        string baseDir = AppDomain.CurrentDomain.BaseDirectory, hostScript = null, dir = null;
        int render = -1;
        for (int i = 0; i < args.Length; i++)
        {
            if (i + 1 < args.Length && args[i] == "--dir") dir = args[i + 1];
            else if (i + 1 < args.Length && args[i] == "--base") baseDir = args[i + 1];
            else if (i + 1 < args.Length && args[i] == "--host-script") { hostScript = Path.GetFullPath(args[i + 1]); baseDir = Path.GetDirectoryName(hostScript); }
            else if (i + 3 < args.Length && args[i] == "--render") render = i;
        }
        if (dir == null) dir = Path.Combine(baseDir, "..\\Sounds");
        if (render >= 0)
        {
            LoadClips(dir);
            return Render(args[render + 1], double.Parse(args[render + 2], CultureInfo.InvariantCulture), args[render + 3]);
        }
        logPath = Path.Combine(baseDir, "CarianSound.log");
        bool created;
        using (var mutex = new Mutex(true, "Local\\CarianSound_PBZ", out created))
        {
            if (!created) return 0;                          // already running
            try { File.WriteAllText(logPath, ""); } catch { }
            // A copy started earlier can hang while .NET starts (third-party DLLs injected into
            // the game's child processes: the Steam overlay, Nahimic). It never got this far, so
            // it holds nothing; the mod starts another one, and this one ends the hung copies.
            int ended = 0;
            try
            {
                if (hostScript != null) ended = EndHungHosts(hostScript);
                else
                {
                    var me = Process.GetCurrentProcess();
                    string path = ImagePath(me);
                    foreach (var p in Process.GetProcessesByName("CarianSound"))
                    {
                        try
                        {
                            if (p.Id != me.Id && path != null && string.Equals(ImagePath(p), path, StringComparison.OrdinalIgnoreCase)) { p.Kill(); ended++; }
                        }
                        catch { }
                    }
                }
            }
            catch (Exception e) { Log("hung copies: " + e.Message); }
            LoadClips(dir);
            int resampled = 0;
            foreach (var c in clips.Values) if (c.Rate != Rate) resampled++;
            Log("CarianSound 2.2 (" + (hostScript != null ? "PowerShell host" : "program") + "), " + Rate + " Hz, clips " + clips.Count + (resampled > 0 ? ", not at " + Rate + " Hz: " + resampled : "") + (ended > 0 ? ", ended " + ended + " hung copies" : ""));
            // Real-time playback while the game loads the CPU: the device wakes this
            // thread the moment a buffer is played (CALLBACK_EVENT) instead of it
            // polling, the thread runs in the MMCSS "Pro Audio" class, and the timer
            // runs at 1 ms (Windows keeps timer resolution per process).
            timeBeginPeriod(1);
            int task = 0;
            IntPtr mmcss = AvSetMmThreadCharacteristics("Pro Audio", ref task);
            if (mmcss == IntPtr.Zero) Thread.CurrentThread.Priority = ThreadPriority.Highest;
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }
            var bufferDone = new AutoResetEvent(false);
            var fmt = new WaveFormat { Tag = 1, Channels = 2, SamplesPerSec = Rate, BitsPerSample = 16, BlockAlign = 4, AvgBytesPerSec = Rate * 4 };
            IntPtr wave;
            int err = waveOutOpen(out wave, -1, ref fmt, bufferDone.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CALLBACK_EVENT);
            if (err != 0) { Log("waveOutOpen failed " + err); return 1; }
            Log("real-time: " + (mmcss != IntPtr.Zero ? "MMCSS Pro Audio" : "thread priority Highest") + ", buffer events, 1 ms timer");
            int hsize = Marshal.SizeOf(typeof(WaveHeader));
            int flagsOffset = (int)Marshal.OffsetOf(typeof(WaveHeader), "Flags");   // read in place, no copies
            var headers = new IntPtr[Buffers];
            var data = new IntPtr[Buffers];
            for (int i = 0; i < Buffers; i++)
            {
                data[i] = Marshal.AllocHGlobal(Block * 4);
                headers[i] = Marshal.AllocHGlobal(hsize);
                var h = new WaveHeader { Data = data[i], BufferLength = Block * 4, Flags = WHDR_DONE };
                Marshal.StructureToPtr(h, headers[i], false);
            }
            new Thread(PipeLoop) { IsBackground = true }.Start();
            var output = new short[Block * 2];
            var left = new float[Block]; var right = new float[Block];
            var clock = Stopwatch.StartNew();
            long lastCheck = 0, lastPass = 0, lastReport = 0;
            var game = new List<Process>(Process.GetProcessesByName("PBZ"));
            double longestWait = 0;
            int underruns = 0, reported = 0;
            bool prepared = false;
            Log("playing");
            while (running)
            {
                bool wrote = false;
                // every buffer back from the device means it ran dry: an audible gap
                int done = 0;
                for (int i = 0; i < Buffers; i++)
                    if ((Marshal.ReadInt32(headers[i], flagsOffset) & WHDR_DONE) != 0) done++;
                if (prepared && done == Buffers) underruns++;
                long t = clock.ElapsedTicks;
                longestWait = Math.Max(longestWait, (t - lastPass) * 1000.0 / Stopwatch.Frequency);
                lastPass = t;
                if (clock.ElapsedMilliseconds - lastReport > 10000)
                {
                    if (underruns > reported) Log("underruns +" + (underruns - reported) + " (total " + underruns + "), longest wait " + longestWait.ToString("F1", CultureInfo.InvariantCulture) + " ms");
                    reported = underruns; longestWait = 0; lastReport = clock.ElapsedMilliseconds;
                }
                for (int i = 0; i < Buffers; i++)
                {
                    if ((Marshal.ReadInt32(headers[i], flagsOffset) & WHDR_DONE) == 0) continue;
                    string cmd;
                    while (commands.TryDequeue(out cmd))
                    {
                        try { Apply(cmd); } catch (Exception e) { Log("command '" + cmd + "': " + e.Message); }
                    }
                    Mix(output, left, right);
                    Marshal.Copy(output, 0, data[i], output.Length);
                    if (prepared) waveOutUnprepareHeader(wave, headers[i], hsize);
                    Marshal.WriteInt32(headers[i], flagsOffset, 0);
                    waveOutPrepareHeader(wave, headers[i], hsize);
                    waveOutWrite(wave, headers[i], hsize);
                    wrote = true;
                }
                prepared = true;
                if (clock.ElapsedMilliseconds - lastCheck > 1000)
                {
                    // Listing every process is expensive: find the game's processes
                    // once, then only ask whether they have exited.
                    lastCheck = clock.ElapsedMilliseconds;
                    game.RemoveAll(p => { try { return p.HasExited; } catch { return true; } });
                    if (game.Count == 0) game.AddRange(Process.GetProcessesByName("PBZ"));
                    if (game.Count == 0) { Log("game closed"); running = false; }
                }
                if (!wrote) bufferDone.WaitOne(10);        // woken when the device returns a buffer (every 10 ms)
            }
            waveOutReset(wave);
            for (int i = 0; i < Buffers; i++) waveOutUnprepareHeader(wave, headers[i], hsize);
            waveOutClose(wave);
            if (mmcss != IntPtr.Zero) AvRevertMmThreadCharacteristics(mmcss);
            timeEndPeriod(1);
            Log("exit, underruns " + underruns);
        }
        return 0;
    }
}
