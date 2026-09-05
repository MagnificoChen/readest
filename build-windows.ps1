#Requires -Version 5.1
<#
.SYNOPSIS
  Readest Windows 一键编译/发布脚本。

.DESCRIPTION
  1. 环境检查: Node.js / pnpm / Rust / MSVC(VS 2022 C++ 生成工具) / Rust 编译目标,
     任一不满足则给出修复方法并以非零码退出。
  2. 依赖准备: git submodule -> pnpm install -> setup-vendors。
  3. 编译发布: pnpm tauri build --target <triple> --bundles nsis
     (与官方 .github/workflows/release.yml 的 Windows 流程一致)。
  4. 可选: -Portable 额外产出便携版 exe; 设置了 TAURI_SIGNING_PRIVATE_KEY 时自动签名。

  产物位置:
    NSIS 安装包:  target\<triple>\release\bundle\nsis\Readest_<version>_<arch>-setup.exe
    便携版 exe:   仓库根目录 Readest_<version>_<arch>-portable.exe

.EXAMPLE
  .\build-windows.ps1                 # x64 NSIS 安装包(默认), 自动更新已编译期禁用
  .\build-windows.ps1 -Portable       # 同时产出便携版
  .\build-windows.ps1 -Arch arm64     # ARM64(额外需要 clang 与 aarch64 编译目标)
  .\build-windows.ps1 -CheckOnly      # 仅检查环境, 不编译
  .\build-windows.ps1 -SkipDeps       # 跳过依赖准备(重复编译提速)

.NOTES
  执行策略受限时运行:
    powershell -ExecutionPolicy Bypass -File .\build-windows.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [switch]$Portable,
    [switch]$SkipDeps,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# ---------------------------------------------------------------- 工具函数
function Fail([string]$Message) {
    Write-Host "`n[失败] $Message" -ForegroundColor Red
    exit 1
}
function Warn([string]$Message) {
    Write-Host "  [警告] $Message" -ForegroundColor Yellow
}
function Ok([string]$Message) {
    Write-Host "  [通过] $Message" -ForegroundColor Green
}
function Test-Cmd([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}
function Test-VersionAtLeast([string]$Current, [string]$Minimum) {
    $c = $Current.TrimStart('v').Split('.') | ForEach-Object { [int]$_ }
    $m = $Minimum.Split('.') | ForEach-Object { [int]$_ }
    $n = [Math]::Max($c.Count, $m.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $cv = if ($i -lt $c.Count) { $c[$i] } else { 0 }
        $mv = if ($i -lt $m.Count) { $m[$i] } else { 0 }
        if ($cv -ne $mv) { return $cv -gt $mv }
    }
    return $true
}
function Invoke-Checked([string]$Name, [string]$Command, [string[]]$Arguments) {
    Write-Host "`n==> $Name" -ForegroundColor Cyan
    # PS 5.1 下 EAP=Stop 会把原生命令的 stderr(tauri/cargo 的进度行)升级为终止错误, 须临时放行
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command @Arguments } finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0) { Fail "$Name 失败(退出码 $LASTEXITCODE)" }
}

# ---------------------------------------------------------------- 环境检查
Write-Host "`n==== Readest Windows 编译环境检查 ====" -ForegroundColor Cyan

if (-not (Test-Path 'Cargo.toml') -or -not (Test-Path 'apps\readest-app\package.json')) {
    Fail '未找到 Cargo.toml / apps\readest-app, 请在 Readest 仓库根目录运行本脚本'
}

if (Test-Cmd git) {
    Ok "git $( (& git --version) )"
} else {
    Fail '未找到 git(子模块初始化需要)。安装: https://git-scm.com/download/win'
}

