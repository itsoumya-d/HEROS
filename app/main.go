// SPDX-License-Identifier: MIT
//
// HEROS Console — a small, dependency-free cross-platform desktop app that
// drives the HEROS MCP bridges (guardian, evolve, audit, vault) from a local
// web UI. Pure Go standard library, so it cross-compiles to Linux, macOS, and
// Windows from any host (no Mac required for the macOS build).
//
// Architecture mirrors the rest of HEROS: this binary owns no risk logic — it
// is a thin client that spawns the bash MCP bridges as subprocesses, speaks
// JSON-RPC 2.0 over their stdio, and renders the JSON they return. All safety
// gating still happens in the bridges (guardian's approval nonce, evolve's
// gated self-modification, audit's chain hash).
//
// Runtime requirement: the bridges are bash + jq, so the host needs bash and
// jq on PATH (on Windows: Git Bash or WSL) until native ports exist.
package main

import (
	"bufio"
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

//go:embed ui/index.html
var uiFS embed.FS

// Allowlisted MCP servers → bridge filename. No arbitrary paths from the client.
var servers = map[string]string{
	"guardian": "guardian/mcp-bridge.sh",
	"evolve":   "evolve/mcp-bridge.sh",
	"audit":    "audit/mcp-bridge.sh",
	"vault":    "vault/mcp-bridge.sh",
}

// herosRoot is the directory containing the per-tool bridge folders.
var herosRoot string

type callRequest struct {
	Server string                 `json:"server"`
	Tool   string                 `json:"tool"`
	Args   map[string]interface{} `json:"args"`
}

func main() {
	addr := flag.String("addr", envOr("HEROS_CONSOLE_ADDR", "127.0.0.1:8765"), "listen address (localhost only)")
	root := flag.String("root", os.Getenv("HEROS_ROOT"), "path to the HEROS repo root (defaults to autodetect)")
	flag.Parse()

	herosRoot = resolveRoot(*root)
	log.Printf("HEROS Console — repo root: %s", herosRoot)

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]any{"status": "ok", "root": herosRoot}) })
	mux.HandleFunc("/api/servers", handleServers)
	mux.HandleFunc("/api/call", handleCall)

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("cannot bind %s: %v", *addr, err)
	}
	url := "http://" + ln.Addr().String() + "/"
	log.Printf("HEROS Console listening on %s", url)
	if os.Getenv("HEROS_CONSOLE_NO_OPEN") == "" {
		openBrowser(url)
	}
	srv := &http.Server{Handler: localhostOnly(mux), ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.Serve(ln))
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// resolveRoot finds the HEROS repo root: explicit flag/env, else walk up from
// the executable and the cwd looking for a directory that has guardian/.
func resolveRoot(explicit string) string {
	if explicit != "" {
		return explicit
	}
	candidates := []string{}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Dir(exe), filepath.Dir(filepath.Dir(exe)))
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, wd, filepath.Dir(wd))
	}
	for _, c := range candidates {
		if fi, err := os.Stat(filepath.Join(c, "guardian", "mcp-bridge.sh")); err == nil && !fi.IsDir() {
			return c
		}
	}
	// Last resort: cwd.
	wd, _ := os.Getwd()
	return wd
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, err := uiFS.ReadFile("ui/index.html")
	if err != nil {
		http.Error(w, "ui not embedded", 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}

func handleServers(w http.ResponseWriter, r *http.Request) {
	names := make([]string, 0, len(servers))
	for k := range servers {
		names = append(names, k)
	}
	writeJSON(w, 200, map[string]any{"servers": names})
}

func handleCall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 405, map[string]any{"error": "POST only"})
		return
	}
	var req callRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "invalid JSON body"})
		return
	}
	rel, ok := servers[req.Server]
	if !ok {
		writeJSON(w, 400, map[string]any{"error": "unknown server; allowed: guardian, evolve, audit, vault"})
		return
	}
	if !isToolName(req.Tool) {
		writeJSON(w, 400, map[string]any{"error": "invalid tool name"})
		return
	}
	bridge := filepath.Join(herosRoot, filepath.FromSlash(rel))
	if _, err := os.Stat(bridge); err != nil {
		writeJSON(w, 500, map[string]any{"error": fmt.Sprintf("bridge not found: %s", bridge)})
		return
	}
	result, err := callBridge(r.Context(), bridge, req.Tool, req.Args)
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(result)
}

// isToolName guards against passing anything weird as a tool name.
func isToolName(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

// callBridge runs one MCP initialize + tools/call against a bridge subprocess
// and returns the inner tool-result JSON (the text of result.content[0].text).
func callBridge(ctx context.Context, bridgePath, tool string, args map[string]interface{}) (json.RawMessage, error) {
	if args == nil {
		args = map[string]interface{}{}
	}
	callMsg := map[string]interface{}{
		"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": map[string]interface{}{"name": tool, "arguments": args},
	}
	callJSON, err := json.Marshal(callMsg)
	if err != nil {
		return nil, err
	}
	var stdin bytes.Buffer
	stdin.WriteString(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}` + "\n")
	stdin.Write(callJSON)
	stdin.WriteString("\n")

	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(cctx, "bash", bridgePath)
	cmd.Stdin = &stdin
	cmd.Dir = filepath.Dir(bridgePath)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		// The bridge may still have produced a valid response before exit; fall through to parse.
		if stdout.Len() == 0 {
			return nil, fmt.Errorf("bridge exec failed: %v", err)
		}
	}

	sc := bufio.NewScanner(&stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var env struct {
			ID     *int `json:"id"`
			Result *struct {
				Content []struct {
					Text string `json:"text"`
				} `json:"content"`
			} `json:"result"`
		}
		if err := json.Unmarshal([]byte(line), &env); err != nil {
			continue
		}
		if env.ID != nil && *env.ID == 1 && env.Result != nil && len(env.Result.Content) > 0 {
			return json.RawMessage(env.Result.Content[0].Text), nil
		}
	}
	return nil, fmt.Errorf("no tool result returned by bridge")
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// localhostOnly rejects any request whose remote address is not loopback.
func localhostOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err == nil {
			if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
				next.ServeHTTP(w, r)
				return
			}
		}
		http.Error(w, "forbidden: localhost only", http.StatusForbidden)
	})
}

func openBrowser(url string) {
	var cmd string
	var args []string
	switch runtime.GOOS {
	case "windows":
		cmd, args = "cmd", []string{"/c", "start", url}
	case "darwin":
		cmd, args = "open", []string{url}
	default:
		cmd, args = "xdg-open", []string{url}
	}
	_ = exec.Command(cmd, args...).Start()
}
