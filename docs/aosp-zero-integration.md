# Zero Language × AOSP Integration Plan

**Date**: 2026-05-23  
**Zero version**: v0.1.3 (experimental)  
**AOSP baseline**: Android 14 (API 34) / Android 15 (API 35)  
**Status**: Research + Architecture — no production use yet

---

## Executive Summary

Zero is an experimental, agent-oriented language that compiles to small, safe binaries. Integrating it into AOSP is viable but must be staged carefully. The language has a planned `android-arm64` (.so via JNI) target (see `zero-platform/compiler/MOBILE-DESIGN.md`), which is the canonical long-term path. Today (v0.1.3), the safest entry point is Zero compiled to `wasm32-wasi` and hosted inside an Android app or service via an embedded WASM runtime — bypassing the not-yet-shipped android-arm64 backend entirely.

**Core recommendation**: Treat Zero as an **agent orchestration runtime** running inside a sandboxed Android service, not as a replacement for Android's platform languages. AOSP native layers (framework, HAL, init) should remain in Java/Kotlin/C++ until Zero has proven correctness and the android-arm64 target is stable.

---

## Part 1 — Android Layer Analysis

### Layer Safety Matrix

```
Layer                        Risk    Reversibility   Recommended Phase
─────────────────────────────────────────────────────────────────────
1. Standard App (APK)        LOW     trivial          Phase 1 ← START HERE
2. Privileged System App     LOW     easy             Phase 2
3. Runtime Resource Overlay  NONE    trivial          Phase 2 (UI-only)
4. System Service (Java)     MEDIUM  moderate         Phase 3 (if justified)
5. Native Daemon (C/C++)     HIGH    hard             Phase 4 (post stable)
6. Framework (frameworks/)   VERY HIGH almost none   Never (for Zero)
7. HAL / Kernel              EXTREME none             Never
```

### Layer Details

#### Layer 1: Standard Application (SAFE — Start Here)

An ordinary APK that bundles a Zero agent as a WASM module. Zero logic runs inside the app process, sandboxed by Android's app sandbox (SELinux domain `untrusted_app`).

- **What changes**: Only app-level files — `build.gradle`, `AndroidManifest.xml`, app assets
- **Reversible**: Uninstall the APK
- **AOSP files touched**: None (no system changes)
- **Zero target**: `wasm32-wasi` (most capable non-native target today)

#### Layer 2: Privileged System App (LOW RISK)

An APK installed in `/system/priv-app/` that runs under a more trusted SELinux domain (`priv_app`). Can use protected permissions (`BIND_ACCESSIBILITY_SERVICE`, `OBSERVE_APP_USAGE`, etc.) that standard apps cannot.

- **What changes**: `device/<vendor>/<device>/device.mk`, `PRODUCT_PACKAGES`, platform signing key
- **Reversible**: Remove from `PRODUCT_PACKAGES`, rebuild image
- **AOSP files touched**: device.mk, `packages/apps/ZeroAgent/Android.bp`

#### Layer 3: Runtime Resource Overlays (RRO — ZERO RISK)

Changes Android resource values (strings, drawables, configs) without modifying framework code. Appropriate for theming or feature-flag-driven UI changes, **not** for Zero execution.

- **When appropriate**: Changing system UI strings, colors, layout configs to surface agent status
- **Not appropriate**: Cannot run code; purely declarative resource replacement

#### Layer 4: System Service (MEDIUM RISK — Phase 3)

A persistent service running in `system_server` or as a separate process, accessible via Binder/AIDL. This is how Android's `ActivityManagerService`, `NotificationManagerService`, etc. work.

- **Do NOT do this in Phase 1-2**. System server crashes bring the whole device down.
- If needed: prefer an **isolated process service** (`android:isolatedProcess="true"`) which has a separate PID and cannot crash system_server.
- **AOSP files touched**: `frameworks/base/services/`, `frameworks/base/core/res/AndroidManifest.xml`

#### Layer 5: Native Daemon (HIGH RISK — Post-Stable)

A C/C++ process started by `init.rc` that runs in its own SELinux domain. Appropriate only when WASM overhead is unacceptable and Zero's `android-arm64` .so target is stable (see MOBILE-DESIGN.md Phase A).

- Wait until Zero v0.3+ when fs and net work on arm64
- Requires new SELinux policy, `init.rc` service entry, vendor partition or system partition placement
- **AOSP files touched**: `system/core/init/`, vendor `*.rc` files, `sepolicy/`

