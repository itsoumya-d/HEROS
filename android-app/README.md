# HEROS Console — Android app (packaged-APK track)

A minimal, **dependency-free** Android app (plain Java + a `WebView`, no
AndroidX/Compose) that is the app shell for the **Zero-as-WASM-in-app** design in
[`docs/aosp-zero-integration.md`](../docs/aosp-zero-integration.md).

## Why this is separate from `app/`

`app/` (the Go console) cross-compiles to an `android/arm64` **binary** that runs
under Termux (which provides `bash` + `jq` for the MCP bridges). That's the
interim Android path and it works today.

A packaged **Play Store APK** is a different architecture, because stock Android
has no shell to run the bash bridges. The production design (per the AOSP doc) is
to embed the HEROS **compute kernels** as a Zero `wasm32-wasi` module loaded by a
WASM runtime (WasmEdge/wasm3), with all platform I/O held by the Java/Kotlin host
— the same Zero-core / host-bridge split HEROS uses everywhere. This module is
the **app shell** for that design.

## Build

Requires the Android SDK (Gradle + the Android Gradle Plugin resolve from Google's
Maven). This is **built in CI** (the `android-apk` job), not in the HEROS dev
container — that container blocks Google's Maven (`dl.google.com` → 403) and has
no Android SDK, so the APK cannot be compiled there. The Gradle wrapper, build
scripts, manifest, and sources are all present and conventional.

```bash
cd android-app
./gradlew :app:assembleDebug        # → app/build/outputs/apk/debug/app-debug.apk
```

- AGP 8.6.0, Gradle 8.14.3 (wrapper), `compileSdk` 34, `minSdk` 24, JDK 17.
- No third-party dependencies → fast, low-breakage CI build.

## Status

| Item | Status |
|---|---|
| Gradle project + wrapper + manifest + sources | ✅ committed |
| APK build | ✅ in CI (`android-apk` job, Android SDK runner) — not buildable in the dev container |
| WASM-in-app integration (Zero kernels) | ▢ next: bundle `evolve` kernels as `wasm32-wasi`, load via WasmEdge/wasm3 per the AOSP doc |
