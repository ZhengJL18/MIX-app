@echo off
REM MIX Agent 打包脚本（Windows 构建机用）
REM 打包 Python + Hermes Agent + 所有依赖 → APK assets
REM 手机上只需解压，零网络零 pip

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set PROJECT_DIR=%SCRIPT_DIR%..
set ASSETS_DIR=%PROJECT_DIR%\android\app\src\main\assets
set BUILD_DIR=%PROJECT_DIR%\build\mix-agent-bundle

echo === MIX Agent 打包 ===
echo.

rmdir /s /q "%BUILD_DIR%" 2>nul
mkdir "%BUILD_DIR%" "%ASSETS_DIR%"

REM ── 1. 下载 Termux Python 3.11 ARM64 ──
echo [1/4] 下载 Python 3.11 ARM64...
if not exist "%BUILD_DIR%\python.deb" (
    curl -sL -o "%BUILD_DIR%\python.deb" ^
        https://packages.termux.org/apt/termux-main/pool/aarch64/python_3.11.11-1_aarch64.deb
)
echo Python deb: %~z1 bytes

REM ── 2. 下载 Hermes Agent ──
echo [2/4] 下载 Hermes Agent...
if not exist "%BUILD_DIR%\hermes-source" (
    git clone --depth 1 --branch v2026.7.20 ^
        https://github.com/NousResearch/hermes-agent.git "%BUILD_DIR%\hermes-source"
)

REM ── 3. 下载 pip 依赖（在构建机上，不是手机上） ──
echo [3/4] 下载 pip 依赖（构建机本地）...
mkdir "%BUILD_DIR%\pip-cache"
cd /d "%BUILD_DIR%\hermes-source"
pip3 install -r requirements.txt --target="%BUILD_DIR%\pip-cache" ^
    --only-binary=:all: --no-compile 2>&1 | findstr /v "already satisfied"

REM ── 4. 打包 ──
echo [4/4] 打包到 APK assets...
cd /d "%BUILD_DIR%"
mkdir bundle
move python.deb bundle\
move hermes-source bundle\hermes
move pip-cache bundle\hermes-packages
xcopy /s /i "%PROJECT_DIR%\mix-plugin" bundle\hermes\plugins\mix

REM 生成配置文件
echo server: {host: "127.0.0.1", port: 0} > bundle\hermes\config.yaml
echo model: "claude-sonnet-4-20250514" >> bundle\hermes\config.yaml
echo plugins: ["mix"] >> bundle\hermes\config.yaml

REM 用 tar 打包（需要 Windows 有 tar 命令，Win10+ 自带）
cd bundle
tar czf "%ASSETS_DIR%\mix-agent-bundle.tar.gz" .
echo.

echo === 打包完成 ===
echo 产物: %ASSETS_DIR%\mix-agent-bundle.tar.gz
