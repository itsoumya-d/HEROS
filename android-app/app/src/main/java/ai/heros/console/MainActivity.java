// SPDX-License-Identifier: MIT
package ai.heros.console;

import android.app.Activity;
import android.os.Bundle;
import android.webkit.WebView;

/**
 * HEROS Console — Android shell.
 *
 * Dependency-free (no AndroidX/Compose) so the APK builds reliably in CI with
 * just the Android SDK. This Activity renders a local status page describing the
 * mobile architecture; it is the app shell for the Zero-as-WASM-in-app design in
 * docs/aosp-zero-integration.md.
 *
 * Mobile architecture note: Android apps cannot shell out to the bash MCP
 * bridges (no bash on stock Android). The production path is to embed the HEROS
 * compute kernels as a Zero wasm32-wasi module loaded by a WASM runtime
 * (WasmEdge/wasm3) and keep all platform I/O in the Kotlin/Java host — the same
 * Zero-core / host-bridge split HEROS uses everywhere. The cross-compiled
 * android/arm64 console binary (see app/) is the interim path that runs under
 * Termux, which does provide bash + jq.
 */
public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WebView web = new WebView(this);
        web.loadDataWithBaseURL(null, STATUS_HTML, "text/html", "utf-8", null);
        setContentView(web);
    }

    private static final String STATUS_HTML =
        "<!DOCTYPE html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
        + "<style>body{font-family:sans-serif;background:#0d1117;color:#e6edf3;margin:0;padding:20px}"
        + "h1{font-size:20px}.pill{display:inline-block;background:#161b22;border:1px solid #30363d;"
        + "border-radius:6px;padding:6px 10px;margin:4px 4px 0 0;font-size:13px}"
        + ".safe{color:#3fb950}.muted{color:#8b949e;font-size:13px;line-height:1.6}</style></head><body>"
        + "<h1>⬡ HEROS Console</h1>"
        + "<p class='muted'>Agent operations stack — mobile shell.</p>"
        + "<div><span class='pill'>guardian</span><span class='pill'>evolve</span>"
        + "<span class='pill'>audit</span><span class='pill'>vault</span></div>"
        + "<p class='muted'>This shell follows the Zero-as-WASM-in-app design "
        + "(docs/aosp-zero-integration.md): HEROS compute kernels run as a Zero "
        + "wasm32-wasi module, with all platform I/O held by the Android host — "
        + "the same Zero-core / host-bridge split used across the stack. Every "
        + "behaviour-changing operation stays gated (<span class='safe'>approval nonce</span>) "
        + "and chain-hash logged.</p>"
        + "</body></html>";
}
