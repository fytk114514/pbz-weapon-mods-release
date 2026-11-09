// Editor commandlet only. Rebuild shader declarations from PBZ's captured
// renderer metadata; do not modify the engine installation or game process.
#include "CBAEditorLibrary.h"
#include "ShaderParameterMetadata.h"
#include "Shader.h"
#include "ShaderCore.h"
#include "VertexFactory.h"
#include "RHIResources.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Misc/CommandLine.h"
#include "Misc/Parse.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

namespace
{
using FMetadata = FShaderParametersMetadata;
// Deliberately process-lifetime allocations: shader type caches retain these
// pointers until commandlet shutdown, after the editor helper module unloads.
TArray<TUniquePtr<FString>>& CBAProfileStrings()
{
    static auto* Strings = new TArray<TUniquePtr<FString>>;
    return *Strings;
}
const TCHAR* KeepString(const FString& Text)
{
    auto& Strings = CBAProfileStrings();
    Strings.Add(MakeUnique<FString>(Text));
    return **Strings.Last();
}
const TCHAR* JsonString(const TSharedPtr<FJsonObject>& Object, const TCHAR* Key)
{
    const auto Value = Object->TryGetField(Key);
    return Value.IsValid() && !Value->IsNull() ? KeepString(Value->AsString()) : nullptr;
}
}

