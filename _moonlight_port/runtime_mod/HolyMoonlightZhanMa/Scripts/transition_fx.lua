-- Form-switch effect (1.3.1): the Holy Moonlight Sword's own transformation from Bloodborne, played from
-- transform_fx_data.lua (built by toolchain/build_moonlight_transform_fx.py from f000250030 and f000250035).
-- Both switches play the transformation (f000250030; the user's video shows it lighting up and going dark):
-- two blade-shaped shells of moonlight (scrolling wisps, and a star field that grows in) form around the
-- blade; sparkles, moon smoke and wisps stream off the blade toward its tip and rise; the light rises. The
-- game stops this effect at the end of its animation event, 0.53 s after it starts; so does this: the
-- emitters stop, the shells fade, what was emitted lives out its life.
-- Going dark also stops the transformed blade's resident moonlight: its sparkles drift off the blade and its
-- seven soft halos fade where the blade was.
-- Particles live in world space (unattached meshes at the world origin) and face the camera. The game's
-- additive material ignores vertex colour: each particle's brightness is the atlas cell it samples.
-- Pools have a fixed size, built once; only positions and UVs change, and only while something is alive (1.3.4: and
-- only in the pool's mesh sections that hold it).
local M={}
local D

-- how many of Bloodborne's particles are drawn (the transformation emits about 830 sparkles, the resident
-- moonlight keeps about 225 alive): every sparkle costs four vertices handed to the engine each frame.
-- Going dark draws both: the transformation's sparkles and the resident ones left on the blade.
local BUDGET={sparkles=.16,resident=.65,smoke=1,wisps=1}
M.POOL={sparkles=220,smoke=40,wisps=24}
-- 1.3.4: each pool is drawn as mesh sections of this many particles, and only a section with something to show (or
-- that had in the frame before) is written and handed to the engine (main.lua). The live particles are spread over
-- the pool; these sizes hand over the least in a switch to glowing, to unlit and overlapping ones (offline model of
-- the engine calls: 10 us a call, 0.5 us a vertex, 0.4 us a UV)
M.SECTION={sparkles=20,smoke=8,wisps=6}
local KINDS={"sparkles","smoke","wisps"}
M.HALOS=7
-- the radial blur (107): one camera-facing quad per node (1.3.3)
M.BLURS=2
-- the halos are left where the blade was and fade over this (Bloodborne's stop of the resident moonlight
-- is not in its file; the video shows the haze gone in about a third of a second)
local HALO_FADE=.35
-- particle sizes are the file's: the size in metres times the emitter's particle scale, half the width of a
-- point sprite (the sparkles; half_width) and the whole width of a billboard (smoke, wisps), as matched to
-- the user's video; this multiplies them (development command qa_fxsize)
M.SIZE=1
-- 1.3.5: the moon smoke and the wisps drawn smaller than the file's sizes, times this (the user found the
-- transformation's mist too big and too solid next to Bloodborne's own; main.lua also draws it fainter). Development
-- command qa_mist sets it live.
M.KIND_SIZE={sparkles=1,smoke=.7,wisps=.75}
-- the shells fade out over this once the effect is stopped
local STOP_FADE=.2
-- the resident sparkles are left along the blade's path over this long
local DISPEL_SPREAD=.1
-- the sparkles turn at random "every frame" (105 [5] = 0): every frame of Bloodborne's 30 a second
local TURN_EVERY=1/30

local function curve(keys,t)
    local n=#keys
    if t<=keys[1][1] then return keys[1][2] end
    for i=2,n do
        local k=keys[i]
        if t<=k[1] then
            local p=keys[i-1];local span=k[1]-p[1]
            return span>0 and p[2]+(k[2]-p[2])*(t-p[1])/span or k[2]
        end
    end
    return keys[n][2]
end
-- node types 6, 12 and 20 repeat over their last key's time
local function looped(keys,t)
    local last=keys[#keys][1]
    if last>0 then t=t%last end
    return curve(keys,t)
end
local function peak(keys) local m=0 for _,k in ipairs(keys) do if k[2]>m then m=k[2] end end return m end

-- A particle's brightness before its tint: the colour's alpha times the emitter colour's alpha times the alpha
-- multiplier is an opacity, at most 1; times the colour's luminance (relative to the colour in the atlas) and
-- the brightness multiplier. age: the particle's; T: how long the effect has been active (the emitter colour
-- and the multipliers follow it: the smoke is brightest early on).
local function shade(e,age,T)
    local a=curve(e.alpha,age)*curve(e.emitter_alpha,T)*curve(e.alpha_mult,T)
    if a>1 then a=1 end
    return a*curve(e.lum,age)*curve(e.rgb_mult,T)
