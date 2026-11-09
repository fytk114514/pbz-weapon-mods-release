"""Deterministic tileable mist texture for the reconstructed moonlight shader."""
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(__file__).parents[1]
y,x=np.mgrid[0:512,0:256]/np.array([512,256])[:,None,None]
noise=np.zeros_like(x)
rng=np.random.default_rng(5937)
for frequency,amplitude in [(2,.45),(5,.27),(11,.16),(23,.08),(43,.04)]:
    for k in range(5):
        fx=int(rng.integers(1,frequency+1)); fy=int(rng.integers(1,frequency+1))
        noise+=amplitude/5*np.sin(2*np.pi*(fx*x+fy*y)+rng.random()*2*np.pi)
wisps=np.clip(.48+noise,0,1)**2
edge=np.sin(np.pi*x)**2
alpha=np.clip(wisps*edge*1.8,0,1)
cyan=np.array([.10,1.,.89])
rgb=np.concatenate([alpha[:,:,None]*cyan[None,None,:],np.ones((*alpha.shape,1))],-1)
out=root/'runtime_mod/HolyMoonlightZhanMa/Textures/Moonlight_Mist.png'
Image.fromarray(np.uint8(np.clip(rgb,0,1)*255)).save(out)
print(out)
# Put the tint and falloff in the texture as well as the MID. This material's
# cooked permutation does not consistently apply Main_Color to procedural meshes.
gy,gx=np.mgrid[-1:1:128j,-1:1:128j]
falloff=np.clip(1-gx*gx-gy*gy,0,1)**2
glow=np.concatenate([falloff[:,:,None]*cyan[None,None,:],np.ones((*falloff.shape,1))],-1)
Image.fromarray(np.uint8(np.clip(glow,0,1)*255)).save(out.with_name('Moonlight_Cyan_Glow.png'))

# 1.3: the form-switch effect is Bloodborne's own (build_moonlight_transform_fx.py); the 1.2 smoke and
# spark atlases made here are gone.