#### Layers 6-7: Framework / HAL / Kernel (NEVER TOUCH for Zero)

- `frameworks/base/` — Any bug here can break all Android apps on device
- `art/` — Android Runtime; crash = boot loop
- `bionic/` — C library; any bug = undefined behavior across entire system
- `hardware/` interfaces — HAL bugs cause device hangs
- Kernel — irreversible damage

---

## Part 2 — Zero Deployment Modes on Android

### Current Zero Capability on ARM64 (v0.1.3)

```
Target                 mem  stdio  args  env  fs   net  proc  http
───────────────────────────────────────────────────────────────────
linux-musl-arm64       ✅   ✅     ❌    ❌   ❌   ❌   ❌    ❌
wasm32-wasi            ✅   ✅     ✅    ✅   ✅   ❌   ❌    ❌
android-arm64 (.so)    🔜 planned (MOBILE-DESIGN.md Phase A, blocked on upstream)
```

The `linux-musl-arm64` target cannot read files, environment variables, or spawn processes — nearly useless as an agent runtime. **The only viable today-path is `wasm32-wasi`**.

### Deployment Mode Comparison

| Mode | Capability | On-Device | Latency | Today? |
|------|-----------|-----------|---------|--------|
| A. WASM-in-App (wasm32-wasi + wasmer/wasm3) | Full (fs/args/env) | Yes | +5-50ms startup | **Yes** |
| B. Native .so via JNI (android-arm64) | Full (when ships) | Yes | <1ms | No (Phase A) |
| C. Server bridge (linux-musl-x64 on remote) | Full | No | network RTT | Yes (fallback) |
| D. linux-musl-arm64 binary (subprocess) | mem+stdio only | Yes | +1ms | Marginal |

**Recommendation: Mode A for Phase 1, Mode B when android-arm64 target ships.**

### Mode A: WASM-in-App (Phase 1)

**WASM Runtime recommendation**: **WasmEdge** (not Wasmer — it has known aarch64 Android issues).  
- WasmEdge: production-ready, arm64-v8a supported, ~992KB compressed library, full WASI support  
- Alternative: **wasm3** (C-based interpreter, ~100KB, no JIT, predictable performance, NDK-friendly)  
- Avoid: Wasmer (aarch64 calling convention issues on Android); Wasmtime (Tier 2 Android support)

```
Android App (Kotlin)
  │
  ├── assets/zero_agent.wasm    ← compiled from Zero .0 sources
  │
  └── JNI bridge (zero_jni.cpp)
        │
        └── WasmEdge (libwasmedge.so, ~992KB) or wasm3 (libwasm3.a, ~100KB)
              │
              └── Zero WASM module (zagent framework)
                    ├── context manager
                    ├── tool registry  
                    ├── plan executor
                    └── memory (in-module)
```

Zero WASM module interface (C-ABI exports, called via WasmEdge):

```zero
// agent.0 — compiled to wasm32-wasi: agent.wasm
// Note: WASM exports must use primitive types (i32/i64) at the boundary;
//       string passing uses WASM linear memory pointer+length convention.
pub fun agentHandle(requestPtr: i32, requestLen: i32, respPtr: i32, respMaxLen: i32) -> i32 raises { }
pub fun agentStatus() -> i32 raises { }
```

Android Kotlin + JNI bridge (WasmEdge pattern):

```kotlin
// ZeroAgentRuntime.kt
class ZeroAgentRuntime(context: Context) {
    private external fun nativeAgentHandle(wasmBytes: ByteArray, requestJson: String): String
    private external fun nativeAgentStatus(wasmBytes: ByteArray): String

    companion object {
        init { System.loadLibrary("zero_jni") }
    }

    private val wasmBytes: ByteArray by lazy {
        context.assets.open("zero_agent.wasm").readBytes()
    }

    fun handle(requestJson: String): String = nativeAgentHandle(wasmBytes, requestJson)
    fun status(): String = nativeAgentStatus(wasmBytes)
}
```

