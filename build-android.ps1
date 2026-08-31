#Requires -Version 5.1
<#
.SYNOPSIS
  Readest Android 一键编译脚本(Windows)。

.DESCRIPTION
  与官方 .github/workflows/release.yml 的 Android 任务保持一致:
  1. 环境检查: Node.js / pnpm / Rust + Android 目标 / JDK 17 / Android SDK / NDK,
     任一不满足则给出修复方法并以非零码退出。
  2. 依赖准备: git submodule -> pnpm install -> setup-vendors。
  3. gen/android 工程重建: rm -> tauri android init -> tauri icon -> git checkout
     (仓库只提交了 app/ 自定义部分, 其余模板由 init 生成)。
  4. 签名: 首次运行自动生成 .android-keystore\readest-release.jks(口令 readest),
     每次 init 后重写 gen\android\keystore.properties 指向它。
  5. 编译: pnpm tauri android build, APK 复制到仓库根目录。

  JDK 优先级: JAVA_HOME 环境变量 -> 项目内 .jdk\jdk-17*(build 脚本装的绿色版)。
  SDK 优先级: ANDROID_HOME -> %LOCALAPPDATA%\Android\Sdk。
  NDK 优先级: NDK_HOME -> SDK\ndk 下最新版本。

  产物位置:
    APK: 仓库根目录 Readest_<version>_universal.apk (或 Readest_<version>_aarch64.apk)

.EXAMPLE
  .\build-android.ps1                 # universal APK(含全部 4 种 abi, 任何手机可装)
  .\build-android.ps1 -Target aarch64 # 仅 arm64 APK(现代手机, 体积更小)
  .\build-android.ps1 -CheckOnly      # 仅检查环境, 不编译
  .\build-android.ps1 -SkipDeps       # 跳过依赖准备(重复编译提速)
  .\build-android.ps1 -DisableUpdater # 编译期禁用自动更新(设置页不显示"更新"分组)

.NOTES
  首次构建需下载 gradle 发行版与全部 maven 依赖, 且 4 个 Android 目标的 Rust
  crate 需全量编译(universal 模式), 总时长可能超过 30 分钟, 属正常现象。
  安装到手机: 数据线连接后 `adb install -r <apk>`, 或把 APK 传到手机直接安装。
  iOS 无法在 Windows 上构建(需 macOS + Xcode)。
  执行策略受限时运行:
    powershell -ExecutionPolicy Bypass -File .\build-android.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('universal', 'aarch64')]
    [string]$Target = 'universal',
    [switch]$SkipDeps,
    [switch]$DisableUpdater,
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
Write-Host "`n==== Readest Android 编译环境检查 ====" -ForegroundColor Cyan

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

if (-not (Test-Cmd rustup)) { Fail '未找到 rustup, 无法校验编译目标。请通过 https://rustup.rs 安装' }
$installedTargets = @(& rustup target list --installed)
$requiredTargets = if ($Target -eq 'universal') {
    @('aarch64-linux-android', 'armv7-linux-androideabi', 'i686-linux-android', 'x86_64-linux-android')
} else {
    @('aarch64-linux-android')
}
$missingTargets = @($requiredTargets | Where-Object { $installedTargets -notcontains $_ })
if ($missingTargets.Count -gt 0) {
    Fail "缺少 Rust Android 编译目标: $($missingTargets -join ', ')。安装: rustup target add $($missingTargets -join ' ')"
}
Ok "Rust Android 目标: $($requiredTargets -join ', ')"

# JDK: JAVA_HOME -> 项目内 .jdk\jdk-17* -> 常规安装位置
$javaHome = $null
if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
    $javaHome = $env:JAVA_HOME
} else {
    $localJdk = Get-ChildItem (Join-Path $PSScriptRoot '.jdk') -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($localJdk) {
        $javaHome = $localJdk.FullName
    } else {
        foreach ($root in @('C:\Program Files\Java', 'C:\Program Files\Eclipse Adoptium', 'C:\Program Files\Zulu')) {
            $hit = Get-ChildItem $root -Directory -Filter '*-17*' -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') } | Select-Object -First 1
            if ($hit) { $javaHome = $hit.FullName; break }
        }
    }
}
if (-not $javaHome) {
    Fail '未找到 JDK 17。安装: https://adoptium.net/ (选 JDK 17), 或设置 JAVA_HOME 指向含 bin\javac.exe 的 JDK 目录'
}
$javac = Join-Path $javaHome 'bin\javac.exe'
$javacVersion = ((& $javac -version) -replace '^javac ', '')
$javacMajor = [int]($javacVersion.Split('.')[0])
if ($javacMajor -lt 17) {
    Fail "JDK 版本过低(当前 $javacVersion, 需要 17+)。$javaHome"
}
if ($javacMajor -ne 17) { Warn "CI 基准为 JDK 17, 当前 $javacVersion, 一般也可编译" }
Ok "JDK: $javacVersion ($javaHome)"

