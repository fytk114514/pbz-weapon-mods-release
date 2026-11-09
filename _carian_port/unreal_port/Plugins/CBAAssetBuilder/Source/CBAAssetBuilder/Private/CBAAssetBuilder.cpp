#include "Modules/ModuleManager.h"
#include "CBAEditorLibrary.h"
#include "Misc/CommandLine.h"
#include "Misc/Parse.h"
class FCBAAssetBuilderModule : public IModuleInterface
{
public:
    void StartupModule() override
    {
        if (FParse::Param(FCommandLine::Get(),TEXT("CBAUniformProfile")))
            UCBAEditorLibrary::ApplyUniformProfile();
    }
};
IMPLEMENT_MODULE(FCBAAssetBuilderModule, CBAAssetBuilder)
