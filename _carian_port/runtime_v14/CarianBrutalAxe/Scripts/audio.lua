-- Elden Ring "Carian Grandeur" sounds (v1.7).
-- Phantom Blade Zero plays everything through Wwise and keeps Unreal's own
-- audio device off (GetMaxAudioChannelCount = 0), so the clips (decoded from
-- the local Elden Ring cs_main.bnk into Sounds\*.wav) are played by the small
-- helper SoundHelper\CarianSound.exe. The mod starts it when needed and sends
-- it one text line per command over \\.\pipe\CarianSound_PBZ; the helper quits
-- with the game. sound_bank.lua lists each Elden Ring event as layers played
-- together, each layer picking one clip at random, as in the source Wwise
-- containers. Position is approximated: distance volume and left/right pan from
-- the camera, refreshed while a sound follows the sword.
--
-- Every event sounds as it does in Elden Ring: the clips are pre-rendered at
-- their Wwise pitch (toolchain\extract_grandeur_sounds.py) and played sample
-- for sample, never stretched; sounds with the Wwise Loop property repeat their
-- own loop segment until stopped; events Elden Ring cuts at the end of their
-- TAE event (bank.cuts) are cut after the same time. Only the moments come
-- from PBZ (main.lua).
--
-- 2.2: a package may leave CarianSound.exe out. The same player then runs in
-- Windows' own PowerShell: SoundHelper\CarianSound.ps1 compiles CarianSound.cs
-- when it starts (same mixer, same pipe). The shell cannot pass arguments to a
-- program, so the script is started by CarianSound.vbs (Windows Script Host: no
-- window, the game keeps the focus) or, where VBScript is not installed, by
-- CarianSound.cmd (a console window shows for a moment and takes the focus).
-- Optional config keys: sfxHost = 'exe' | 'powershell', sfxLauncher = 'vbs' | 'cmd'.
local M = {}
local PIPE = '\\\\.\\pipe\\CarianSound_PBZ'
-- Master level at sfxVolume = 1 and in-game volume 100. Measured with
-- toolchain\audio_sessions.ps1: the Elden Ring mix peaks about where the
-- game's own axe skill sounds peak (~0.6-0.75).
local LEVEL = .15
-- fade applied when a sound is cut (Elden Ring's event end, PBZ's release or
-- the sword vanishing): short enough to keep the cut, long enough not to click
local CUT_FADE = .15

