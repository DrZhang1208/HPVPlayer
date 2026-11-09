# third_party 说明

本仓库不含大体积预编译产物与嵌套仓库，克隆后需自行获取以下内容：

## libmpv-dist（必需，约 49M）

`libmpv.so`（arm64-v8a，HarmonyOS 交叉编译版）+ 头文件。

获取方式：使用上游 [libmpv-ohos-build](https://gitcode.com/) 项目交叉编译：

```bash
git clone <libmpv-ohos-build 仓库地址> third_party/libmpv-ohos-build
cd third_party/libmpv-ohos-build
./download.sh && ./build.sh && ./bundle.sh
```

放置后的目录结构：
```
third_party/libmpv-dist/
├── include/mpv/*.h
└── lib/arm64-v8a/libmpv.so
```

## mpv/libs（必需，约 34M）

把 `libmpv.so` 复制到 `mpv/libs/arm64-v8a/`（mpv HAR 模块打包用）。

## mpv-arkts（必需，约 13M）

mpv 的 ArkTS/HAR 封装（本项目 mpv 模块依赖 `@mpv-ohos/mpv-arkts`），是独立 git 仓库：

```bash
git clone <mpv-arkts 仓库地址> third_party/mpv-arkts
```

## mpv/src/main/cpp/third_party（已包含）

aki（NAPI 绑定）与 simdjson 源码，随仓库提交，无需额外操作。
