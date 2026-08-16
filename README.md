## Build

-----------------------------------环境准备-------------------------------------

# 更新子模块
git submodule update --init --recursive

# 初次执行，只执行一次
git -C BaseBin/XPF apply $PWD/.github/patches/XPF-roothide.patch
git -C BaseBin/opainject apply $PWD/.github/patches/opainject-build.patch

# 检查状态
git -C BaseBin/XPF status
git -C BaseBin/opainject status

# theos下载
git clone --recursive https://github.com/roothide/theos.git theos
git -C theos checkout --detach 88506b2c22e9e07dd4ed055f23c9e398a117a2c7
git -C theos submodule update --init --recursive
export THEOS="$PWD/theos"

# 改变xcode-select、设置环境变量 Xcode_16
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export THEOS="$PWD/theos"

echo "$DEVELOPER_DIR"
echo "$THEOS"

# 验证生效与否
xcrun --sdk iphoneos --show-sdk-path
xcode-select -p
xcodebuild -version

# 编译 systemhook
gmake -C BaseBin systemhook
# 如果成功，检查：
ls -lh BaseBin/systemhook/systemhook.dylib
file BaseBin/systemhook/systemhook.dylib

-----------------------------------打包命令-------------------------------------

# 清理编译文件 然后清理 Clang Module Cache
rm -rf BaseBin/roothidehooks/.theos
rm -rf BaseBin/.theos
rm -rf BaseBin/.build
rm -rf BaseBin/.include
rm -rf ~/Library/Developer/Xcode/DerivedData
rm -rf /var/folders/6p/*/C/clang/ModuleCache
rm -rf ~/Library/Caches/com.apple.dt.Xcode/*

# 每日版本
gmake clean
gmake -j"$(sysctl -n hw.logicalcpu)" NIGHTLY=1

# 固定版本
gmake clean
gmake -j"$(sysctl -n hw.logicalcpu)" NIGHTLY=0

# -I../.include

-----------------------------------说明信息-------------------------------------


                 GitHub macOS 14
                       │
                 Xcode 15.4
                       │
              iPhoneOS17.5.sdk
                       │
            ┌──────────┴──────────┐
            │                     │
        Xcode/xcrun             actool
            │                     │
            ↓                     ↓
       系统组件/App        Assets.car/AppIcon


                 Theos
                   │
            iPhoneOS16.5.sdk
                   │
                   ↓
          BaseBin / Tweaks

# RootHide on Dopamine 3

RootHide on Dopamine 3 ports the RootHide jailbreak environment to the
Dopamine 3 codebase. It keeps Dopamine's device and exploit support while
providing RootHide's randomized jailbreak root and package environment.

This project is experimental. Back up important data before testing, and
remove incompatible tweaks if SpringBoard enters a respring loop.

## Downloads and changelog

Download signed builds and read the changelog on the
[GitHub Releases](https://github.com/P013onEr/RootHide/releases) page. The
in-app update screen reads release notes from the same location.

## Tested configuration

- iPhone 14 Pro Max (iPhone15,3)
- iOS 16.6
- Dopamine 3.0.6 base

Other devices and versions supported by Dopamine 3 may work, but should be
treated as unverified until they have been tested with this RootHide port.

## Community

- Telegram: https://t.me/+WtnN67BeOsA1MGM5
- RootHide developer documentation: https://github.com/roothide/Developer

## Building

See [BUILD.md](BUILD.md) for GitHub Actions instructions. The workflow used by
this repository is available at [.github/workflows/roothide.yml](.github/workflows/roothide.yml).

## Credits

- Dopamine: https://github.com/opa334/Dopamine
- RootHide: https://github.com/roothide
- Dopamine2-roothide: https://github.com/roothide/Dopamine2-roothide

This repository retains the licenses and attribution of its upstream
components.

