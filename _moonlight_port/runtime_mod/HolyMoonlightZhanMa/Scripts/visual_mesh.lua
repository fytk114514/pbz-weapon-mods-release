-- Split by the source blade UV island, including its narrow root bevel.
local M={}
function M.partition(data)
    local hilt,blade={},{}
    for i=1,#data.indices,3 do
        local ids={data.indices[i],data.indices[i+1],data.indices[i+2]}
        local luminous=true
        for _,id in ipairs(ids) do
            if data.uv0[id+1].X<=.7 then luminous=false end
        end
        local out=luminous and blade or hilt
        for _,id in ipairs(ids) do out[#out+1]=id end
    end
    assert(#blade>0 and #hilt>0,"luminous blade partition is empty")
    return hilt,blade
end
-- The vertices moved by d (cm) along their shading normals: a layer just outside the surface (1.3.2: the
-- blade light over the glowing form's metal; both are opaque, so at the same depth they would fight).
function M.inflate(data,d)
    local out={}
    for i,v in ipairs(data.vertices) do
        local n=data.normals[i]
        out[i]={X=v.X+n.X*d,Y=v.Y+n.Y*d,Z=v.Z+n.Z*d}
    end
    return out
end
-- Rigid rotation around the lower gripping hand. No vertex deformation or
-- change to handle length: the wide blade tilts clear of the supporting palm.
-- roll (degrees) first turns the sword about its own long axis, which is the
-- handle axis, so the grip stays where it is (the combat art uses it, main.lua).
function M.guardPose(degrees,scaleY,scaleZ,roll)
    local a=math.rad(degrees);local s,c=math.sin(a),math.cos(a)
    local pivot=-60
    local ratio=(scaleZ or 1)/(scaleY or 1)
    local b=math.rad(roll or 0);local sb,cb=math.sin(b),math.cos(b)
    return {X=0,Y=-pivot*s*ratio,Z=pivot*(1-c)},
        {X=cb,Y=sb*c,Z=-sb*s},{X=-sb,Y=cb*c,Z=-cb*s},{X=0,Y=s,Z=c}
end
return M
