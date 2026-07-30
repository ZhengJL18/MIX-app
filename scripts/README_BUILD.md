# MIX Agent 打包说明

## 前置条件

在构建机上运行，需要：
- curl / git
- Python 3.11+（打包机自己的，不是给手机用的）
- pip3

## 打包

```bash
cd scripts/
bash package-hermes.sh
```

脚本会：
1. 下载 Python 3.11 ARM64 编译版
2. 下载 Hermes Agent v0.18.0 源码
3. 安装所有 pip 依赖到指定目录（版本锁定）
4. 复制 MIX 插件
5. 打包成 `android/app/src/main/assets/mix-agent-bundle.tar.gz`

## APK 构建

打包完成后，正常用 flutter build 即可：

```bash
flutter build apk --debug
```

首次启动时 App 会自动解压 bundle。

## 后续更新 Hermes 版本

1. 修改 `package-hermes.sh` 中的版本号
2. 重新运行脚本
3. 重新构建 APK

## MIX 插件开发

插件在 `mix-plugin/` 目录下，每个 Python 文件实现 `register_tools(registry)` 函数，
用 `registry.register_tool()` 注册工具。写完后重新打包即可。
