#include "CBAEditorLibrary.h"
#include "NiagaraSystem.h"
#include "NiagaraEmitter.h"
#include "NiagaraScript.h"
#include "NiagaraSystemFactoryNew.h"
#include "NiagaraEditorUtilities.h"
#include "AssetRegistry/AssetRegistryModule.h"
#include "Misc/PackageName.h"
#include "Serialization/JsonWriter.h"
#include "Serialization/JsonSerializer.h"
#include "NiagaraScriptSource.h"
#include "NiagaraGraph.h"
#include "NiagaraNodeOutput.h"
#include "NiagaraNodeCustomHlsl.h"
#include "EdGraph/EdGraphPin.h"
#include "UObject/UnrealType.h"
#include "NiagaraSpriteRendererProperties.h"
#include "Materials/MaterialInterface.h"
#include "ShaderParameterMetadata.h"
#include "RHIResources.h"

FString UCBAEditorLibrary::InspectUniformLayouts()
{
    TArray<TSharedPtr<FJsonValue>> Entries;
    for (TLinkedList<FShaderParametersMetadata*>::TIterator It(FShaderParametersMetadata::GetStructList()); It; ++It)
    {
        auto* Metadata = *It;
        if (!Metadata || !Metadata->IsLayoutInitialized()) continue;
        const auto& Layout = Metadata->GetLayout();
        auto Entry = MakeShared<FJsonObject>();
        Entry->SetStringField(TEXT("name"), Metadata->GetShaderVariableName());
        Entry->SetStringField(TEXT("type"), Metadata->GetStructTypeName());
        Entry->SetStringField(TEXT("hash"), FString::Printf(TEXT("0x%08x"), Layout.GetHash()));
        Entry->SetNumberField(TEXT("constant_bytes"), Layout.ConstantBufferSize);
        TArray<TSharedPtr<FJsonValue>> Resources;
        for (const auto& Resource : Layout.Resources)
        {
            auto R = MakeShared<FJsonObject>();
            R->SetNumberField(TEXT("offset"),Resource.MemberOffset);
            R->SetNumberField(TEXT("type"),uint8(Resource.MemberType));
            Resources.Add(MakeShared<FJsonValueObject>(R));
        }
        Entry->SetArrayField(TEXT("resources"),Resources);
        Entries.Add(MakeShared<FJsonValueObject>(Entry));
    }
    FString Result;
    auto Writer = TJsonWriterFactory<>::Create(&Result);
    FJsonSerializer::Serialize(Entries,Writer);
    return Result;
}

UNiagaraSystem* UCBAEditorLibrary::CreateTemplateSystem(const FString& AssetPath, const FString& EmitterPath)
{
    if (!AssetPath.StartsWith(TEXT("/Game/Mods/CBAOriginalFX/"))) return nullptr;
    if (auto* Existing = LoadObject<UNiagaraSystem>(nullptr, *AssetPath)) return Existing;
    auto* Emitter = LoadObject<UNiagaraEmitter>(nullptr, *EmitterPath);
    if (!Emitter) return nullptr;
    FString Name = FPackageName::GetLongPackageAssetName(AssetPath);
    UPackage* Package = CreatePackage(*AssetPath);
    auto* System = NewObject<UNiagaraSystem>(Package, FName(*Name), RF_Public|RF_Standalone|RF_Transactional);
    UNiagaraSystemFactoryNew::InitializeSystem(System, true);
    FNiagaraEditorUtilities::AddEmitterToSystem(*System, *Emitter, Emitter->GetExposedVersion().VersionGuid, true);
    FAssetRegistryModule::AssetCreated(System);
    System->MarkPackageDirty();
    System->RequestCompile(true);
    System->WaitForCompilationComplete(true, false);
    return System;
}