-- env: valid, log, cfg, bank, dir (mod folder)
function M.new(env)
 local A = {handles = {}, queue = {}, ok = false, voice = 0, muted = {}, played = 0, gameVolume = 1}
 local valid, log, cfg, bank = env.valid, env.log, env.cfg, env.bank

 function A:masterLine()
  return string.format('M %.4f', (cfg.sfxVolume or 1) * LEVEL * self.gameVolume)
 end
 -- g: the game's own volume for sound effects, 0..1 (master x SFX slider)
 function A:setGameVolume(g)
  if math.abs(g - self.gameVolume) < .002 then return end
  self.gameVolume = g
  log('SOUND_GAME_VOLUME', string.format('%.3f', g))
  if self.pipe then self:send(self:masterLine()) end
 end

 function A:send(line)
  if not self.pipe then return false end
  local ok, r = pcall(function() return self.pipe:write(line, '\n') end)
  if ok and r then return true end
  log('SOUND_HELPER', 'connection lost', tostring(r))
  pcall(function() self.pipe:close() end)
  self.pipe, self.ok = nil, false
  self:restoreNative()
  return false
 end

 -- What the shell is asked to open to start the player (decided once):
 -- host 'exe' (the bundled program) or 'powershell' (CarianSound.ps1 through
 -- its .vbs / .cmd launcher, used when the package has no program); retry: how
 -- long to wait for a connection before starting it again (PowerShell compiles
 -- the player first: about 3 s on an idle PC, more while the game loads).
 local function exists(p) local f = io.open(p, 'rb') if f then f:close() return true end return false end
 function A:target()
  if self.start then return self.start end
  local helper = env.dir .. '/SoundHelper/'
  local host = cfg.sfxHost
  if host ~= 'exe' and host ~= 'powershell' then
   host = (exists(helper .. 'CarianSound.exe') or not exists(helper .. 'CarianSound.ps1')) and 'exe' or 'powershell'
  end
  local file, marked = 'CarianSound.exe', {'CarianSound.exe'}
  if host == 'powershell' then
   local launcher = cfg.sfxLauncher
   if launcher ~= 'vbs' and launcher ~= 'cmd' then
    local root = os.getenv('SystemRoot') or 'C:\\Windows'
    launcher = exists(root .. '\\System32\\vbscript.dll') and 'vbs' or 'cmd'
   end
   file = 'CarianSound.' .. launcher
   marked = {'CarianSound.vbs', 'CarianSound.cmd', 'CarianSound.ps1', 'CarianSound.cs'}
  end
  self.start = {host = host, file = helper .. file, marked = marked, retry = host == 'powershell' and 20 or 6}
  return self.start
 end

 -- Connect to the helper, starting it once if it is not running. Uses real
 -- time (os.clock): it is called before any world exists.
 function A:connect()
  local now = os.clock()
  if self.pipe or cfg.sfxEnabled == false then return self.pipe ~= nil end
  if self.lastTry and now - self.lastTry < .25 then return false end
  self.lastTry = now
  local f = io.open(PIPE, 'w')
  if f then
   pcall(function() f:setvbuf('no') end)
   self.pipe, self.ok = f, true
   self.muteDirty = true
   self:send(self:masterLine())
   log('SOUND_HELPER', 'connected')
   return true
  end
  -- Started by the game, the helper inherits DLLs injected into its child
  -- processes (seen: the Steam overlay, Nahimic's AudioDevProps2) and can hang
  -- while .NET starts, before any of its own code runs (2.0.1, user's PC). So it
  -- is started again when no connection came within 6 s (PowerShell: 20 s), up
  -- to three times; a copy that does start ends the hung ones.
  local start = self:target()
  local wait = self.launched and now - self.launched
  if not self.launched or (wait > start.retry and (self.attempts or 1) < 3) then
   self.attempts = (self.attempts or 0) + 1
   if self.launched then log('SOUND_HELPER', 'no connection after ' .. start.retry .. ' s, starting it again', self.attempts) end
   self.launched = now
   -- Unpacked from a zip that was downloaded with a browser, the files carry
   -- the download mark (the NTFS stream Zone.Identifier), and the shell would
   -- stop the launch for a security prompt. Clear the mark of the files that
   -- are started first, as the "Unblock" box in their file properties does.
   local cleared = 0
   for _, n in ipairs(start.marked) do
    if os.remove((env.dir .. '/SoundHelper/' .. n):gsub('/', '\\') .. ':Zone.Identifier') then cleared = cleared + 1 end
   end
   if cleared > 0 then log('SOUND_HELPER', 'download mark removed', cleared) end
   -- Start through the shell (UE's LaunchURL -> ShellExecute): no cmd.exe, so
   -- no console / Windows Terminal window and no wait on the game thread
   -- (except the .cmd launcher, used only where VBScript is missing).
   local path = start.file:gsub('\\', '/'):gsub(' ', '%%20')
   local url = 'file:///' .. path
   local ksl = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
   local ok, r = pcall(function() ksl:LaunchURL(url) end)
   log('SOUND_HELPER', 'start', start.host, url, tostring(ok), tostring(r))
  elseif wait > start.retry and not self.gaveUp then
   self.gaveUp = true
   log('SOUND_HELPER', 'no connection after 3 starts: Elden Ring sounds off, native sounds kept')
  end
  return false
 end

 function A:spatial(h)
  local cam = self.cam
  local p = h.at or (h.follow and h.follow())
  if not cam or not p then return h.volume, 0 end
  local dx, dy, dz = p[1] - cam.p[1], p[2] - cam.p[2], p[3] - cam.p[3]
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  local att = 1
  if d > 1000 then att = math.max(0, 1 - (d - 1000) / 5000) end   -- full within 10 m, silent at 60 m
  local pan = 0
  if d > 1 then pan = (dx * cam.r[1] + dy * cam.r[2] + dz * cam.r[3]) / d * .7 end
  return h.volume * att, pan
 end

 -- opts: follow() -> {x,y,z} | at {x,y,z}; volume. Events Elden Ring cuts
 -- (bank.cuts) stop after that time.
 function A:play(name, now, opts)
  if not self.ok or cfg.sfxEnabled == false then return nil end
  local layers = bank.events[name]
  if not layers then return nil end
  opts = opts or {}
  local cut = bank.cuts[name]
  local h = {name = name, voices = {}, fade = CUT_FADE, stopAt = cut and now + cut or nil,
   born = now, follow = opts.follow, at = opts.at, volume = opts.volume or 1}
  local vol, pan = self:spatial(h)
  for _, layer in ipairs(layers) do
   -- alternative = {clip, gain, loops} (clip rendered at its Wwise pitch; Wwise volume; Loop)
   local alt = layer[math.random(#layer)]
   self.voice = self.voice + 1
   if alt[3] then h.loops = true end
   if self:send(string.format('P %d %s %.4f %.3f 1 0 %d', self.voice, alt[1], vol * alt[2], pan, alt[3] and 1 or 0)) then
    h.voices[#h.voices + 1] = self.voice; h.gains = h.gains or {}; h.gains[#h.voices] = alt[2]
   end
  end
  self.played = self.played + 1
  if env.verbose then log('SOUND_PLAY', name, 'voices', #h.voices, string.format('vol %.2f pan %.2f', vol, pan)) end
  if #h.voices == 0 then return nil end
  self.handles[#self.handles + 1] = h
  return h
 end
 function A:schedule(at, name, opts) self.queue[#self.queue + 1] = {at = at, name = name, opts = opts} end
 function A:stop(h, fade, now)
  if not h or h.stopped then return end
  h.stopped, h.stoppedAt = true, now or self.now or 0
  h.fade = fade or h.fade
  for _, v in ipairs(h.voices) do self:send(string.format('F %d %.3f', v, h.fade)) end
 end
 function A:stopAll(fade)
  self.queue = {}
  for _, h in ipairs(self.handles) do h.stopped = true end
  self.handles = {}
  if self.pipe then self:send(string.format('X %.3f', fade or .2)) end
 end
 -- cam: {p = {x,y,z}, r = {x,y,z}} (camera position and right vector)
 function A:update(now, cam)
  self.cam, self.now = cam or self.cam, now
  if #self.queue > 0 then
   local later = {}
   for _, q in ipairs(self.queue) do
    if now >= q.at then self:play(q.name, now, q.opts) else later[#later + 1] = q end
   end
   self.queue = later
  end
  local refresh = not self.lastRefresh or now - self.lastRefresh >= .1
  if refresh then self.lastRefresh = now end
  local keep = {}
  for _, h in ipairs(self.handles) do
   if h.stopAt and not h.stopped and now >= h.stopAt then self:stop(h, nil, now) end
   -- a looping sound must be stopped by its owner; this only guards against a lost handle
   if h.loops and not h.stopped and now - h.born > 120 then self:stop(h, .5, now); log('SOUND_LOOP_TIMEOUT', h.name) end
   if refresh and h.follow and not h.stopped then
    local vol, pan = self:spatial(h)
    for i, v in ipairs(h.voices) do self:send(string.format('V %d %.4f %.3f', v, vol * (h.gains and h.gains[i] or 1), pan)) end
   end
   -- keep a handle while it can still be heard: one-shots last at most 4.5 s
   -- (3 s clip at the slowest Wwise pitch), loops until stopped, then their fade
   local alive
   if h.stopped then alive = now - h.stoppedAt < h.fade + .1
   elseif h.loops then alive = true
   else alive = now - h.born < 6 end
   if alive then keep[#keep + 1] = h end
  end
  self.handles = keep
 end

 -- The axe skill's own weapon sounds are Wwise events posted by
 -- GAA_PlaySound_Opt actions in its ability timelines. Clear those (only the
 -- Brutal Axe abilities and only the weapon's magic/impact family) while the
 -- helper is connected; voice, footsteps and cloth stay. Restored when the
 -- helper goes away.
 -- The actions are created with their ability objects, so this runs only when
 -- muteDirty is set: on connecting, and by main.lua when the Brutal Axe
 -- abilities change (a level load). One pass over every GAA_PlaySound object
 -- in the game costs ~40 ms, too much to repeat while playing.
 local families = {'AxeGiant', 'MoJi_Disappear'}
 A.muteDirty = true
 function A:muteNative()
  if not self.ok or cfg.muteNativeAxeSounds == false or cfg.sfxEnabled == false then return 0 end
  self.muteDirty = false
  local kept = {}
  for _, m in ipairs(self.muted) do if valid(m.o) then kept[#kept + 1] = m end end   -- objects of an unloaded level
  self.muted = kept
  local n = 0
  for _, o in ipairs(FindAllOf('GAA_PlaySound_Opt_C') or {}) do
   if valid(o) then
    local full = o:GetFullName()
    if full:find('GA_BrutalAxe_Normal', 1, true) or full:find('GA_BrutalAxe_Sprint', 1, true) then
     local ev = o.AkEvent
     if valid(ev) then
      local en = ev:GetFName():ToString()
      for _, f in ipairs(families) do
       if en:find(f, 1, true) then
        local ok, e = pcall(function() o.AkEvent = nil end)
        if ok and not valid(o.AkEvent) then n = n + 1; self.muted[#self.muted + 1] = {o = o, ev = ev}
        else log('NATIVE_SOUND_KEEP', en, tostring(e)) end
        break
       end
      end
     end
    end
   end
  end
  if n > 0 then log('NATIVE_SOUNDS_MUTED', n, 'total', #self.muted) end
  return n
 end
 function A:restoreNative()
  local n = 0
  for _, m in ipairs(self.muted) do
   if valid(m.o) and valid(m.ev) then if pcall(function() m.o.AkEvent = m.ev end) then n = n + 1 end end
  end
  if #self.muted > 0 then log('NATIVE_SOUNDS_RESTORED', n) end
  self.muted = {}
  self.muteDirty = true                    -- mute again once the helper is back
 end
 return A
end
return M