```cpp
// zero_jni.cpp — calls WasmEdge C API
#include <wasmedge/wasmedge.h>
#include <jni.h>

extern "C" JNIEXPORT jstring JNICALL
Java_ai_zerolang_agent_ZeroAgentRuntime_nativeAgentHandle(
        JNIEnv* env, jobject, jbyteArray wasmBytes, jstring requestJson) {

    WasmEdge_ConfigureContext* conf = WasmEdge_ConfigureCreate();
    WasmEdge_ConfigureAddHostRegistration(conf, WasmEdge_HostRegistration_Wasi);
    WasmEdge_VMContext* vm = WasmEdge_VMCreate(conf, nullptr);

    jbyte* buf = env->GetByteArrayElements(wasmBytes, nullptr);
    jsize len = env->GetArrayLength(wasmBytes);
    const char* req = env->GetStringUTFChars(requestJson, nullptr);

    // TODO: pass req into WASM linear memory, call agentHandle, read response
    // (full implementation uses WasmEdge memory API)
    WasmEdge_String fn = WasmEdge_StringCreateByCString("agentHandle");
    WasmEdge_Value params[2] = {{.i32 = 0}, {.i32 = (int)strlen(req)}};
    WasmEdge_Value returns[1];
    WasmEdge_VMRunWasmFromBuffer(vm, (uint8_t*)buf, len, fn, params, 2, returns, 1);

    env->ReleaseByteArrayElements(wasmBytes, buf, JNI_ABORT);
    env->ReleaseStringUTFChars(requestJson, req);
    WasmEdge_VMDelete(vm);
    WasmEdge_ConfigureDelete(conf);

    return env->NewStringUTF("{\"status\":\"ok\"}"); // placeholder
}
```

**Performance characteristics** (from WasmEdge Android benchmarks):
- Cold start (module load): 50-200ms on modern ARM64 device
- VM instantiation: 20-50ms
- Warm function call overhead: 10-50µs per JNI→WASM→JNI round-trip
- With module caching: subsequent starts < 5ms
- WasmEdge JIT convergence: ~1.1-1.3x native performance for compute-heavy work
```

### Mode B: Native .so via JNI (Phase 2 — when android-arm64 ships)

Per `MOBILE-DESIGN.md`:

```bash
zero build --target android-arm64 --kind so --pic ./agent
# → .zero/out/aarch64-linux-android/libzeroagent.so

zero package aar --so-dir .zero/out/ --jni-package ai.zerolang.agent --out zeroagent.aar
```

```kotlin
class ZeroAgent {
    companion object {
        init { System.loadLibrary("zeroagent") }
        external fun init(config: String): Int
        external fun handle(request: String): String
        external fun status(): String
    }
}
```

---

## Part 3 — Architecture Diagram

```
┌─────────────────────────────── Android Device ──────────────────────────────────┐
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                        USER SPACE                                           │ │
│  │                                                                             │ │
│  │  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────────────┐   │ │
│  │  │  User App A  │   │  User App B  │   │    Zero Agent Service        │   │ │
│  │  │  (any APK)   │   │  (any APK)   │   │    (priv-app, Phase 2+)      │   │ │
│  │  └──────┬───────┘   └──────┬───────┘   │                              │   │ │
│  │         │  AIDL/Binder     │           │  ┌────────────────────────┐  │   │ │
│  │         └──────────────────┴──────────▶│  │  WASM Runtime (wasm3)  │  │   │ │
│  │                                        │  │                        │  │   │ │
│  │                                        │  │  ┌──────────────────┐  │  │   │ │
│  │  ┌─────────────────────────────────┐   │  │  │  zero_agent.wasm │  │  │   │ │
│  │  │      Android System Services   │   │  │  │                  │  │  │   │ │
│  │  │                                │   │  │  │  zagent:         │  │  │   │ │
│  │  │  NotificationManager           │◀──┤  │  │  ┌──────────┐   │  │  │   │ │
│  │  │  AccessibilityService         │   │  │  │  │  context  │   │  │  │   │ │
│  │  │  JobScheduler                  │   │  │  │  ├──────────┤   │  │  │   │ │
│  │  │  UsageStatsManager             │   │  │  │  │  tools   │   │  │  │   │ │
│  │  │  ActivityManager               │   │  │  │  ├──────────┤   │  │  │   │ │
│  │  └─────────────────────────────┘   │  │  │  │  plan/loop │   │  │  │   │ │
│  │                                        │  │  │  ├──────────┤   │  │  │   │ │
│  │  ┌─────────────────────────────────┐   │  │  │  │  memory  │   │  │  │   │ │
│  │  │   Permission / SELinux Gate    │   │  │  └──────────────┘   │  │  │   │ │
│  │  │   (user must grant at runtime)  │   │  └────────────────────┘  │   │ │
│  │  └─────────────────────────────────┘   └──────────────────────────┘   │ │
│  │                                                                             │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                        ANDROID FRAMEWORK (DO NOT MODIFY)                    │ │
│  │   frameworks/base · ART · Bionic · SELinux policy                           │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                        KERNEL (DO NOT TOUCH)                                 │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────── Build Host ─────────────────────────────────────┐
│                                                                                  │
│   zero build --target wasm32-wasi ./agent → agent.wasm                          │
│   (future) zero build --target android-arm64 --kind so → libzeroagent.so        │
│                                                                                  │
│   Bundled into APK assets/ or JNI libs/arm64-v8a/                               │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 4 — AOSP Build System Files