FString UCBAEditorLibrary::InspectSystem(UNiagaraSystem* System)
{
    auto Root = MakeShared<FJsonObject>();
    if (!System) return TEXT("{}");
    Root->SetStringField(TEXT("asset"), System->GetPathName());
    TArray<TSharedPtr<FJsonValue>> Emitters;
    for (const auto& Handle : System->GetEmitterHandles())
    {
        auto Entry = MakeShared<FJsonObject>();
        Entry->SetStringField(TEXT("name"), Handle.GetName().ToString());
        auto Instance = Handle.GetInstance();
        auto* Data = Instance.GetEmitterData();
        if (!Data) continue;
        Entry->SetBoolField(TEXT("local_space"), Data->bLocalSpace);
        Entry->SetNumberField(TEXT("renderer_count"),Data->GetRenderers().Num());
        TArray<TSharedPtr<FJsonValue>> Scripts;
        for (UNiagaraScript* Script : {Data->EmitterSpawnScriptProps.Script.Get(),Data->EmitterUpdateScriptProps.Script.Get(),Data->SpawnScriptProps.Script.Get(),Data->UpdateScriptProps.Script.Get()})
        {
            if (!Script) continue;
            auto S = MakeShared<FJsonObject>();
            S->SetStringField(TEXT("name"), Script->GetName());
            S->SetNumberField(TEXT("compile_status"),int32(Script->GetLastCompileStatus()));
            S->SetStringField(TEXT("compiler_error"),Script->GetVMExecutableData().ErrorMsg);
            TArray<TSharedPtr<FJsonValue>> Events;
            for(const auto& Event : Script->GetVMExecutableData().LastCompileEvents)
                Events.Add(MakeShared<FJsonValueString>(Event.Message));
            S->SetArrayField(TEXT("compiler_events"),Events);
            S->SetStringField(TEXT("hlsl"),Script->GetVMExecutableData().LastHlslTranslation);
            TArray<FNiagaraVariable> Parameters;
            Script->RapidIterationParameters.GetParameters(Parameters);
            TArray<TSharedPtr<FJsonValue>> Vars;
            for (const auto& Var : Parameters)
            {
                auto V = MakeShared<FJsonObject>();
                V->SetStringField(TEXT("name"),Var.GetName().ToString());
                V->SetStringField(TEXT("type"),Var.GetType().GetName());
                if (const uint8* Bytes = Script->RapidIterationParameters.GetParameterData(Var))
                    V->SetStringField(TEXT("bytes"),BytesToHex(Bytes,Var.GetSizeInBytes()));
                Vars.Add(MakeShared<FJsonValueObject>(V));
            }
            S->SetArrayField(TEXT("rapid_iteration_parameters"),Vars);
            Scripts.Add(MakeShared<FJsonValueObject>(S));
        }
        Entry->SetArrayField(TEXT("scripts"),Scripts);
        Emitters.Add(MakeShared<FJsonValueObject>(Entry));
    }
    Root->SetArrayField(TEXT("emitters"),Emitters);
    FString Result;
    auto Writer=TJsonWriterFactory<>::Create(&Result);
    FJsonSerializer::Serialize(Root,Writer);
    return Result;
}

