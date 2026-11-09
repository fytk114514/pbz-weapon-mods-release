#include "CBAEditorLibrary.h"
#include "NiagaraSystem.h"
#include "NiagaraEmitter.h"
#include "NiagaraScriptSource.h"
#include "NiagaraGraph.h"
#include "NiagaraNodeOutput.h"
#include "NiagaraNodeCustomHlsl.h"
#include "NiagaraNodeInput.h"
#include "NiagaraDataInterfaceArrayFloat.h"
#include "NiagaraSpriteRendererProperties.h"
#include "EdGraph/EdGraphPin.h"
#include "UObject/UnrealType.h"

bool UCBAEditorLibrary::AddParticleArrayDriver(UNiagaraSystem* System)
{
    if (!System || !System->GetPathName().StartsWith(TEXT("/Game/Mods/CBAOriginalFX/"))) return false;
    FNiagaraTypeDefinition ArrayType(UNiagaraDataInterfaceArrayColor::StaticClass());
    FNiagaraVariable UserData(ArrayType,TEXT("User.CBA_ParticleData"));
    auto* Array=NewObject<UNiagaraDataInterfaceArrayColor>(System);
    Array->ColorData.SetNumZeroed(9*128);
    System->GetExposedParameters().AddParameter(UserData);
    System->GetExposedParameters().SetDataInterface(Array,UserData);
    for (auto& Handle : System->GetEmitterHandles())
    {
        auto* Data=Handle.GetInstance().GetEmitterData();
        auto* Source=Data ? Cast<UNiagaraScriptSource>(Data->GraphSource) : nullptr;
        auto* Graph=Source ? Source->NodeGraph.Get() : nullptr;
        if (!Graph) return false;
        auto* Output=Graph->FindEquivalentOutputNode(ENiagaraScriptUsage::ParticleUpdateScript);
        UEdGraphPin* MapInput=nullptr;
        if (Output) for(auto* Pin : Output->Pins) if(Pin->Direction==EGPD_Input && Pin->LinkedTo.Num()==1){MapInput=Pin;break;}
        if (!MapInput) return false;
        auto* Previous=MapInput->LinkedTo[0];
        auto* Node=NewObject<UNiagaraNodeCustomHlsl>(Graph,NAME_None,RF_Transactional);
        Node->CreateNewGuid();
        Node->Signature.Name=TEXT("CBA_OriginalParticleBuffer");
        Node->Signature.Inputs={FNiagaraVariable(FNiagaraTypeDefinition::GetParameterMapDef(),TEXT("InputMap")),FNiagaraVariable(ArrayType,TEXT("ParticleData"))};
        Node->Signature.Outputs={FNiagaraVariableBase(FNiagaraTypeDefinition::GetParameterMapDef(),TEXT("OutputMap"))};
        Node->ScriptUsage=ENiagaraScriptUsage::Module;
        const FString Hlsl=TEXT(
            "int i=ExecIndex()*9;\n"
            "float4 p,s,c,f,a,d,t1,t2,t3;\n"
            "ParticleData.Get(i,p); ParticleData.Get(i+1,s); ParticleData.Get(i+2,c);\n"
            "ParticleData.Get(i+3,f); ParticleData.Get(i+4,a); ParticleData.Get(i+5,d);\n"
            "ParticleData.Get(i+6,t1); ParticleData.Get(i+7,t2); ParticleData.Get(i+8,t3);\n"
            "Particles.Position=p.xyz; Particles.SpriteSize=float2(p.w,s.x);\n"
            "Particles.SpriteRotation=s.y; Particles.SubImageIndex=s.z; Particles.Color=c;\n"
            "Particles.SpriteFacing=f.xyz; Particles.SpriteAlignment=a.xyz;\n"
            "Particles.DynamicMaterialParameter=d; Particles.DynamicMaterialParameter1=t1;\n"
            "Particles.DynamicMaterialParameter2=t2; Particles.DynamicMaterialParameter3=t3;\n");
        auto* HlslProperty=FindFProperty<FStrProperty>(Node->GetClass(),TEXT("CustomHlsl"));
        if (!HlslProperty) return false;
        HlslProperty->SetPropertyValue_InContainer(Node,Hlsl);
        Graph->AddNode(Node,false,false);
        static_cast<UEdGraphNode*>(Node)->AllocateDefaultPins();
        MapInput->BreakLinkTo(Previous);
        Previous->MakeLinkTo(Node->FindPin(TEXT("InputMap"),EGPD_Input));
        Node->FindPin(TEXT("OutputMap"),EGPD_Output)->MakeLinkTo(MapInput);
        // A standalone Input node registers an emitter-local DI. Read the
        // exposed User parameter from the map so runtime overrides bind it.
        auto* GetClass=FindObject<UClass>(nullptr,TEXT("/Script/NiagaraEditor.NiagaraNodeParameterMapGet"));
        if (!GetClass) return false;
        auto* Get=NewObject<UEdGraphNode>(Graph,GetClass,NAME_None,RF_Transactional);
        Get->CreateNewGuid();Graph->AddNode(Get,false,false);Get->AllocateDefaultPins();
        auto* DataPin=Node->FindPin(TEXT("ParticleData"),EGPD_Input);
        auto* ReadPin=Get->CreatePin(EGPD_Output,DataPin->PinType,TEXT("User.CBA_ParticleData"));
        ReadPin->PinType.PinSubCategory=TEXT("ParameterPin");ReadPin->PersistentGuid=FGuid::NewGuid();
        auto* DefaultPin=Get->CreatePin(EGPD_Input,ReadPin->PinType,NAME_None);
        DefaultPin->PersistentGuid=FGuid::NewGuid();DefaultPin->bNotConnectable=true;
        DefaultPin->bDefaultValueIsReadOnly=true;DefaultPin->bHidden=true;
        auto* Pairs=FindFProperty<FMapProperty>(GetClass,TEXT("PinOutputToPinDefaultPersistentId"));
        if (!Pairs) return false;
        Pairs->ContainerPtrToValuePtr<TMap<FGuid,FGuid>>(Get)->Add(ReadPin->PersistentGuid,DefaultPin->PersistentGuid);
        Previous->MakeLinkTo(Get->FindPin(TEXT("Source"),EGPD_Input));
        ReadPin->MakeLinkTo(DataPin);
        for(auto* Renderer : Data->GetRenderers()) if(auto* Sprite=Cast<UNiagaraSpriteRendererProperties>(Renderer))
        {
            Sprite->FacingMode=ENiagaraSpriteFacingMode::CustomFacingVector;
            Sprite->Alignment=ENiagaraSpriteAlignment::CustomAlignment;
            const FVersionedNiagaraEmitterBase Emitter(Handle.GetInstance().Emitter,Handle.GetInstance().Version);
            Sprite->SpriteFacingBinding.SetValue(TEXT("Particles.SpriteFacing"),Emitter,ENiagaraRendererSourceDataMode::Particles);
            Sprite->SpriteAlignmentBinding.SetValue(TEXT("Particles.SpriteAlignment"),Emitter,ENiagaraRendererSourceDataMode::Particles);
            Sprite->DynamicMaterialBinding.SetValue(TEXT("Particles.DynamicMaterialParameter"),Emitter,ENiagaraRendererSourceDataMode::Particles);
            Sprite->DynamicMaterial1Binding.SetValue(TEXT("Particles.DynamicMaterialParameter1"),Emitter,ENiagaraRendererSourceDataMode::Particles);
            Sprite->DynamicMaterial2Binding.SetValue(TEXT("Particles.DynamicMaterialParameter2"),Emitter,ENiagaraRendererSourceDataMode::Particles);
            Sprite->DynamicMaterial3Binding.SetValue(TEXT("Particles.DynamicMaterialParameter3"),Emitter,ENiagaraRendererSourceDataMode::Particles);
            Sprite->SubImageIndexBinding.SetValue(TEXT("Particles.SubImageIndex"),Emitter,ENiagaraRendererSourceDataMode::Particles);
        }
        Graph->NotifyGraphChanged();
        static_cast<UNiagaraScriptSourceBase*>(Source)->MarkNotSynchronized(TEXT("CBA original particle array driver"));
    }
    System->MarkPackageDirty();System->RequestCompile(true);System->WaitForCompilationComplete(true,false);
    return System->IsValid();
}