### Phase 1: App Layer Only (Gradle — no AOSP build changes)

```
packages/apps/ZeroAgentApp/
├── build.gradle              ← add wasm runtime dependency
├── AndroidManifest.xml       ← permissions (FOREGROUND_SERVICE, etc.)
├── CMakeLists.txt            ← if using wasm3 (C library via NDK)
├── src/
│   └── main/
│       ├── assets/
│       │   └── zero_agent.wasm  ← compiled Zero module
│       ├── cpp/
│       │   └── zero_jni.cpp     ← JNI bridge to WASM runtime
│       └── kotlin/
│           └── ZeroAgentRuntime.kt
└── zero-src/
    ├── zero.json
    └── src/
        ├── agent.0
        └── tools.0
```

### Phase 2: Privileged System App (AOSP build)

```
device/<vendor>/<device>/device.mk
  PRODUCT_PACKAGES += ZeroAgentService

packages/apps/ZeroAgentService/
├── Android.bp                ← AOSP native build rule
├── AndroidManifest.xml
└── src/...
```

**Android.bp** for a privileged system app:

```
android_app {
    name: "ZeroAgentService",
    srcs: ["src/**/*.kt"],
    resource_dirs: ["res"],
    manifest: "AndroidManifest.xml",
    platform_apis: true,         // access to @hide APIs
    privileged: true,            // installs to /system/priv-app
    certificate: "platform",     // signed with platform key
    jni_libs: ["libzero_wasm"],  // embedded WASM runtime
    required: ["libzero_wasm"],
    sdk_version: "",             // blank = platform SDK
}

cc_prebuilt_library_shared {
    name: "libzero_wasm",
    srcs: ["libs/arm64-v8a/libwasm3.so"],
    target: {
        android_arm64: { enabled: true },
    },
}
```

**AndroidManifest.xml** for privileged service:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="ai.zerolang.agent"
    android:sharedUserId="android.uid.system">

    <uses-permission android:name="android.permission.BIND_ACCESSIBILITY_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.OBSERVE_APP_USAGE" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />

    <application android:persistent="false">
        <service
            android:name=".ZeroAgentService"
            android:permission="ai.zerolang.BIND_AGENT"
            android:exported="true"
            android:isolatedProcess="false">
            <intent-filter>
                <action android:name="ai.zerolang.agent.BIND" />
            </intent-filter>
        </service>
    </application>
</manifest>
```

### Phase 2: AIDL Interface

```
packages/apps/ZeroAgentService/
└── aidl/
    └── ai/zerolang/agent/
        └── IZeroAgent.aidl
```

```java
// IZeroAgent.aidl
package ai.zerolang.agent;

interface IZeroAgent {
    // Returns JSON response for a given JSON request
    String handle(String requestJson);
    // Returns agent status as JSON
    String status();
    // Cancel a running task
    boolean cancel(String taskId);
}
```

### Phase 3: Feature Flags (android.aconfig)

```
packages/apps/ZeroAgentService/
└── zero_agent.aconfig
```

```
package: "ai.zerolang.agent.flags"
container: "system"

flag {
    name: "enable_zero_agent_runtime"
    namespace: "zero_agent"
    description: "Master switch for Zero agent runtime"
    bug: "b/123456789"
}