# Android SDK: ANDROID_HOME -> %LOCALAPPDATA%\Android\Sdk
$androidHome = $null
if ($env:ANDROID_HOME -and (Test-Path $env:ANDROID_HOME)) {
    $androidHome = $env:ANDROID_HOME
} else {
    $defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $defaultSdk) { $androidHome = $defaultSdk }
}
if (-not $androidHome) {
    Fail "未找到 Android SDK。安装 Android Studio(https://developer.android.com/studio)或设置 ANDROID_HOME; 默认位置 %LOCALAPPDATA%\Android\Sdk"
}
if (-not (Test-Path (Join-Path $androidHome 'platform-tools\adb.exe'))) {
    Fail "Android SDK 不完整(缺 platform-tools): $androidHome"
}
if (-not (Get-ChildItem (Join-Path $androidHome 'platforms') -Directory -ErrorAction SilentlyContinue)) {
    Fail "Android SDK 缺 platforms: $androidHome"
}
if (-not (Get-ChildItem (Join-Path $androidHome 'build-tools') -Directory -ErrorAction SilentlyContinue)) {
    Fail "Android SDK 缺 build-tools: $androidHome"
}
Ok "Android SDK: $androidHome"

# NDK: NDK_HOME -> SDK\ndk 最新
$ndkHome = $null
if ($env:NDK_HOME -and (Test-Path $env:NDK_HOME)) {
    $ndkHome = $env:NDK_HOME
} else {
    $ndk = Get-ChildItem (Join-Path $androidHome 'ndk') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($ndk) { $ndkHome = $ndk.FullName }
}
if (-not $ndkHome) {
    Fail "未找到 Android NDK(SDK\ndk 下无安装)。安装: sdkmanager `"ndk;28.2.13676358`" 或在 Android Studio SDK Manager 里装 NDK"
}
Ok "Android NDK: $ndkHome"
if ((Split-Path $ndkHome -Leaf) -ne '28.2.13676358') {
    Warn "CI 钉定 NDK 28.2.13676358, 本机为 $(Split-Path $ndkHome -Leaf); 若构建报 NDK 版本问题再对齐"
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

    # pnpm 默认 store 建在盘根目录, 无写权限时 EPERM 崩溃; 慢网络下放宽超时并重试
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

# ---------------------------------------------------------------- 环境变量
$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $androidHome
$env:NDK_HOME = $ndkHome
# tauri android init 会把各 tauri 插件 android 工程的路径写进 tauri.settings.gradle
# (指向 CARGO_HOME 的 registry); 固定为项目内 .cargo-home(已缓存全部 crate),
# 保证每次 init 后路径有效, 也免去手工设置环境变量。
$projCargoHome = Join-Path $PSScriptRoot '.cargo-home'
if (Test-Path $projCargoHome) { $env:CARGO_HOME = $projCargoHome }
if ($DisableUpdater) {
    # Next.js 构建期内联进客户端代码: hasUpdater=false, 设置页"更新"分组消失, 启动不再检查更新
    $env:NEXT_PUBLIC_DISABLE_UPDATER = 'true'
    Write-Host "`n[开关] 编译期禁用自动更新(NEXT_PUBLIC_DISABLE_UPDATER)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- gen/android 工程重建(官方 CI 流程)
$appDir = Join-Path $PSScriptRoot 'apps\readest-app'
$genAndroid = Join-Path $appDir 'src-tauri\gen\android'

$buildStart = Get-Date
Write-Host "`n==== 重建 gen/android 工程 ====" -ForegroundColor Cyan
if (Test-Path $genAndroid) { Remove-Item $genAndroid -Recurse -Force }
Push-Location $appDir
try {
    Invoke-Checked 'tauri android init' 'pnpm' @('tauri', 'android', 'init')
    Invoke-Checked '生成应用图标' 'pnpm' @('tauri', 'icon', '../../data/icons/readest-book.png')
} finally {
    Pop-Location
}
# 仓库只提交了 gen/android/app 的自定义部分, init 覆盖后从 git 恢复(CONTRIBUTING.md 流程)
Invoke-Checked '恢复 gen/android 自定义配置' 'git' @('checkout', '--', 'apps/readest-app/src-tauri/gen/android')

# ---------------------------------------------------------------- Gradle 镜像(境内网络)
# plugins.gradle.org / dl.google.org 在境内网络常发生 TLS 握手中断(buildSrc 的 kotlin-dsl
# 插件解析即卡死于此); 注入阿里云聚合镜像, 官方仓保留兜底。
# buildSrc 无 settings 文件时插件仅从 gradlePluginPortal 解析, 必须补一个 pluginManagement。
function Insert-GradleMirrors([string]$File) {
    $lines = Get-Content $File
    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in $lines) {
        if ($line -match '^(\s*)google\(\)\s*$') {
            $indent = $Matches[1]
            $out.Add($indent + 'maven("https://maven.aliyun.com/repository/google")')
            $out.Add($indent + 'maven("https://maven.aliyun.com/repository/public")')
            $inserted = $true
        }
        $out.Add($line)
    }
    if ($inserted) {
        Set-Content $File $out.ToArray() -Encoding ascii
        Ok "镜像注入: $(Split-Path $File -Leaf)"
    } else {
        Warn "未找到 google() 声明, 跳过: $(Split-Path $File -Leaf)"
    }
}