FString UCBAEditorLibrary::ApplyUniformProfile()
{
    checkf(IsRunningCommandlet() && FParse::Param(FCommandLine::Get(),TEXT("NullRHI")), TEXT("PBZ shader profiles require a NullRHI commandlet"));
    static FString CompletedReport;
    if (!CompletedReport.IsEmpty()) return CompletedReport;
    FString Text;
    const auto Path = FPaths::ProjectConfigDir() / TEXT("PBZUniformProfile.json");
    checkf(FFileHelper::LoadFileToString(Text,*Path), TEXT("Missing PBZ uniform profile"));
    TSharedPtr<FJsonObject> Profile;
    auto Reader=TJsonReaderFactory<>::Create(Text);
    checkf(FJsonSerializer::Deserialize(Reader,Profile) && Profile.IsValid(), TEXT("Invalid PBZ uniform profile JSON"));
    check(Profile->GetStringField(TEXT("format")) == TEXT("CBA_GameUniformProfile/1"));
    const auto Definitions=Profile->GetObjectField(TEXT("metadata"));
    TMap<FString,FMetadata*> Created;
    TSet<FString> InProgress;
    TFunction<FMetadata*(const FString&)> Build = [&](const FString& ID)->FMetadata*
    {
        if (auto** Found=Created.Find(ID)) return *Found;
        checkf(!InProgress.Contains(ID), TEXT("Cyclic PBZ metadata dependency"));
        InProgress.Add(ID);
        const auto Record=Definitions->GetObjectField(ID);
        TArray<FMetadata::FMember> Members;
        for (const auto& MemberValue : Record->GetArrayField(TEXT("members")))
        {
            const auto M=MemberValue->AsObject();
            const auto Child=M->TryGetField(TEXT("struct"));
            FMetadata* Nested=Child.IsValid() && !Child->IsNull() ? Build(Child->AsString()) : nullptr;
            Members.Emplace(JsonString(M,TEXT("name")),JsonString(M,TEXT("shader_type")),
                int32(M->GetIntegerField(TEXT("line"))),uint32(M->GetIntegerField(TEXT("offset"))),
                EUniformBufferBaseType(M->GetIntegerField(TEXT("base_type"))),
                EShaderPrecisionModifier::Type(M->GetIntegerField(TEXT("precision"))),
                uint32(M->GetIntegerField(TEXT("rows"))),uint32(M->GetIntegerField(TEXT("columns"))),
                uint32(M->GetIntegerField(TEXT("elements"))),Nested);
        }
        auto* Metadata=new FMetadata(FMetadata::EUseCase(Record->GetIntegerField(TEXT("use_case"))),
            EUniformBufferBindingFlags(Record->GetIntegerField(TEXT("binding_flags"))),
            JsonString(Record,TEXT("layout_name")),JsonString(Record,TEXT("type")),
            JsonString(Record,TEXT("shader_name")),JsonString(Record,TEXT("static_slot")),
            "PBZUniformProfile",0,uint32(Record->GetIntegerField(TEXT("size"))),Members,true,nullptr,
            FMetadata::EUsageFlags(Record->GetIntegerField(TEXT("usage_flags"))));
        Created.Add(ID,Metadata);
        InProgress.Remove(ID);
        return Metadata;
    };
    TArray<TSharedPtr<FJsonValue>> Results;
    for (const auto& RootValue : Profile->GetArrayField(TEXT("roots")))
    {
        const auto Root=RootValue->AsObject();
        auto* Replacement=Build(Root->GetStringField(TEXT("id")));
        const auto Expected=FCString::Strtoui64(*Root->GetStringField(TEXT("expected_hash")),nullptr,16);
        const auto& Layout=Replacement->GetLayout();
        checkf(Layout.GetHash()==uint32(Expected),TEXT("PBZ layout checksum mismatch for %s: %08x != %08x"),
            Replacement->GetShaderVariableName(),Layout.GetHash(),uint32(Expected));
        const auto& Resources=Root->GetArrayField(TEXT("expected_resources"));
        check(Layout.Resources.Num()==Resources.Num());
        for (int32 Index=0;Index<Resources.Num();++Index)
        {
            const auto R=Resources[Index]->AsObject();
            check(Layout.Resources[Index].MemberOffset==R->GetIntegerField(TEXT("offset")));
            check(uint8(Layout.Resources[Index].MemberType)==R->GetIntegerField(TEXT("type")));
        }
        FMetadata* Original=nullptr;
        for (TLinkedList<FMetadata*>::TIterator It(FMetadata::GetStructList());It;++It)
        {
            if ((*It)->GetShaderVariableHashedName()==Replacement->GetShaderVariableHashedName())
            {
                Original=*It;
                *It=Replacement;
                break;
            }
        }
        checkf(Original,TEXT("Unknown editor uniform buffer %s"),Replacement->GetShaderVariableName());
        FMetadata::GetNameStructMap().Add(Replacement->GetShaderVariableHashedName(),Replacement);
        FMetadata::GetStringStructMap().Add(Replacement->GetShaderVariableName(),Replacement);
        auto Result=MakeShared<FJsonObject>();
        Result->SetStringField(TEXT("name"),Replacement->GetShaderVariableName());
        Result->SetStringField(TEXT("stock_hash"),FString::Printf(TEXT("0x%08x"),Original->GetLayout().GetHash()));
        Result->SetStringField(TEXT("game_hash"),FString::Printf(TEXT("0x%08x"),Layout.GetHash()));
        Result->SetNumberField(TEXT("constant_bytes"),Layout.ConstantBufferSize);
        Results.Add(MakeShared<FJsonValueObject>(Result));
    }
    FlushShaderFileCache();
    TArray<const FShaderType*> ShaderTypes;
    for (TLinkedList<FShaderType*>::TConstIterator It(FShaderType::GetTypeList());It;++It) ShaderTypes.Add(*It);
    TArray<const FVertexFactoryType*> FactoryTypes;
    for (TLinkedList<FVertexFactoryType*>::TConstIterator It(FVertexFactoryType::GetTypeList());It;++It) FactoryTypes.Add(*It);
    UpdateReferencedUniformBufferNames(ShaderTypes,FactoryTypes,{});
    auto Writer=TJsonWriterFactory<>::Create(&CompletedReport);
    FJsonSerializer::Serialize(Results,Writer);
    UE_LOG(LogTemp,Display,TEXT("CBA_PBZ_UNIFORM_PROFILE_APPLIED %s"),*CompletedReport);
    return CompletedReport;
}
