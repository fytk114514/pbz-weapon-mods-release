-- Flowing-light geometry built for this mod, in a cyan/green palette.
-- Everything is drawn with the mod's own meshes: the looping glow, the
-- startup flourish and the sustained blade mist follow PBZ's heavy window.
local M={}
local function empty() return {vertices={},indices={},normals={},uv0={},tangents={}} end
local function vertex(m,x,y,z,u,v,nx,ny,nz)
    m.vertices[#m.vertices+1]={X=x,Y=y,Z=z}
    m.normals[#m.normals+1]={X=nx,Y=ny,Z=nz}
    m.uv0[#m.uv0+1]={X=u,Y=v}
    m.tangents[#m.tangents+1]={TangentX={X=1,Y=0,Z=0},bFlipTangentY=false}
end
local function tri(m,a,b,c)
    local i=m.indices; i[#i+1]=a; i[#i+1]=b; i[#i+1]=c
    i[#i+1]=c; i[#i+1]=b; i[#i+1]=a -- double-sided translucent ribbon
end
local ribbon=empty()
for strand=0,1 do
    local start=#ribbon.vertices
    for step=0,48 do
        local t=step/48
        local angle=t*math.pi*2.2+strand*math.pi
        local radius=4+14*(1-t)^0.6
        local z=10+175*t
        local width=0.25+0.7*math.sin(math.pi*t)
        local x,y=radius*math.cos(angle),radius*0.5*math.sin(angle)
        local nx,ny=math.cos(angle),math.sin(angle)
        vertex(ribbon,x,y,z-width,0,t,nx,ny,0)
        vertex(ribbon,x,y,z+width,1,t,nx,ny,0)
        if step>0 then
            local a=start+(step-1)*2
            tri(ribbon,a,a+1,a+2); tri(ribbon,a+1,a+3,a+2)
        end
    end
end
M.ribbon=ribbon
local spark=empty()
local s,z=7,190.5
for plane=1,2 do
    local first=#spark.vertices
    if plane==1 then
        vertex(spark,-s,0,z-s,0,0,0,1,0); vertex(spark,s,0,z-s,1,0,0,1,0)
        vertex(spark,-s,0,z+s,0,1,0,1,0); vertex(spark,s,0,z+s,1,1,0,1,0)
    else
        vertex(spark,0,-s,z-s,0,0,1,0,0); vertex(spark,0,s,z-s,1,0,1,0,0)
        vertex(spark,0,-s,z+s,0,1,1,0,0); vertex(spark,0,s,z+s,1,1,1,0,0)
    end
    tri(spark,first,first+1,first+2); tri(spark,first+1,first+3,first+2)
end
M.spark=spark

-- Three intersecting, tapered veils keep the mist visible as the sword turns.
-- A tileable noise texture supplies wisps; no opaque tube surrounds the blade.
local mist=empty()
for plane=0,2 do
    local angle=plane*math.pi/3
    local ax,ay=math.cos(angle),math.sin(angle)
    local first=#mist.vertices
    for step=0,24 do
        local t=step/24
        local width=(13+5*math.sin(math.pi*t))*(1-t)^0.35+1
        local z=12+184*t
        vertex(mist,-width*ax,-width*ay,z,0,t,-ay,ax,0)
        vertex(mist,width*ax,width*ay,z,1,t,-ay,ax,0)
        if step>0 then
            local a=first+(step-1)*2
            tri(mist,a,a+1,a+2);tri(mist,a+1,a+3,a+2)
        end
    end
end
M.mist=mist

local function crossCard(m,x,y,z,w,h,angle)
    local a=#m.vertices;local ax,ay=math.cos(angle)*w,math.sin(angle)*w
    vertex(m,x-ax,y-ay,z-h,0,0,0,1,0);vertex(m,x+ax,y+ay,z-h,1,0,0,1,0)
    vertex(m,x-ax,y-ay,z+h,0,1,0,1,0);vertex(m,x+ax,y+ay,z+h,1,1,0,1,0)
    tri(m,a,a+1,a+2);tri(m,a+1,a+3,a+2)
end
-- the motes: 28 pairs of crossed cards circling and rising along the blade; place(j,x,y,z,size) gets each pair's
-- centre and size at time t (q: the charge, 0..1)
local function motes(t,q,place)
    for j=0,27 do
        local life=1.8+(j%7)*.19
        local age=(t/life+j*.61803398875)%1
        local angle=j*2.399963229728653+.15*t
        local radius=2+(j%4)*1.5+age*(12+10*q)
        local x=(8+radius)*math.cos(angle)
        local y=(3+radius*.5)*math.sin(angle)
        local z=18+(j*53%160)+age*(8+10*q)
        local size=(.6+(j%5)*.22)*math.sin(math.pi*age)^.7
        place(j,x,y,z,size)
    end
end
M.motes=empty()
motes(0,0,function(_,x,y,z,size) crossCard(M.motes,x,y,z,size,size,0);crossCard(M.motes,x,y,z,size,size,math.pi/2) end)
-- 1.3.4: a frame of the motes (30 a second while the sword glows) rewrites the positions in one array, as crossCard
-- places them; the section keeps its UVs, normals and indices. Rebuilding the whole mesh for its positions took
-- about 15 times as long and left about 180 KB of garbage each time.
local frame={}
for i=1,#M.motes.vertices do frame[i]={X=0,Y=0,Z=0} end
local C0,S0,C90,S90=math.cos(0),math.sin(0),math.cos(math.pi/2),math.sin(math.pi/2)
local function card(k,x,y,z,w,h,cs,sn)
    local ax,ay=cs*w,sn*w
    local v=frame[k+1];v.X,v.Y,v.Z=x-ax,y-ay,z-h
    v=frame[k+2];v.X,v.Y,v.Z=x+ax,y+ay,z-h
    v=frame[k+3];v.X,v.Y,v.Z=x-ax,y-ay,z+h
    v=frame[k+4];v.X,v.Y,v.Z=x+ax,y+ay,z+h
end
local function place(j,x,y,z,size) card(j*8,x,y,z,size,size,C0,S0);card(j*8+4,x,y,z,size,size,C90,S90) end
function M.particleFrame(t,q) motes(t,q or 0,place);return frame end
-- Cyan vapor gathers along the entire blade and expands briefly on release.
local charge=empty()
for plane=0,3 do
    local angle=plane*math.pi/4;local ax,ay=math.cos(angle),math.sin(angle)
    local first=#charge.vertices
    for step=0,24 do
        local t=step/24;local width=3+30*math.sin(math.pi*t)^.7;local z=(t-.5)*180
        vertex(charge,-width*ax,-width*ay,z,0,t,-ay,ax,0)
        vertex(charge,width*ax,width*ay,z,1,t,-ay,ax,0)
        if step>0 then
            local a=first+(step-1)*2
            tri(charge,a,a+1,a+2);tri(charge,a+1,a+3,a+2)
        end
    end
end
M.charge=charge
local burst=empty()
for j=0,39 do
    local a=j*2.39996323;local z=-.9+1.8*(j+.5)/40
    local rad=math.sqrt(1-z*z);local x,y=math.cos(a)*rad,math.sin(a)*rad
    local first=#burst.vertices;local width=.22+(j%3)*.12
    local sideX,sideY=-math.sin(a)*width,math.cos(a)*width
    for _,endp in ipairs({{18,0},{36+(j%4)*3,1}}) do
        local d,v=endp[1],endp[2]
        vertex(burst,x*d-sideX,y*d-sideY,z*d,0,v,0,1,0)
        vertex(burst,x*d+sideX,y*d+sideY,z*d,1,v,0,1,0)
    end
    tri(burst,first,first+1,first+2);tri(burst,first+1,first+3,first+2)
end
M.burst=burst
return M
