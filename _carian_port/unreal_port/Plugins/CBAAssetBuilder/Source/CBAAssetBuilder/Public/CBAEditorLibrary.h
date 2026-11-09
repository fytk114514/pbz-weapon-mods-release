#pragma once
#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "CBAEditorLibrary.generated.h"
class UNiagaraSystem;
class UMaterialInterface;

UCLASS()
class CBAASSETBUILDER_API UCBAEditorLibrary : public UBlueprintFunctionLibrary
{
    GENERATED_BODY()
public:
    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static FString InspectUniformLayouts();

    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static FString ApplyUniformProfile();

    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static UNiagaraSystem* CreateTemplateSystem(const FString& AssetPath, const FString& EmitterPath);

    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static FString InspectSystem(UNiagaraSystem* System);

    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static bool AppendParticleHlsl(UNiagaraSystem* System, const FString& Hlsl);

    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static bool ConfigureSpriteSystem(UNiagaraSystem* System, UMaterialInterface* Material, bool LocalSpace, int32 ParticleCount, float Duration);

    UFUNCTION(BlueprintCallable, Category="Carian Source Conversion")
    static bool AddParticleArrayDriver(UNiagaraSystem* System);
};