end

function M.init(data)
    D=data
    -- each pool's top brightness: the largest shade over the times a particle can be emitted (until the effect
    -- is stopped) and its ages, times the largest tint. The resident moonlight's sparkles share the sparkles'
    -- pool and scale (their atlas cells hold their darker colour).
    for _,k in ipairs(KINDS) do
        local e=D[k];local m=0
        local life=type(e.life)=="table" and e.life[2] or e.life
        for i=0,math.ceil(D.stop*60) do
            for j=0,math.ceil(life*60) do
                local v=shade(e,j/60,(i+j)/60)
                if v>m then m=v end
            end
        end
        e.peak=m*(e.tint and e.tint[2] or 1)
    end
    D.resident.peak=D.sparkles.peak
    D.lightPeak=peak(D.light.alpha)
end
-- a particle pool's emissive gain relative to the others: its top atlas cell is worth peak x norm (norm: the
-- atlas's own scale). One gain times this keeps Bloodborne's balance between sparkles, smoke and wisps.
function M.gain(kind) return D[kind].peak*D[kind].norm end

local function pool(n)
    local p={n=n,list={},next=1}
    for i=1,n do p.list[i]={birth=0,life=0} end
    return p
end
function M.new()
    local s={pools={},verts={},uvs={},alive={},on={},was={},sectionVerts={},sectionUVs={},seed=1708,lit=nil,dark=nil}
    for k,n in pairs(M.POOL) do
        s.pools[k]=pool(n);s.verts[k]={};s.uvs[k]={};s.alive[k]=false
        for i=1,n*4 do s.verts[k][i]={X=0,Y=0,Z=0};s.uvs[k][i]={X=0,Y=0} end
        -- the pool's mesh sections: each one's vertices and UVs (the same tables as the pool's), whether it has a
        -- visible quad (on) and whether it had one in the frame before (was)
        local per=M.SECTION[k]
        assert(n%per==0,"a pool must be a whole number of sections")
        s.on[k],s.was[k],s.sectionVerts[k],s.sectionUVs[k]={},{},{},{}
        for c=1,n/per do
            local v,u={},{}
            for j=1,per*4 do v[j]=s.verts[k][(c-1)*per*4+j];u[j]=s.uvs[k][(c-1)*per*4+j] end
            s.on[k][c],s.was[k][c],s.sectionVerts[k][c],s.sectionUVs[k][c]=false,false,v,u
        end
    end
    s.verts.halos={}
    for i=1,M.HALOS*4 do s.verts.halos[i]={X=0,Y=0,Z=0} end
    s.haloLevel=0
    s.verts.blurs={}
    for i=1,M.BLURS*4 do s.verts.blurs[i]={X=0,Y=0,Z=0} end
    s.blurLevel=0
    return s
end

-- static mesh for a pool of n quads (double-sided, like the other additive meshes of this mod); with
-- corner UVs for the halos
function M.mesh(n,cornerUVs)
    local m={vertices={},indices={},normals={},uv0={},tangents={}}
    local q={{0,0},{1,0},{0,1},{1,1}}
    for k=0,n-1 do
        for c=1,4 do
            m.vertices[#m.vertices+1]={X=0,Y=0,Z=0}
            m.normals[#m.normals+1]={X=0,Y=0,Z=1}
            m.uv0[#m.uv0+1]=cornerUVs and {X=q[c][1],Y=q[c][2]} or {X=0,Y=0}
            m.tangents[#m.tangents+1]={TangentX={X=1,Y=0,Z=0},bFlipTangentY=false}
        end
        local a=k*4;local i=m.indices
        for _,v in ipairs({a,a+1,a+2,a+1,a+3,a+2,a+2,a+1,a,a+2,a+3,a+1}) do i[#i+1]=v end
    end
    return m
end

-- small deterministic generator: the effect looks the same each time
local function rnd(s) s.seed=(s.seed*1103515245+12345)%2147483648;return s.seed/2147483648 end
local function range(s,a,b) return a+(b-a)*rnd(s) end

-- The effect's frame: Bloodborne metres from dummy 120 (the blade base), z along the blade toward the tip,
-- x across it, y off its flat. In the mod's frame (cm, the rig's axes) that is (-S x, -S y, S z + Z0); f holds
-- the rig's world origin o, axes ax/ay/az and world scale sx/sy/sz.
local function point(f,xe,ye,ze)
    local x,y,z=-D.S*xe*f.sx,-D.S*ye*f.sy,(D.S*ze+D.Z0)*f.sz
    return f.o.X+f.ax.X*x+f.ay.X*y+f.az.X*z,f.o.Y+f.ax.Y*x+f.ay.Y*y+f.az.Y*z,f.o.Z+f.ax.Z*x+f.ay.Z*y+f.az.Z*z
end
local function direction(f,xe,ye,ze)
    local x,y,z=-D.S*xe*f.sx,-D.S*ye*f.sy,D.S*ze*f.sz
    return f.ax.X*x+f.ay.X*y+f.az.X*z,f.ax.Y*x+f.ay.Y*y+f.az.Y*z,f.ax.Z*x+f.ay.Z*y+f.az.Z*z
end

-- One particle from a box emitter (32): a point in the box; a direction in the cone around the effect's +Z
-- (initial direction 6: along the blade, toward the tip), even over the cone's solid angle; the speed and the
-- particle scale, each with its relative spread. t0: when the effect started (its active time drives the
-- emitter colour and the multipliers). row: the atlas variant (random when nil).
local function emit(s,kind,e,birth,f,t0,row)
    -- the next free slot of the pool from where the last one was taken (a full pool reuses the next slot)
    local p=s.pools[kind];local i=p.next
    for _=1,p.n do
        local o=p.list[i]
        if o.life<=0 or birth-o.birth>=o.life then break end
        i=i%p.n+1
    end
    local q=p.list[i];p.next=i%p.n+1
    local b,c=e.box,e.center
    q.x,q.y,q.z=point(f,c[1]+range(s,-.5,.5)*b[1],c[2]+range(s,-.5,.5)*b[2],c[3]+range(s,-.5,.5)*b[3])
    local ct=1-rnd(s)*(1-math.cos(math.rad(e.cone_deg)));local st=math.sqrt(math.max(0,1-ct*ct))
    local ph=range(s,0,6.2832)
    local speed=e.speed[1]*(1+range(s,-e.speed[2],e.speed[2]))
    q.vx,q.vy,q.vz=direction(f,st*math.cos(ph)*speed,st*math.sin(ph)*speed,ct*speed)
    q.scale=e.scale[1]*(1+range(s,-e.scale[2],e.scale[2]))
    q.birth=birth;q.t=birth;q.t0=t0
    q.nextTurn=e.turn_deg>0 and birth+TURN_EVERY or math.huge
    q.life=type(e.life)=="table" and range(s,e.life[1],e.life[2]) or e.life
    q.e=e
    q.tint=e.tint and range(s,e.tint[1],e.tint[2]) or 1
    q.rot=e.rotation_deg and math.rad(range(s,e.rotation_deg[1],e.rotation_deg[2])) or 0
    q.spin=e.spin_deg and math.rad(e.spin_deg*range(s,e.spin_random[1],e.spin_random[2])) or 0
    q.frame=e.start_frame and range(s,e.start_frame[1],e.start_frame[2]) or 0
    q.row=row or math.floor(rnd(s)*D.atlas[kind].variants)
    return q
end

-- turn a particle's velocity by a random angle of up to maxDeg about a random axis across it (same speed)
local function turn(s,q,maxDeg)
    local vx,vy,vz=q.vx,q.vy,q.vz
    local sp=math.sqrt(vx*vx+vy*vy+vz*vz)
    if sp<1e-6 then return end
    vx,vy,vz=vx/sp,vy/sp,vz/sp
    local ux,uy,uz
    if math.abs(vz)<.9 then ux,uy,uz=-vy,vx,0 else ux,uy,uz=0,-vz,vy end
    local ul=math.sqrt(ux*ux+uy*uy+uz*uz);ux,uy,uz=ux/ul,uy/ul,uz/ul
    local wx,wy,wz=vy*uz-vz*uy,vz*ux-vx*uz,vx*uy-vy*ux
    local ph=range(s,0,6.2832);local cp,sp2=math.cos(ph),math.sin(ph)
    local rx,ry,rz=cp*ux+sp2*wx,cp*uy+sp2*wy,cp*uz+sp2*wz
    local a=math.rad(maxDeg)*rnd(s);local ca,sa=math.cos(a)*sp,math.sin(a)*sp
    q.vx,q.vy,q.vz=vx*ca+rx*sa,vy*ca+ry*sa,vz*ca+rz*sa
end
-- move a particle from its last time to now: its velocity; the world's gravity (105 [0], Bloodborne m/s^2 along
-- the world's down axis, negative rises; it bends the velocity); the random turns (the sparkles')
local function advance(s,q,now)
    local e=q.e
    while q.t<now do
        local t1=now<q.nextTurn and now or q.nextTurn
        local dt=t1-q.t
        local g=curve(e.lift,q.t+dt*.5-q.birth)*D.S
        local vz=q.vz;q.vz=vz-g*dt
        q.x,q.y,q.z=q.x+q.vx*dt,q.y+q.vy*dt,q.z+(vz+q.vz)*.5*dt
        q.t=t1
        if t1>=q.nextTurn then turn(s,q,e.turn_deg);q.nextTurn=q.nextTurn+TURN_EVERY end
    end
end

-- start the effect for the form being switched to ("glowing" or "unlit"): the transformation either way
-- (s.lit: one run of it; a new switch starts a new run, what the last one emitted lives on), and going dark
-- also leaves the resident moonlight's sparkles and halos
function M.start(s,mode,now)
    local lit={t0=now,stopAt=now+D.stop,ticks={},acc={},uv={}}
    for _,k in ipairs(KINDS) do lit.ticks[k]=0;lit.acc[k]=0 end
    -- the wisp shells' random UV offsets (Bloodborne picks them per particle)
    for i,sh in ipairs(D.shells) do lit.uv[i]={range(s,0,sh.uv_random[1]),range(s,0,sh.uv_random[2])} end
    s.lit=lit
    if mode=="glowing" then
        s.dark=nil
    else
        s.dark={t0=now,n=0}
        s.halo={t0=now}   -- placed at the blade on the next step
    end
end

-- how many of emitter e's particles are alive in pool p (an emitter's cap counts only its own: going dark, the
-- resident moonlight's sparkles share the pool)
local function aliveIn(p,now,e)
    local n=0
    for i=1,p.n do local q=p.list[i] if q.e==e and q.life>0 and now-q.birth<q.life then n=n+1 end end
    return n
end

-- the emission ticks of one emitter up to now: Bloodborne emits every interval while the emitter runs (until
-- its duration or the stop), count(t) particles each time; this draws budget of them
local function emitter(s,kind,f,now)
    local lit,e,budget=s.lit,D[kind],BUDGET[kind]
    local window=math.min(lit.stopAt-lit.t0,e.duration>0 and e.duration or math.huge)
    local t=now-lit.t0
    local alive,cap=aliveIn(s.pools[kind],now,e),e.max*budget
    while true do
        local tick=lit.ticks[kind]*e.interval
        if tick>t or tick>=window then break end
        lit.ticks[kind]=lit.ticks[kind]+1
        lit.acc[kind]=lit.acc[kind]+curve(e.count,tick)*budget
        while lit.acc[kind]>=1 do
            lit.acc[kind]=lit.acc[kind]-1
            if alive<cap then emit(s,kind,e,lit.t0+tick,f,lit.t0,kind=="sparkles" and 0 or nil);alive=alive+1 end
        end
    end
    return t<window
end

-- going dark: the resident moonlight is stopped. It emits 5 sparkles a frame that live 0.53 to 0.97 s, so the
-- ones it leaves are at every age; they are put along the blade over the first DISPEL_SPREAD seconds (a moving
-- blade leaves them along its path), each as old as its age and rising as fast as that age gives.
local function dispel(s,f,now)
    local e,dark=D.resident,s.dark
    local total=e.count[1][2]/e.interval*(e.life[1]+e.life[2])/2*BUDGET.resident
    local t=now-dark.t0
    local want=math.floor(total*math.min(1,t/DISPEL_SPREAD)+.5)
    while dark.n<want do
        dark.n=dark.n+1
        local q=emit(s,"sparkles",e,now,f,-math.huge,1)
        local age=range(s,0,q.life*.9)
        q.birth=now-age
        q.vz=q.vz-curve(e.lift,age*.5)*D.S*age
        q.nextTurn=now+TURN_EVERY*rnd(s)
    end
    return t<DISPEL_SPREAD
end

local function cell(a,index)
    local col,row=index%a.cols,math.floor(index/a.cols)
    return col/a.cols,row/a.rows,(col+1)/a.cols,(row+1)/a.rows
end

-- move and write one pool's quads, a mesh section at a time: a section is written while it holds a live particle or
-- had a visible quad in the frame before (its quads then collapse onto park); a section with neither is left as it
-- is, collapsed. Sets s.on and s.was (see M.new); returns whether any particle is visible. The particles are visited
-- in the same order as before 1.3.4, so their random turns are the same.
local function write(s,kind,now,cam,park)
    local p=s.pools[kind];local verts,uvs=s.verts[kind],s.uvs[kind]
    local on,was,per=s.on[kind],s.was[kind],M.SECTION[kind]
    local camR,camU=cam.R,cam.U
    local a=D.atlas[kind];local top=D[kind].peak;local any=false
    for sc=1,#on do
        local first=(sc-1)*per
        local active=on[sc]
        if not active then
            for i=first+1,first+per do
                local q=p.list[i]
                if q.life>0 and now-q.birth<q.life then active=true break end
            end
        end
        was[sc]=on[sc];on[sc]=false
        if active then
            for i=first+1,first+per do
                local q=p.list[i];local base=(i-1)*4
                local age=now-q.birth
                local cx,cy,cz,size,rot,u0,v0,u1,v1=park.X,park.Y,park.Z,0,0,0,0,0,0
                if q.life>0 and age>=0 and age<q.life then
                    local e=q.e
                    advance(s,q,now)
                    local b=shade(e,age,now-q.t0)*q.tint/top
                    local level=math.floor(math.min(1,b)*(a.levels-1)+.5)
                    if level>0 then
                        on[sc]=true
                        cx,cy,cz=q.x,q.y,q.z
                        -- half the quad's width (cm): the file's size (m) times the particle scale
                        size=(e.size_loops and looped(e.size,age) or curve(e.size,age))*q.scale*D.S*(e.half_width and 1 or .5)*M.SIZE*M.KIND_SIZE[kind]
                        rot=q.rot+q.spin*age
                        local row=q.row
                        if kind=="wisps" then row=math.floor((q.frame+curve(e.timeline,age))/4)%16 end
                        u0,v0,u1,v1=cell(a,row*a.levels+level)
                    end
                elseif q.life>0 and age>=q.life then q.life=0 end
                local c,sn=math.cos(rot)*size,math.sin(rot)*size
                local ax,ay,az=c*camR.X+sn*camU.X,c*camR.Y+sn*camU.Y,c*camR.Z+sn*camU.Z
                local bx,by,bz=-sn*camR.X+c*camU.X,-sn*camR.Y+c*camU.Y,-sn*camR.Z+c*camU.Z
                local v=verts[base+1];v.X,v.Y,v.Z=cx-ax-bx,cy-ay-by,cz-az-bz
                v=verts[base+2];v.X,v.Y,v.Z=cx+ax-bx,cy+ay-by,cz+az-bz
                v=verts[base+3];v.X,v.Y,v.Z=cx-ax+bx,cy-ay+by,cz-az+bz
                v=verts[base+4];v.X,v.Y,v.Z=cx+ax+bx,cy+ay+by,cz+az+bz
                local t=uvs[base+1];t.X,t.Y=u0,v0
                t=uvs[base+2];t.X,t.Y=u1,v0
                t=uvs[base+3];t.X,t.Y=u0,v1
                t=uvs[base+4];t.X,t.Y=u1,v1
            end
            if on[sc] then any=true end
        end
    end
    return any
end

-- 1 until the stop, then down to 0 over STOP_FADE
local function stopFade(lit,now) return math.max(0,math.min(1,1-(now-lit.stopAt)/STOP_FADE)) end

-- the shells: for each of D.shells, brightness (alpha x intensity curves) and size (the grow curve)
function M.shells(s,now,out)
    out=out or {}
    local lit=s.lit
    for i,sh in ipairs(D.shells) do
        local o=out[i] or {};out[i]=o
        local age=lit and now-lit.t0 or -1
        if age>=0 and age<sh.life then
            o.level=curve(sh.alpha,age)*curve(sh.intensity,age)*stopFade(lit,now);o.scale=curve(sh.grow,age)
        else o.level=0;o.scale=1 end
    end
    return out
end
function M.uvOffset(s,i) return s.lit and s.lit.uv[i] or {0,0} end

-- the light: 0..1 of its peak
function M.light(s,now)
    local l,lit=D.light,s.lit
    local age=lit and now-lit.t0 or -1
    if age<0 or age>=l.life then return 0 end
    return curve(l.alpha,age)/D.lightPeak*stopFade(lit,now)
end

-- going dark: the resident moonlight's halos (59: s01000 billboards on the blade), left where the blade was
-- and fading out; returns their brightness 0..1
local function halos(s,now,f,cam)
    local h=s.halo
    if not h then return 0 end
    if not h.pts then
        h.pts={}
        for i,d in ipairs(D.halos) do local x,y,z=point(f,0,0,d.z);h.pts[i]={x,y,z,d.size*D.S*.5} end
    end
    local level=math.max(0,1-(now-h.t0)/HALO_FADE)
    if level<=0 then s.halo=nil end
    local verts=s.verts.halos
    for i,p in ipairs(h.pts) do
        local base=(i-1)*4;local size=level>0 and p[4] or 0
        local ax,ay,az=cam.R.X*size,cam.R.Y*size,cam.R.Z*size
        local bx,by,bz=cam.U.X*size,cam.U.Y*size,cam.U.Z*size
        local v=verts[base+1];v.X,v.Y,v.Z=p[1]-ax-bx,p[2]-ay-by,p[3]-az-bz
        v=verts[base+2];v.X,v.Y,v.Z=p[1]+ax-bx,p[2]+ay-by,p[3]+az-bz
        v=verts[base+3];v.X,v.Y,v.Z=p[1]-ax+bx,p[2]-ay+by,p[3]-az+bz
        v=verts[base+4];v.X,v.Y,v.Z=p[1]+ax+bx,p[2]+ay+by,p[3]+az+bz
    end
    return level
end

-- the radial blur (107, both switches): a camera-facing quad of the node's size at each node's place off the
-- blade's flats, following the blade; its strength is the colour's alpha over the effect's age (in over
-- 0.25 s), faded out with the stop like the shells. Returns the strength 0..1.
local function blurs(s,now,f,cam)
    local lit=s.lit
    local age=lit and now-lit.t0 or -1
    local level=0
    local verts=s.verts.blurs
    for i,b in ipairs(D.blurs) do
        local l=(age>=0 and age<b.life) and curve(b.alpha,age)*stopFade(lit,now) or 0
        if l>level then level=l end
        local base=(i-1)*4
        local cx,cy,cz=point(f,b.place[1],b.place[2],b.place[3])
        local size=l>0 and b.size*D.S*.5 or 0
        local ax,ay,az=cam.R.X*size,cam.R.Y*size,cam.R.Z*size
        local bx,by,bz=cam.U.X*size,cam.U.Y*size,cam.U.Z*size
        local v=verts[base+1];v.X,v.Y,v.Z=cx-ax-bx,cy-ay-by,cz-az-bz
        v=verts[base+2];v.X,v.Y,v.Z=cx+ax-bx,cy+ay-by,cz+az-bz
        v=verts[base+3];v.X,v.Y,v.Z=cx-ax+bx,cy-ay+by,cz-az+bz
        v=verts[base+4];v.X,v.Y,v.Z=cx+ax+bx,cy+ay+by,cz+az+bz
    end
    return level
end

-- advance to time now. f: the blade frame (see point); cam: {R=,U=} camera right and up.
-- s.alive[kind] tells which pools have something to draw; s.haloLevel the halos' brightness, s.blurLevel the
-- radial blur's strength.
function M.step(s,now,f,cam)
    local lit=s.lit
    if lit and not lit.done then
        local more=false
        for _,k in ipairs(KINDS) do more=emitter(s,k,f,now) or more end
        if not more and now>=lit.stopAt then lit.done=true end
    end
    if s.dark and not dispel(s,f,now) then s.dark=nil end
    for _,k in ipairs(KINDS) do s.alive[k]=write(s,k,now,cam,f.o) end
    s.haloLevel=halos(s,now,f,cam)
    s.blurLevel=blurs(s,now,f,cam)
end
-- anything still to come or to draw
function M.busy(s,now)
    if s.dark or s.halo or (s.lit and not s.lit.done) then return true end
    for _,k in ipairs(KINDS) do if s.alive[k] then return true end end
    if s.lit and now<s.lit.stopAt+STOP_FADE then return true end
    return false
end
return M
