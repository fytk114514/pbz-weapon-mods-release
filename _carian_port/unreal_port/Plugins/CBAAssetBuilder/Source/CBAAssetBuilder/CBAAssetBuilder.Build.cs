using UnrealBuildTool;
public class CBAAssetBuilder : ModuleRules
{
    public CBAAssetBuilder(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new[] { "Core", "CoreUObject", "Engine", "Niagara" });
        PrivateDependencyModuleNames.AddRange(new[] { "UnrealEd", "AssetRegistry", "NiagaraCore", "NiagaraEditor", "Json", "JsonUtilities", "Projects", "RHI", "RenderCore" });
    }
}