flag {
    name: "enable_context_sensing"
    namespace: "zero_agent"  
    description: "Allow agent to observe app usage and notifications"
    bug: "b/123456790"
}
```

Usage in code:

```kotlin
if (Flags.enableZeroAgentRuntime()) {
    startZeroAgentService()
}
```

---

## Part 5 — AI Agent Architecture on Android

### What Zero Agent Does on Android

Zero's `zagent` framework (already in `zero-platform/`) provides:
- **context**: What the user is doing (current app, recent actions)
- **tools**: Callable actions (send notification, launch app, query calendar)
- **plan**: Multi-step task execution
- **memory**: Persistent state across agent invocations
- **eval**: Task outcome verification

On Android, these map to:

| zagent concept | Android mechanism |
|---------------|-------------------|
| context | AccessibilityService, UsageStatsManager |
| tools.notify | NotificationManager |
| tools.launch | ActivityManager.startActivity() |
| tools.calendar | CalendarContract ContentProvider |
| tools.sms | SmsManager |
| memory | Room database / SharedPreferences |
| eval | LogCat + custom metrics |

### Permission Gating (Critical)

Every agent action must be permission-gated at two levels:

**Level 1: Android runtime permissions** (system enforcement)
```
OBSERVE_APP_USAGE → reading which apps are active
BIND_ACCESSIBILITY → reading screen content  
RECEIVE_BOOT_COMPLETED → auto-start after reboot
FOREGROUND_SERVICE → persistent background work
POST_NOTIFICATIONS → sending notifications (Android 13+)
```

**Level 2: Zero agent capability tokens** (application enforcement)
```zero
shape AgentCapabilities {
    canReadUsage: Bool,
    canSendNotif: Bool,
    canLaunchApps: Bool,
    canReadCalendar: Bool,
    canSendSms: Bool,
}
```

The Zero agent receives only the capability subset the user explicitly granted. A capability never granted cannot be used even if the Android permission is held.

### Rollback and Safety

Zero WASM modules are loaded from app assets. Rollback = rollback the APK. Steps:

1. Agent version pinned in `zero.json` with semantic version
2. New agent version deployed via Play Store / sideload as new APK
3. Old APK restored if new agent misbehaves (standard Android rollback)
4. Agent task log written to SQLite via Room — reviewable by user at any time
5. All agent actions are **append-only logged** before execution
6. A "dry-run mode" flag in AgentCapabilities prevents any write-actions during testing

### Logging Architecture

```
Agent action intent → LogEntry(action, timestamp, dry_run)
                   ↓
              Room DB (local, private to app)
                   ↓
    User can review in "Agent History" UI
                   ↓
    Optional: export to adb logcat (debug builds only)
```

---

## Part 6 — Risks and Constraints

### Zero Language Risks (treat as unsafe until proven otherwise)

| Risk | Severity | Mitigation |
|------|---------|-----------|
| linux-musl-arm64 has no fs/net/proc | HIGH | Use wasm32-wasi instead |
| android-arm64 target not yet shipped | HIGH | WASM bridge in Phase 1 |
| No stdin support (V34 gap) | MEDIUM | Design IPC as function calls, not stdin pipes |
| CGEN004: non-primitive params blocked in direct backend | MEDIUM | WASM target not affected |
| Language is unstable (breaking changes expected) | MEDIUM | Pin Zero version in zero.json |
| No language-level async | LOW | Use Android's coroutines at the host layer |
| UTF-8 BOM issue in Windows builds | LOW | Use Zero Write tool or utf8NoBOM encoding |

### AOSP Integration Risks

| Risk | Severity | Mitigation |
|------|---------|-----------|
| Privileged app crashes → ANR visible to user | MEDIUM | `isolatedProcess="true"` for service |
| SELinux policy denials | MEDIUM | Start with standard `priv_app` domain, no custom policy |
| Boot image size increase | LOW | Keep WASM runtime .so < 2MB |
| Play Store policy (JIT/dynamic code) | LOW | WasmEdge interpreted mode or wasm3 (AOT-free) for Play Store; JIT only for sideloaded builds |
| WasmEdge CVEs (sandbox escape via JIT) | LOW | Use interpreter mode until JIT CVEs assessed; monitor wasmedge.org/security |
| Permission whitelist XML missing | HIGH | Android 9+ won't boot if privapp-permissions XML absent; always include it |
| Platform key required for priv-app signing | MEDIUM | Use debug key in Phase 1, get release key before Phase 2 |

### What Not to Do

- Do NOT add Zero binaries to the boot classpath (`PRODUCT_BOOT_JARS`)
- Do NOT modify `system/core/init/` for Phase 1-2
- Do NOT add Zero to `frameworks/base/` in any phase
- Do NOT use `android:sharedUserId="android.uid.system"` in Phase 1 (only Phase 2+ if truly needed)
- Do NOT attempt net operations from Zero WASM on Android (wasm32-wasi has no net)
- Do NOT use `std.proc.spawn` from within Android WASM context (proc not available in wasm32-wasi)

---

## Part 7 — Phased Implementation Roadmap

### Phase 1: WASM Proof-of-Concept (Weeks 1-4)

**Goal**: Zero agent logic running inside a standard Android APK on AOSP emulator.

**Deliverables**:
- `packages/apps/ZeroAgentApp/` — Standard APK
- Zero source: `agent.0` using `zagent` framework, compiled to `wasm32-wasi`
- Embedded WASM runtime: wasm3 (C library, ~100KB, NDK-compatible)
- JNI bridge: `zero_jni.cpp` → Kotlin `ZeroAgentRuntime`
- Simple tool: "send notification with message X"
- Unit tests: agent handles JSON request, returns JSON response

**Files changing**:
```
packages/apps/ZeroAgentApp/build.gradle                       [NDK CMake, abiFilters: arm64-v8a]
packages/apps/ZeroAgentApp/AndroidManifest.xml
packages/apps/ZeroAgentApp/CMakeLists.txt                     [link wasmedge or wasm3.a]
packages/apps/ZeroAgentApp/src/main/assets/agent.wasm         [generated: zero build --target wasm32-wasi]
packages/apps/ZeroAgentApp/src/main/jniLibs/arm64-v8a/
    libwasmedge.so                                            [WasmEdge prebuilt; ~992KB compressed]