if (-not (Test-Cmd node)) { Fail '未找到 Node.js。安装: https://nodejs.org/ (推荐 v24 LTS)' }
$nodeVersion = (& node --version).TrimStart('v')
if (-not (Test-VersionAtLeast $nodeVersion '20.9.0')) {
    Fail "Node.js 版本过低(当前 $nodeVersion, Next.js 16 要求 >= 20.9)。请升级: https://nodejs.org/"
}
Ok "Node.js v$nodeVersion"
if ([int]($nodeVersion.Split('.')[0]) -lt 24) {
    Warn "建议 Node.js v24(CI 基准), 当前 v$nodeVersion 一般也可编译"
}

if (-not (Test-Cmd pnpm)) { Fail '未找到 pnpm。安装: npm install -g pnpm 或 corepack enable' }
$pnpmVersion = (& pnpm --version)
if (($pnpmVersion.Split('.')[0]) -ne '11') {
    Warn "项目锁定 pnpm@11.1.1, 当前 $pnpmVersion; corepack 会按 packageManager 字段自动匹配"
}
Ok "pnpm $pnpmVersion"

if (-not (Test-Cmd rustc) -or -not (Test-Cmd cargo)) {
    Fail '未找到 Rust/Cargo。安装: https://rustup.rs'
}
$rustVersion = ((& rustc --version) -replace '^rustc ', '' -replace ' \(.*$', '')
if (-not (Test-VersionAtLeast $rustVersion '1.77.2')) {
    Fail "Rust 版本过低(当前 $rustVersion, Cargo.toml 要求 >= 1.77.2)。请运行: rustup update"
}
Ok "Rust $rustVersion"

$rustTarget = if ($Arch -eq 'x64') { 'x86_64-pc-windows-msvc' } else { 'aarch64-pc-windows-msvc' }
if (-not (Test-Cmd rustup)) { Fail '未找到 rustup, 无法校验编译目标。请通过 https://rustup.rs 安装' }
$installedTargets = @(& rustup target list --installed)
if ($installedTargets -notcontains $rustTarget) {
    Fail "缺少 Rust 编译目标 $rustTarget。安装: rustup target add $rustTarget"
}
Ok "Rust 目标: $rustTarget"

# MSVC: 优先标准桌面库布局(lib\<arch>); VS 2026 最小 C++ 工具集只有 lib\onecore\<arch>,
# 此时自动拼 LIB 环境变量(MSVC onecore + Windows SDK ucrt/um)兜底, 否则 link.exe 报 LNK1104
$programFilesX86 = ${env:ProgramFiles(x86)}
if (-not $programFilesX86) { $programFilesX86 = $env:ProgramFiles }
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
$archLib = if ($Arch -eq 'x64') { 'x64' } else { 'arm64' }
$msvcToolchain = $null
if (Test-Path $vswhere) {
    $installPaths = @(& $vswhere -products * -property installationPath | Where-Object { $_ })
    foreach ($ip in $installPaths) {
        $msvcDir = Join-Path $ip 'VC\Tools\MSVC'
        if (-not (Test-Path $msvcDir)) { continue }
        $latest = Get-ChildItem $msvcDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest -and (Test-Path (Join-Path $latest.FullName "bin\HostX64\$archLib"))) {
            $msvcToolchain = $latest.FullName
            break
        }
    }
}
if (-not $msvcToolchain) {
    Fail '未检测到 MSVC 工具链(需要 VS 2022+ / VS 2026 并含 C++ 工具集)。安装 Visual Studio 并勾选 Desktop development with C++ 工作负载'
}
$msvcLibDir = $null
if (Test-Path (Join-Path $msvcToolchain "lib\$archLib")) {
    $msvcLibDir = Join-Path $msvcToolchain "lib\$archLib"
    Ok "MSVC: $msvcToolchain"
} elseif (Test-Path (Join-Path $msvcToolchain "lib\onecore\$archLib")) {
    $msvcLibDir = Join-Path $msvcToolchain "lib\onecore\$archLib"
    Ok "MSVC: $msvcToolchain (onecore 库布局)"
    Warn "MSVC 缺少标准桌面库目录(lib\$archLib), 未安装完整 C++ 工作负载, 已自动用 onecore 库兜底"
} else {
    Fail "MSVC 工具链缺少 $archLib 链接库。请在 Visual Studio Installer 中补装 Desktop development with C++ 工作负载"
}

