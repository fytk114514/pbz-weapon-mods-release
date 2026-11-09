# 影之刃零武器模组源码（卡利亚 3.6.2、月光大剑 1.3.6）

Release 里两个懒人包的源码：模组运行用的脚本，以及把《艾尔登法环》《血源诅咒》原版文件转换成模组数据的构建工具。

## 目录

- `_carian_port/runtime_v14/CarianBrutalAxe/`：卡利亚模组的脚本，`SoundHelper` 是音效播放器的源码。
- `_carian_port/original_runtime/`：法环特效（FXR）的 Lua 解释器，离线烘焙特效轨迹用。
- `_carian_port/toolchain/`：卡利亚的构建工具。依次是：`ErAssetBridge` 解包，`extract_grandeur.mjs`、`build_grandeur_ir.mjs` 提取特效，`build_er_blade.py` 生成剑身，`bake_fx_tracks.py`、`bake_gpu.py` 烘焙，`build_fx_container.py` 生成材质包，`extract_grandeur_sounds.py` 提取音效，`build_v14_release.py` 出包。
- `_carian_port/unreal_port/`：生成材质包用的 UE 5.7 工程，包括配置、插件和建材质的脚本。
- `_carian_port/release_v14/`：加载器配置、安装说明和开发说明（`使用说明.md`）。
- `_moonlight_port/runtime_mod/HolyMoonlightZhanMa/`：月光大剑模组的脚本。
- `_moonlight_port/toolchain/`：月光的构建工具。`BbAssetBridge` 解包，`build_bloodborne_sword.py` 生成剑的网格和贴图，`build_moonlight_transform_fx.py` 生成变形特效，`build_moonlight_fx.py` 生成发光部件的贴图，`bb_sfx/bbfxr.py` 读取血源的特效文件。
- `_moonlight_port/build_release.py`：月光出包。

## 不在这里的

- 工具生成的数据，包括剑的网格、特效数据和轨迹、贴图、音效：在两个懒人包里，也可以用构建工具从自己的游戏文件重新生成。
- 游戏文件和第三方工具，需要自备：《艾尔登法环》、《血源诅咒》PS4 v1.09 的文件，以及 .NET SDK、SoulsFormatsNEXT、WitchyBND、Node.js（@cccode/fxr）、vgmstream、Unreal Engine 5.7、UE4SS。
- 脚本里的本机路径换成了尖括号占位符，例如 `<仓库根目录>`，使用前改成自己的路径。

剑的模型、贴图、特效和音效来自《艾尔登法环》《血源诅咒》，相关权利归原游戏的权利人。
