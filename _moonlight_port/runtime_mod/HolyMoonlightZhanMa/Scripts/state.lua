-- Latched visual form. Combat logic, damage and input are never modified.
local M={}
local function clamp(x) return math.max(0,math.min(1,x)) end
local function smooth(x) x=clamp(x);return x*x*(3-2*x) end
function M.new()
    return {mode="normal",form="unlit",blend=0,from=0,to=0,start=-10,duration=.48,
        wasLight=false,wasHeavy=false,wasCharge=false,chargeStart=0,releaseStart=-10}
end
function M.update(s,a,t)
    local light=a.light==true
    local heavy=a.heavy==true or a.charge==true
    local lightStart=a.lightStart
    local heavyStart=a.heavyStart
    if lightStart==nil then lightStart=light and not s.wasLight end
    if heavyStart==nil then heavyStart=heavy and not s.wasHeavy end
    local target=s.form
    if heavyStart then target="glowing" end
    if lightStart then target="unlit" end
    if s.request then target=s.request;s.request=nil end -- development only
    local switched
    if target~=s.form then
        s.from=s.blend;s.to=target=="glowing" and 1 or 0
        s.form=target;switched=target;s.switchAt=t
        -- lighting up: the moonlight forms around the blade first (transition_fx.lua) and the blade
        -- glows under it; going dark: the glow drops off quickly and leaves its sparkles behind
        -- (1.3: the blade lights up under the moonlight shells, as in Bloodborne, and is fully lit when they fade)
        if target=="glowing" then s.start=t+.25;s.duration=.4 else s.start=t;s.duration=.2 end
    end
    local progress=clamp((t-s.start)/s.duration)
    s.blend=s.from+(s.to-s.from)*smooth(progress)
    local transition=(progress<1 or t<s.start) and math.abs(s.to-s.from)>.001
    local charge=a.charge==true and not lightStart
    if charge and not s.wasCharge then s.chargeStart=t end
    if not charge and s.wasCharge then s.releaseStart=t;s.released=a.chargeAbility==true end
    local q=charge and smooth((t-s.chargeStart)/.85) or 0
    local release=clamp((t-s.releaseStart)/.42)
    local burst=(not charge and s.released and release<1) and math.sin(release*math.pi) or 0
    if lightStart then burst=0;s.releaseStart=-10;s.released=false end
    local b=s.blend;local pulse=.96+.025*math.sin(t*2.8)+.015*math.sin(t*5.3)
    local mode=light and "light" or (heavy and "heavy" or "normal")
    s.mode=mode;s.wasLight=light;s.wasHeavy=heavy;s.wasCharge=charge
    -- the form-switch effect's own light is added in main.lua (transition_fx.lua). 1.3.2: the glowing form's
    -- steady light is Bloodborne's two moonlights off the blade's faces (moonIntensity, main.lua MOON_LIGHT);
    -- lightIntensity, the light at the blade's centre, is the charge and its release only
    return {mode=mode,form=s.form,blend=b,unlit=b<.5,glowing=b>=.5,aura=b>.001,switched=switched,
        transition=transition,progress=progress,
        age=t,angle=t*80,
        intensity=1.9*b*pulse*(1+1.1*q)+burst*1.4,
        mistIntensity=1.1*b,moteIntensity=3*b+q*2,
        ribbonIntensity=2.5*q,lightIntensity=1600*q+1700*burst,moonIntensity=b,
        charge=charge,chargeProgress=q,chargeIntensity=charge and (2+7*q) or 8*burst,
        burstIntensity=10*burst,releaseProgress=release,
        sparkIntensity=charge and 2*q or 3*burst}
end
return M