# Windows SDK: 库(um/ucrt) + 头文件, 供 LIB/INCLUDE 兜底
$sdkLibRoot = $null; $sdkVersion = $null
foreach ($root in @((Join-Path $programFilesX86 'Windows Kits\10\Lib'), (Join-Path $env:ProgramFiles 'Windows Kits\10\Lib'))) {
    if (-not (Test-Path $root)) { continue }
    $ver = Get-ChildItem $root -Directory | Sort-Object Name -Descending |
        Where-Object { Test-Path (Join-Path $root "$($_.Name)\um\$archLib") } | Select-Object -First 1
    if ($ver) { $sdkLibRoot = $root; $sdkVersion = $ver.Name; break }
}
if (-not $sdkVersion) { Fail "未找到含 $archLib 库的 Windows SDK" }
Ok "Windows SDK: $sdkVersion"

# 链接器/编译器搜索路径兜底: rustc 调 link.exe 时不带 vcvars 环境,
# LIB 缺失时 LNK1104(msvcrt.lib 找不到), cc 编 C 时 INCLUDE 缺失也会失败
if (-not $env:LIB) {
    $env:LIB = @(
        $msvcLibDir
        (Join-Path $sdkLibRoot "$sdkVersion\ucrt\$archLib")
        (Join-Path $sdkLibRoot "$sdkVersion\um\$archLib")
    ) -join ';'
}
$msvcInclude = Join-Path $msvcToolchain 'include'
if (-not $env:INCLUDE) {
    $incDirs = @()
    if (Test-Path $msvcInclude) { $incDirs += $msvcInclude }
    foreach ($root in @((Join-Path $programFilesX86 'Windows Kits\10\Include'), (Join-Path $env:ProgramFiles 'Windows Kits\10\Include'))) {
        $incRoot = Join-Path $root $sdkVersion
        if (Test-Path (Join-Path $incRoot 'um')) {
            $incDirs += @((Join-Path $incRoot 'ucrt'), (Join-Path $incRoot 'um'), (Join-Path $incRoot 'shared'))
            break
        }
    }
    if ($incDirs.Count -gt 0) { $env:INCLUDE = ($incDirs -join ';') }
}

if ($Arch -eq 'arm64') {
    if (-not (Test-Cmd clang)) {
        Fail 'ARM64 构建需要 clang: 安装 VS 组件 "C++ Clang Compiler for Windows" 并把 Llvm\x64\bin 加入 PATH(见 CONTRIBUTING.md)'
    }
    Ok "clang $( @(& clang --version)[0] )"
}

$wv2 = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
if ($wv2) { Ok "WebView2 Runtime $($wv2.pv) (运行应用需要)" } else {
    Warn '未检测到 WebView2 Runtime(不影响编译, 运行应用需要, 见 README 故障排查)'
}