$buildSrcDir = Join-Path $genAndroid 'buildSrc'
Insert-GradleMirrors (Join-Path $genAndroid 'build.gradle.kts')
Insert-GradleMirrors (Join-Path $buildSrcDir 'build.gradle.kts')
@'
// Injected by build-android.ps1: buildSrc resolves plugins from gradlePluginPortal
// by default, which is unreliable on CN networks (TLS handshake drops). Aliyun
// mirrors first, official repositories kept as fallback.
pluginManagement {
    repositories {
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}
'@ | Set-Content (Join-Path $buildSrcDir 'settings.gradle.kts') -Encoding ascii
Ok '镜像注入: buildSrc\settings.gradle.kts(kotlin-dsl 不再直连 plugins.gradle.org)'

# ---------------------------------------------------------------- 签名
$ksDir = Join-Path $PSScriptRoot '.android-keystore'
$jks = Join-Path $ksDir 'readest-release.jks'
if (-not (Test-Path $jks)) {
    New-Item -ItemType Directory -Force $ksDir | Out-Null
    Write-Host "`n==> 生成本地签名密钥(口令 readest, 仅本地自签)" -ForegroundColor Cyan
    & (Join-Path $javaHome 'bin\keytool.exe') -genkeypair -keystore $jks -alias readest `
        -storepass readest -keypass readest -keyalg RSA -keysize 2048 -validity 36500 `
        -dname 'CN=Readest Local Build, OU=Dev, O=Readest, C=CN' | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail '生成本地签名 keystore 失败' }
    Ok '.android-keystore\readest-release.jks'
}
# keystore.properties 在 gen/android 下, init 重建目录后需每次重写(CI 同款)。
# Java properties 格式把反斜杠当转义符(\r 会变回车, \D 会吞掉反斜杠),
# 必须写正斜杠路径, 否则 storeFile 被 Properties.load() 打碎导致签名失败。
$storeFileProp = $jks -replace '\\', '/'
@("storeFile=$storeFileProp", 'keyAlias=readest', 'password=readest') |
    Set-Content (Join-Path $genAndroid 'keystore.properties') -Encoding ascii
Ok "签名配置 -> $storeFileProp"

# ---------------------------------------------------------------- 编译
Write-Host "`n==== 编译 APK ($Target) ====" -ForegroundColor Cyan
$buildArgs = @('tauri', 'android', 'build')
if ($Target -ne 'universal') { $buildArgs += @('-t', $Target) }
Push-Location $appDir
try {
    Invoke-Checked "tauri android build ($Target)" 'pnpm' $buildArgs
} finally {
    Pop-Location
}

# ---------------------------------------------------------------- 汇总
$elapsed = (Get-Date) - $buildStart
Write-Host ("`n==== 构建完成(耗时 {0:N0} 秒) ====" -f $elapsed.TotalSeconds) -ForegroundColor Green
$appVersion = (Get-Content (Join-Path $appDir 'package.json') -Raw | ConvertFrom-Json).version
$apkRoot = Join-Path $genAndroid 'app\build\outputs\apk'
$apkFiles = @(Get-ChildItem $apkRoot -Recurse -Filter '*-release.apk' -ErrorAction SilentlyContinue)
if ($apkFiles.Count -eq 0) { Fail "未找到输出 APK(在 $apkRoot 下)" }
foreach ($apk in $apkFiles) {
    $rel = $apk.FullName.Substring($apkRoot.Length).TrimStart('\')
    $flavor = ($rel -split '\\')[0]
    $outName = "Readest_${appVersion}_${flavor}.apk"
    $outPath = Join-Path $PSScriptRoot $outName
    Copy-Item $apk.FullName $outPath -Force
    Write-Host ("  产物: {0}  ({1:N1} MB)" -f $outPath, ($apk.Length / 1MB))
}
Write-Host "  安装: 数据线连接后 adb install -r <apk>, 或传到手机直接安装(自签应用需允许未知来源)" -ForegroundColor DarkGray
exit 0
