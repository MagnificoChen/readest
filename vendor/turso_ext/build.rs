fn main() {
    // build.rs 编译运行在宿主机上, cfg! 判断的是宿主而非交叉编译目标。
    // 从 Windows 交叉编译 Android 时, cfg!(windows) 为真会误向 Android 链接器
    // 发出 advapi32(Windows 专有库)导致 "unable to find library -ladvapi32"。
    // 官方 CI 在 Linux 上构建 Android 故未触发; 必须用 CARGO_CFG_TARGET_OS 判断真实目标。
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        println!("cargo:rustc-link-lib=advapi32");
    }
}
