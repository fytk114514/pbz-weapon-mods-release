return {
    -- Blade only; the grip and guard retain their proportions.
    length={1.0,1.125/.65,1.6/.65},
    width={1.0,.625/.3,.95/.3},
    growSeconds=.3,
    shrinkSeconds=.28,
    emission={4.8,6.0,7.5},
    rimEmission=1.25,
    lightIntensity={650,1000,1450},
    particleEmission=4.0,
    offset={X=0,Y=0,Z=0},
    -- Local Z is the sword's long axis. Align the cutting plane with the axe swing.
    rotation={Pitch=0,Yaw=90,Roll=0},
    chargePulseSeconds=.42,
    summonSeconds=.24,
    impactFadeSeconds=.55,
    trailSeconds=.18,
    trailEmission=.8,
    originalLightUnits=.2,
    originalBrightness=.08,
    enabled=true,
}