packages/apps/ZeroAgentApp/src/main/cpp/zero_jni.cpp          [WasmEdge C API → JNI bridge]
packages/apps/ZeroAgentApp/src/main/kotlin/ZeroAgentRuntime.kt
packages/apps/ZeroAgentApp/zero-src/zero.json
packages/apps/ZeroAgentApp/zero-src/src/agent.0
packages/apps/ZeroAgentApp/zero-src/src/tools.0
```

**WasmEdge download**: `https://github.com/WasmEdge/WasmEdge/releases` — `WasmEdge-*-android_aarch64.tar.gz`  
**WasmEdge docs**: `wasmedge.org/docs/category/build-and-run-wasmedge-on-android/`

**No AOSP system files change in Phase 1.**

**Test before building image**:
- Run on AOSP emulator (`sdk_gphone64_arm64` target)
- `adb install ZeroAgentApp.apk`
- Verify agent.wasm loads without crash
- Verify JNI bridge calls succeed
- Verify notification tool fires correctly
- Verify SELinux denials = 0 (`adb logcat | grep avc:`)
- Verify memory usage < 50MB delta after agent load

### Phase 2: Privileged Background Service (Weeks 5-10)

**Goal**: Zero agent runs as a persistent background service, accessible via Binder to other apps.

**Prerequisites from Phase 1**: Stable WASM bridge, no SELinux issues.

**Deliverables**:
- Promote to privileged system app: `packages/apps/ZeroAgentService/`
- AIDL interface: `IZeroAgent.aidl`
- Feature flag: `zero_agent.aconfig`
- Context sensing: AccessibilityService listener → agent context
- User permission dialog: explain what agent accesses before enabling
- Agent history UI: Room DB + RecyclerView of past agent actions

**Files changing**:
```
device/<vendor>/<device>/device.mk            [add PRODUCT_PACKAGES]
packages/apps/ZeroAgentService/Android.bp
packages/apps/ZeroAgentService/AndroidManifest.xml
packages/apps/ZeroAgentService/aidl/...
packages/apps/ZeroAgentService/zero_agent.aconfig
packages/apps/ZeroAgentService/src/...
```

**AOSP files changing** (first real system-level change):
```
device/<vendor>/<device>/device.mk
etc/permissions/privapp-permissions-zero-agent.xml   ← REQUIRED for Android 9+
```