bool UCBAEditorLibrary::AppendParticleHlsl(UNiagaraSystem* System, const FString& Hlsl)
{
    if (!System || !System->GetPathName().StartsWith(TEXT("/Game/Mods/CBAOriginalFX/"))) return false;
    for (auto& Handle : System->GetEmitterHandles())
    {
        auto* Data = Handle.GetInstance().GetEmitterData();
        auto* Source = Data ? Cast<UNiagaraScriptSource>(Data->GraphSource) : nullptr;
        auto* Graph = Source ? Source->NodeGraph.Get() : nullptr;
        if (!Graph) return false;
        auto* Output = Graph->FindEquivalentOutputNode(ENiagaraScriptUsage::ParticleUpdateScript);
        if (!Output) return false;
        UEdGraphPin* MapInput = nullptr;
        for (UEdGraphPin* Pin : Output->Pins)
            if (Pin->Direction == EGPD_Input && Pin->LinkedTo.Num()) { MapInput = Pin; break; }
        if (!MapInput || MapInput->LinkedTo.Num() != 1) return false;
        UEdGraphPin* Previous = MapInput->LinkedTo[0];
        auto* Node = NewObject<UNiagaraNodeCustomHlsl>(Graph,NAME_None,RF_Transactional);
        Node->CreateNewGuid();
        Node->Signature.Name = TEXT("CBA_SourceEquations");
        Node->Signature.Inputs = {FNiagaraVariable(FNiagaraTypeDefinition::GetParameterMapDef(),TEXT("InputMap"))};
        Node->Signature.Outputs = {FNiagaraVariableBase(FNiagaraTypeDefinition::GetParameterMapDef(),TEXT("OutputMap"))};
        Node->ScriptUsage = ENiagaraScriptUsage::Module;
        auto* HlslProperty = FindFProperty<FStrProperty>(Node->GetClass(),TEXT("CustomHlsl"));
        if (!HlslProperty) return false;
        HlslProperty->SetPropertyValue_InContainer(Node,Hlsl);
        Graph->AddNode(Node,false,false);
        static_cast<UEdGraphNode*>(Node)->AllocateDefaultPins();
        auto* Input = Node->FindPin(TEXT("InputMap"),EGPD_Input);
        auto* Result = Node->FindPin(TEXT("OutputMap"),EGPD_Output);
        if (!Input || !Result) return false;
        MapInput->BreakLinkTo(Previous);
        Previous->MakeLinkTo(Input);
        Result->MakeLinkTo(MapInput);
        Graph->NotifyGraphChanged();
        static_cast<UNiagaraScriptSourceBase*>(Source)->MarkNotSynchronized(TEXT("CBA source equations"));
    }
    System->MarkPackageDirty();
    System->RequestCompile(true);
    System->WaitForCompilationComplete(true,false);
    return System->IsValid();
}

bool UCBAEditorLibrary::ConfigureSpriteSystem(UNiagaraSystem* System, UMaterialInterface* Material, bool LocalSpace, int32 ParticleCount, float Duration)
{
    if (!System || !Material || !System->GetPathName().StartsWith(TEXT("/Game/Mods/CBAOriginalFX/"))) return false;
    FNiagaraVariable MaterialParameter(FNiagaraTypeDefinition::GetUMaterialDef(),TEXT("User.CBA_Material"));
    System->GetExposedParameters().AddParameter(MaterialParameter);
    System->GetExposedParameters().SetUObject(Material,MaterialParameter);
    System->GetExposedParameters().SetParameterValue(0.0f,FNiagaraVariable(FNiagaraTypeDefinition::GetFloatDef(),TEXT("User.CBA_Time")),true);
    for (auto& Handle : System->GetEmitterHandles())
    {
        auto* Data = Handle.GetInstance().GetEmitterData();
        if (!Data) return false;
        Data->bLocalSpace = LocalSpace;
        for (auto* Renderer : Data->GetRenderers())
            if (auto* Sprite = Cast<UNiagaraSpriteRendererProperties>(Renderer))
            {
                Sprite->Material = Material;
                Sprite->MaterialUserParamBinding.Parameter = MaterialParameter;
            }
        for (UNiagaraScript* Script : {Data->EmitterSpawnScriptProps.Script.Get(),Data->EmitterUpdateScriptProps.Script.Get(),Data->SpawnScriptProps.Script.Get(),Data->UpdateScriptProps.Script.Get()})
        {
            if (!Script) continue;
            TArray<FNiagaraVariable> Vars;
            Script->RapidIterationParameters.GetParameters(Vars);
            for (const auto& Var : Vars)
            {
                const FString Name = Var.GetName().ToString();
                if (Var.GetType() == FNiagaraTypeDefinition::GetFloatDef() && (Name.EndsWith(TEXT(".LoopDuration")) || Name.EndsWith(TEXT(".Loop Duration")) || Name.EndsWith(TEXT(".Lifetime"))))
                    Script->RapidIterationParameters.SetParameterValue(Duration,Var);
                else if (Var.GetType() == FNiagaraTypeDefinition::GetIntDef() && Name.EndsWith(TEXT(".Spawn Count")))
                    Script->RapidIterationParameters.SetParameterValue(ParticleCount,Var);
            }
        }
    }
    System->MarkPackageDirty();
    System->RequestCompile(true);
    System->WaitForCompilationComplete(true,false);
    return System->IsValid();
}