if ($CheckOnly) {
    Write-Host "`n环境检查通过, 未执行编译(-CheckOnly)。" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- 依赖准备
Write-Host "`n==== 依赖准备 ====" -ForegroundColor Cyan
if ($SkipDeps) {
    Warn '已跳过依赖准备(-SkipDeps)'
} else {
    Invoke-Checked '初始化 git 子模块' 'git' @('submodule', 'update', '--init', '--recursive')

    # pnpm 默认把依赖 store 建在项目所在盘的根目录(如 D:\.pnpm-store), 该位置无写权限时
    # 会直接 EPERM 崩溃(闪退的元凶之一)。注意 pnpm 11 不认 npm_config_store_dir 环境变量,
    # 备用路径必须通过 --store-dir 参数传入(项目内, 同盘仍可硬链接)。
    # 慢网络(国内直连 npmjs 常见)下默认 60s 单请求超时易中断, 放宽到 5 分钟并增加重试
    $installArgs = @('install', '--fetch-timeout', '300000', '--fetch-retries', '5')
    $defaultStore = Join-Path (Split-Path $PSScriptRoot -Qualifier) '.pnpm-store'
    try { New-Item -ItemType Directory -Path $defaultStore -Force -ErrorAction Stop | Out-Null }
    catch {
        $fallbackStore = Join-Path $PSScriptRoot '.pnpm-store'
        $installArgs += @('--store-dir', $fallbackStore)
        Warn "无法创建默认 pnpm store($defaultStore), 已改用: $fallbackStore"
    }
    Invoke-Checked '安装 JS 依赖' 'pnpm' $installArgs
    Invoke-Checked '复制前端 vendor 资源' 'pnpm' @('--filter', '@readest/readest-app', 'setup-vendors')
}

# ---------------------------------------------------------------- 编译发布
$buildStart = Get-Date
# Next.js 构建期内联进客户端代码: hasUpdater=false, 设置页"更新"分组消失, 启动不再检查更新。
# 本地自编译无 .sig 签名文件, 更新包安装必然失败, 故无条件禁用。
$env:NEXT_PUBLIC_DISABLE_UPDATER = 'true'
Write-Host "`n==== 编译 NSIS 安装包 ($Arch) ====" -ForegroundColor Cyan
Invoke-Checked "tauri build --target $rustTarget" 'pnpm' @('tauri', 'build', '--target', $rustTarget, '--bundles', 'nsis')

$nsisDir = Join-Path $PSScriptRoot "target\$rustTarget\release\bundle\nsis"
$portableName = $null

if ($Portable) {
    Write-Host "`n==== 编译便携版 ($Arch) ====" -ForegroundColor Cyan
    # 便携版与安装包前端产物不同(NEXT_PUBLIC_PORTABLE_APP), 需按 release.yml 再跑一次完整构建
    $env:NEXT_PUBLIC_PORTABLE_APP = 'true'
    Invoke-Checked "tauri build --target $rustTarget (便携版)" 'pnpm' @('tauri', 'build', '--target', $rustTarget, '--bundles', 'nsis')
    Remove-Item Env:NEXT_PUBLIC_PORTABLE_APP -ErrorAction SilentlyContinue

    $appVersion = (Get-Content 'apps\readest-app\package.json' -Raw | ConvertFrom-Json).version
    $portableExe = Join-Path $PSScriptRoot "target\$rustTarget\release\readest.exe"
    if (-not (Test-Path $portableExe)) { Fail "未找到便携版可执行文件: $portableExe" }
    $portableName = "Readest_${appVersion}_$Arch-portable.exe"
    Copy-Item $portableExe $portableName -Force
    Write-Host "  便携版已输出: $portableName"

    if ($env:TAURI_SIGNING_PRIVATE_KEY) {
        Invoke-Checked '签名便携版' 'pnpm' @('tauri', 'signer', 'sign', $portableName)
    } else {
        Warn '未设置 TAURI_SIGNING_PRIVATE_KEY, 跳过便携版签名(本地构建可忽略)'
    }
}

# ---------------------------------------------------------------- 汇总
$elapsed = (Get-Date) - $buildStart
Write-Host ("`n==== 构建完成(耗时 {0:N0} 秒) ====" -f $elapsed.TotalSeconds) -ForegroundColor Green
$releaseExe = Join-Path $PSScriptRoot "target\$rustTarget\release\readest.exe"
$artifacts = @(Get-ChildItem $nsisDir -Filter '*.exe' -ErrorAction SilentlyContinue)
if ($portableName) {
    $artifacts += Get-Item $portableName -ErrorAction SilentlyContinue
} elseif (Test-Path $releaseExe) {
    # 非 -Portable 模式也提示裸 exe(免安装直跑, 注意它不带便携版标志)
    $artifacts += Get-Item $releaseExe
}
foreach ($a in $artifacts) {
    Write-Host ("  产物: {0}  ({1:N1} MB)" -f $a.FullName, ($a.Length / 1MB))
}
if ($artifacts.Count -eq 0) { Fail "在 $nsisDir 未找到任何安装包" }
exit 0
