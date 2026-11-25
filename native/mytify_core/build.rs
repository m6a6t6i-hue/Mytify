use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=../../assets/mytify.ico");
    println!("cargo:rerun-if-changed=app.rc");
    if env::var_os("CARGO_FEATURE_EMBED_UI").is_some() {
        println!("cargo:rerun-if-changed=../../build/web");
    }
    let target = env::var("TARGET").unwrap();
    if !target.contains("windows") { return; }
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    if target.ends_with("gnullvm") || target.ends_with("gnu") {
        let object = out.join("mytify-icon.o");
        let tool = env::var("WINDRES").unwrap_or_else(|_| "x86_64-w64-mingw32-windres".into());
        assert!(Command::new(tool).args(["app.rc", "-O", "coff", "-o"]).arg(&object).status().unwrap().success(), "Windows icon compilation failed");
        println!("cargo:rustc-link-arg-bin=mytify={}", object.display());
    } else {
        let res = out.join("mytify.res");
        assert!(Command::new("rc.exe").arg(format!("/fo{}", res.display())).arg("app.rc").status().unwrap().success(), "Windows icon compilation failed");
        println!("cargo:rustc-link-arg-bin=mytify={}", res.display());
    }
}