**Permission Whitelisting** (mandatory for Android 9+, device won't boot without it):

```xml
<!-- etc/permissions/privapp-permissions-zero-agent.xml -->
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="ai.zerolang.agent">
        <permission name="android.permission.OBSERVE_APP_USAGE" />
        <permission name="android.permission.BIND_ACCESSIBILITY_SERVICE" />
        <permission name="android.permission.RECEIVE_BOOT_COMPLETED" />
    </privapp-permissions>
</permissions>
```

In `Android.bp`, reference via `required: ["privapp-permissions-zero-agent"]`.

**Test before building image**:
- CTS (Compatibility Test Suite): run `cts-tradefed run cts -m CtsPermissionTestCases`
- SELinux audit log clean: `adb logcat -b events | grep selinux`
- Feature flag off by default: agent service does NOT start unless flag enabled
- Accessibility service opt-in: user must explicitly enable in Settings → Accessibility
- Binder IPC test: client app can connect and call `handle()` without crash
- OOM test: WASM module unloads cleanly when Android kills service for memory

### Phase 3: Context-Aware Automation (Weeks 11-20)

**Goal**: Agent reacts to user context (current app, screen content, calendar events) and executes multi-step plans.

**Prerequisites from Phase 2**: Stable service, user opt-in flow, clean SELinux policy.

**Deliverables**:
- Context providers: UsageStatsManager, AccessibilityEvent stream → Zero WASM context object
- Tool expansion: calendar, SMS, contacts, settings toggle
- Plan execution: zagent multi-step planning within Zero WASM
- Rollback: undo-last-action tool
- Agent evaluation harness (extending zero-platform/eval/)

**Files changing** (additions to Phase 2 service):
```
packages/apps/ZeroAgentService/src/.../ContextProvider.kt
packages/apps/ZeroAgentService/src/.../ToolRegistry.kt
packages/apps/ZeroAgentService/zero-src/src/context.0
packages/apps/ZeroAgentService/zero-src/src/planner.0
packages/apps/ZeroAgentService/zero-src/src/tools/*.0
```

### Phase 4: Native .so Integration (When android-arm64 Ships)

**Goal**: Replace WASM bridge with native Zero .so for lower overhead.

**Prerequisites**: Zero `android-arm64` backend (MOBILE-DESIGN.md Phase A) shipped and validated.

**Deliverables**:
- Build: `zero build --target android-arm64 --kind so ./agent`
- Package: `zero package aar` → `zeroagent.aar`
- Replace WASM runtime + agent.wasm with JNI-direct `libzeroagent.so`
- Benchmark: compare latency WASM vs native .so
- Keep WASM as fallback for devices where .so fails

**Files changing**:
```
packages/apps/ZeroAgentService/Android.bp  [add jni_libs entry]
packages/apps/ZeroAgentService/libs/arm64-v8a/libzeroagent.so  [built by zero build]
packages/apps/ZeroAgentService/src/.../ZeroNativeRuntime.kt
```

---

## Part 8 — Minimum Viable Proof of Concept

The MVP demonstrates that Zero can run agent logic on Android without breaking anything.

### MVP Scope

- Standard APK (no system changes)
- Zero `wasm32-wasi` module that:
  - Accepts a JSON string as input
  - Returns a JSON string as output
  - Implements one tool: `{ "tool": "notify", "title": "Hello", "body": "from Zero" }`
- Android JNI bridge loads module from assets
- Kotlin Activity calls bridge, shows result in TextView
- NotificationManager fires the notification if tool = "notify"

### MVP Zero Source

```zero
// agent.0
pub fun agentHandle(requestJson: String) -> String raises { } {
    // Parse the tool name from JSON (simple substring match for MVP)
    let isNotify = std.mem.eql(requestJson, "notify")  // simplified
    if isNotify {
        return "{\"status\":\"ok\",\"action\":\"notify\"}"
    }
    return "{\"status\":\"error\",\"message\":\"unknown tool\"}"
}
```

### MVP Build Command

```bash
zero build --target wasm32-wasi --emit wasm ./agent
cp .zero/out/wasm32-wasi/agent.wasm android-app/src/main/assets/
```

### MVP Success Criteria

- [ ] `agent.wasm` loads on arm64 Android device/emulator without crash
- [ ] JNI bridge `agentHandle("{...}")` returns valid JSON
- [ ] SELinux audit log shows zero denials for WASM execution
- [ ] Peak memory delta < 20MB
- [ ] Round-trip latency (Kotlin → JNI → WASM → response) < 100ms
- [ ] App uninstall fully removes all Zero artifacts

---

## Part 9 — Files Most Likely to Change First

### Phase 1 (no system files)

```
packages/apps/ZeroAgentApp/
  ├── AndroidManifest.xml          [POST_NOTIFICATIONS, FOREGROUND_SERVICE]
  ├── build.gradle                 [NDK CMake config]
  ├── CMakeLists.txt               [link wasm3.a]
  ├── src/main/assets/agent.wasm   [compiled Zero]
  ├── src/main/cpp/zero_jni.cpp    [JNI ↔ wasm3]
  └── src/main/kotlin/ZeroRuntime.kt

zero-src/
  ├── zero.json
  ├── src/agent.0
  └── src/tools.0
```

### Phase 2 (first system file)

```
device/<vendor>/<device>/device.mk           [PRODUCT_PACKAGES += ZeroAgentService]
packages/apps/ZeroAgentService/Android.bp    [privileged: true, certificate: "platform"]
packages/apps/ZeroAgentService/aidl/ai/zerolang/agent/IZeroAgent.aidl
packages/apps/ZeroAgentService/zero_agent.aconfig
```

---

## Part 10 — Pre-Image Safety Checklist

Before building a custom AOSP image with Zero components:

### Code Quality
- [ ] Zero source passes `zero check --json` with no errors
- [ ] WASM module verified with `wasm-validate agent.wasm`
- [ ] JNI bridge has no dangling pointers (valgrind on x86_64 emulator)
- [ ] No `System.loadLibrary` called on non-existent library
- [ ] All `external fun` declarations match JNI C exports exactly

### Security
- [ ] SELinux policy change reviewed: `audit2allow` output is minimal
- [ ] `adb shell dmesg | grep avc:` clean after install + basic operation
- [ ] No `android:debuggable="true"` in release manifest
- [ ] No world-readable files created by Zero module
- [ ] WASM module has content-hash in `zero.json` version pinning

### Android Compatibility
- [ ] CTS passes: `cts-tradefed run cts -m CtsPermissionTestCases`
- [ ] CTS passes: `cts-tradefed run cts -m CtsSecurityTestCases`
- [ ] App installs and uninstalls without leftover data in `/data/`
- [ ] `adb shell am force-stop ai.zerolang.agent` terminates cleanly
- [ ] Memory profiler shows no WASM heap leaks after 100 agent invocations

### Reversibility
- [ ] Feature flag defaults to `false` (agent disabled by default)
- [ ] Removing `ZeroAgentService` from `PRODUCT_PACKAGES` in device.mk produces a clean build
- [ ] APK can be rolled back via standard Android OTA rollback mechanism

### Performance
- [ ] WASM cold start < 500ms on low-end device (Cortex-A53)
- [ ] WASM warm invocation < 50ms
- [ ] Agent service does not hold CPU wakelock when idle
- [ ] `dumpsys battery` shows no unexpected wakelocks from `ai.zerolang.agent`

---

## Part 11 — Zero as Agent Runtime vs OS Language

Zero should **not** be used as an OS-level language in Android (Phase 1-3). The rationale:

| Concern | Detail |
|---------|--------|
| Stability | Zero v0.1.3 is explicitly experimental with breaking changes expected |
| android-arm64 backend | Not yet shipped; unknown correctness against ART/Bionic |
| No async | Android framework is deeply async (Looper/Handler/Coroutines); Zero has no async |
| No JNI codegen | `zero package kotlin-bridge` not yet implemented |
| Safety unknown | Zero memory model unproven against Android's strict SELinux + seccomp-bpf |

Zero's correct role on Android today: **an isolated compute substrate** for AI agent logic, running in a WASM sandbox with well-defined inputs (JSON) and outputs (JSON), orchestrated by an Android service that holds all platform integration responsibilities.

When Zero matures (v0.3+, android-arm64 stable, mobile stdlib shipped), it can expand into:
- Replacing individual computation-heavy JNI libraries
- Providing a type-safe agent protocol layer
- Acting as a language for writing Android Automation scripts (with std.mobile.*)

---

## Appendix: Key Android APIs for Agent Integration

```kotlin
// Context sensing
val usageStatsManager = context.getSystemService(UsageStatsManager::class.java)
val recentApps = usageStatsManager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, ...)

// Notification tool
val notificationManager = context.getSystemService(NotificationManager::class.java)
notificationManager.notify(id, NotificationCompat.Builder(context, channelId)
    .setContentTitle(title).setContentText(body).build())

// App launch tool
context.startActivity(Intent(Intent.ACTION_MAIN)
    .setPackage(packageName)
    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

// Calendar read tool
val cursor = context.contentResolver.query(
    CalendarContract.Events.CONTENT_URI,
    arrayOf(CalendarContract.Events.TITLE, CalendarContract.Events.DTSTART),
    null, null, null)
```

---

## Summary: Recommended Architecture

```
Phase 1  Standard APK + WASM runtime (wasm3/NDK) + Zero wasm32-wasi agent
              ↓ proven stable on emulator
Phase 2  Privileged service + AIDL + Feature flags + User permission UI
              ↓ proven stable on real device, CTS passing
Phase 3  Full context awareness + multi-step planning + tool expansion
              ↓ Zero android-arm64 backend ships
Phase 4  Native .so via JNI, drop WASM overhead
              ↓ Zero mobile stdlib ships
Phase 5  std.mobile.* APIs, Zero writes Android automation natively
```

Zero is safest when it runs **inside** the Android app sandbox (WASM), communicates via **structured JSON**, and touches platform APIs **only through Android's own service layer**. The AOSP framework itself should remain untouched until Phase 5 at the earliest.
