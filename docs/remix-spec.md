# remix — Agent-Generated, User-Tweakable Companion UIs (`heros.ui/v1`)

Status: v0.1 (validator shipped — `remix/mcp-bridge.sh`, 17 CI evals)
Audience: HEROS maintainers + host-app (Android/desktop/iOS) developers

---

## 1. What the user asked for (restated)

> "It already has OS/Android/UI code. Increase its functionality so that if a
> piece of software is connected to it, it can **customize that software
> itself** — its colors, its behavior. E.g. make a **to-do list out of
> Netflix** or a Google app or anything. Whatever can be tweaked, it tweaks,
> and then makes a **separate kind of UI/UX** built from the **existing data**.
> Because it's native code with **JSON output**, if the user wants, **they can
> tweak it** too. Find a way to do this within the feature we're building."

Distilled into capabilities:

1. **Read** data from a connected app (Netflix watchlist, Google Tasks, …).
2. **Re-present** it as a *separate* experience with a *different* purpose
   (a watchlist → a to-do list) — not a clone of the original UI.
3. Let the **agent** decide the layout/colors/structure ("it can tweak it").
4. Emit that as **JSON** so the **user** can hand-tweak colors/spacing/labels
   without touching code.
5. Render it on the existing **native** Android/desktop/iOS host.

This document is the result of researching *how far each of those can actually
go*, and the concrete, safe design that delivers the achievable core.

---

## 2. What is and isn't possible (research findings)

Four things had to be checked before designing. Honest conclusions:

| Question | Finding | Consequence for the design |
|---|---|---|
| **Can we read another app's data?** | Only via **supported channels**: official APIs/OAuth (Google Tasks, Calendar), OS share-sheet / `ACTION_SEND` intents, document/file import, user-pasted exports, and on Android the *user-granted* Notification Listener / accessibility (narrow, policy-sensitive). There is **no general "read any app's private data"** on stock, non-rooted phones — that's the sandbox working as intended. | remix consumes **normalized data the host already fetched** through a supported connector. The Zero/bash core never touches the network or another app's storage. |
| **Can we restyle a third-party app *in place* (its real colors/screens)?** | **No** on stock Android/iOS. You cannot repaint Netflix's own activity. In-place theming exists only with **rooted/Xposed/substratum**, OEM theme engines, or a custom OS — all out of scope and user-hostile. Screen-scraping via accessibility to overlay is brittle and a Play-Store dead-end. | remix builds a **separate companion surface** *you* own and render, themed however you like — exactly the "separate kind of UI/UX with the existing data" the user described. We do **not** promise repainting the source app. |
| **Can a JSON document safely describe a native UI the host renders?** | **Yes** — this is **Server-Driven UI** (SDUI), proven at scale (Airbnb Ghost Platform, Lyft, etc.). The wire format is a tree of components + design tokens + an action table, rendered by a **closed catalog** of native widgets. | `heros.ui/v1` is our SDUI schema. Safety comes from the catalog being closed and every value validated. |
| **Can the user safely tweak it?** | **Yes**, if tweaks are confined to **design tokens** (W3C DTCG-style `{$type,$value}`) and whitelisted content — *not* arbitrary code/logic. | The spec separates **tokens** (user-editable colors/spacing/type) from **tree** (structure) and **actions** (behavior, whitelisted). |

**Bottom line:** the feasible, valuable feature is *"an agent turns data from a
connected app into a separate, themeable, user-editable companion UI rendered
natively, with behavior limited to safe whitelisted actions."* That is what
`remix` implements.

---

## 3. The `heros.ui/v1` spec

A remix spec is one JSON object with three parts:

```jsonc
{
  "schema": "heros.ui/v1",

  // (1) TOKENS — the user-tweakable surface. W3C DTCG shape.
  "tokens": {
    "color":   { "primary": { "$type": "color",     "$value": "#2D6CDF" },
                 "bg":      { "$type": "color",     "$value": "#0B0B0F" } },
    "spacing": { "md":      { "$type": "dimension", "$value": { "value": 16, "unit": "dp" } } }
  },

  // (2) TREE — structure, from a CLOSED widget catalog.
  "tree": {
    "type": "column",
    "children": [
      { "type": "text", "value": "My Watchlist To-Do" },
      { "type": "card", "children": [
        { "type": "text",   "value": "The Witcher S2" },
        { "type": "button", "label": "Mark watched", "onTap": "act.done" },
        { "type": "button", "label": "Open",         "onTap": "act.open" }
      ]},
      { "type": "divider" }, { "type": "spacer" }
    ]
  },

  // (3) ACTIONS — behavior, WHITELISTED. onTap references these by id.
  "actions": {
    "act.done": { "type": "mark_done",     "target": "item-1" },
    "act.open": { "type": "open_deeplink", "url": "https://cdn.example.com/title/1" }
  }
}
```

### Closed widget catalog
`column · row · card · list · text · image · button · spacer · divider`
(`list` may carry an `itemTemplate`.) Any other `type` is **rejected** — the
host can never be asked to render an arbitrary/unknown widget (e.g. a
`webview` that would defeat the sandbox).

### Action whitelist
`navigate · open_deeplink · mark_done · dismiss · submit`. The spec may **never**
carry raw OS plumbing — `intent`, `package`, or `component` fields are
**rejected**. The *host* constructs the platform intent from the safe action
type; the spec only expresses intent semantically. Every action is gated
through **`guardian`** before it runs (same approval-nonce model as forge/evolve).

---

## 4. The pipeline (where remix sits)

```
 connected app
   │  (supported channel: OAuth API / share-sheet / import / user export)
   ▼
 HOST CONNECTOR  (Android/desktop/iOS — app/, android-app/, apple/)
   │  normalizes to plain JSON records
   ▼
 AGENT  ── composes a heros.ui/v1 spec (chooses layout, tokens, actions)
   │
   ▼
 remix_render  ◄── THIS BRIDGE.  Pure compute: validate + sanitize + normalize.
   │  {status:ok, valid:true, node_count, spec}  | {error_code:INVALID_SPEC, violations}
   ▼
 USER TWEAK  ── edits tokens/labels in the JSON (colors, spacing) ──► re-run remix_render
   │
   ▼
 HOST RENDERER  ── maps validated tree → native widgets; dispatches actions via guardian
```

`remix` is the **trust boundary** between an LLM-authored (and then
user-edited) document and the native renderer. It is pure compute — args/JSON
in, JSON out, no I/O — consistent with the HEROS architecture rule.

---

## 5. Validation guarantees (enforced by `remix_render`)

Every spec that returns `valid:true` is guaranteed:

1. **`schema == "heros.ui/v1"`** exactly.
2. **Closed catalog** — every node `type` is in the catalog list.
3. **String safety** — every rendered string (`value`/`label`/`alt`/`title`) is
   printable ASCII only (no control chars, no non-ASCII smuggling) and ≤ 512
   chars. (Non-ASCII display text is a roadmap item gated on a Unicode
   normalization/confusables pass — see §7.)
4. **Token validity** — `color` tokens are `#hex` or `{alias}`; `dimension`
   tokens are `{value(0..4096),unit}` or `{alias}`.
5. **Link/image safety** — `image.source` and `open_deeplink.url` must be
   **https**, and (if `REMIX_ALLOWED_HOSTS` is set) the host must be on the
   operator allowlist.
6. **Action whitelist** — every action `type` is whitelisted; raw
   `intent`/`package`/`component` fields are forbidden.
7. **Referential integrity** — every `onTap` references a declared action id.
8. **Bounded size** — ≤ 500 nodes (DoS guard).

Otherwise `remix_render` returns `INVALID_SPEC` with a precise `violations[]`
list, so the agent (or user) can fix the offending field.

### Configuration
- `REMIX_ALLOWED_HOSTS` — comma-separated https host allowlist for links/images.
  Empty ⇒ any host allowed but https still required. Set it in production.
- Rate limit: 600 renders/hour, burst 20 (token bucket, in `mcp-bridge.sh`).

---

## 6. Worked example — "Netflix watchlist → to-do list"

1. User connects an account via a **supported** path (e.g. share-sheet export
   of a watchlist, or a Trakt/Google-Tasks OAuth connector the host owns).
2. Host normalizes to `[{id, title, deeplink}, …]`.
3. Agent composes a `heros.ui/v1` spec: a `column` of `card`s, each with the
   title and `Mark watched` / `Open` buttons, themed with the user's tokens.
4. `remix_render` validates → `valid:true` (this is CI case **RX-14**).
5. User dislikes the blue; edits `tokens.color.primary` to `#E50914`,
   re-runs `remix_render` → still valid. **That edit is the entire "user can
   tweak it" loop** — no code, just a token.
6. Host renders the tree natively; tapping `Mark watched` dispatches
   `mark_done` through guardian.

The result is a *separate* app surface ("a separate kind of UI/UX") built from
the *existing data*, exactly as described — without ever claiming to repaint
Netflix itself.

---

## 7. Honest limits & roadmap

**Today (v0.1):**
- Validator/normalizer shipped + 17 CI evals; manifest + shellcheck clean.
- ASCII-only display strings; alias tokens are validated structurally but **not
  yet resolved** to concrete values (the renderer or a later pass resolves them).

**Not done / out of scope (and why):**
- **Repainting a third-party app in place** — impossible on stock OSes; not
  attempted (see §2).
- **Reading arbitrary app data** — only supported connectors; the core never
  does I/O. Connector adapters live in the host, behind user consent.
- **Unicode display text** — deferred until a confusables/normalization guard
  exists, to keep the string-safety guarantee airtight.
- **Alias resolution & theme inheritance** — planned `remix_resolve` pass.

**Roadmap:** `remix_resolve` (token-alias resolution + light/dark theme
derivation), an `itemTemplate` data-binding pass for `list`, a small set of
reference host renderers (Compose / SwiftUI / desktop), and a connector SDK
contract so new "connected software" can be added without touching the core.

---

## 8. Files

| File | Role |
|---|---|
| `remix/mcp-bridge.sh` | MCP 2025-11-25 bridge; `remix_render` validator (pure jq, no eval). |
| `remix/mcp-manifest.json` | Tool manifest (description ≤ 512 chars). |
| `remix/eval-cases.jsonl` | 17 cases (valid specs + every rejection path). |
| `remix/eval-bridge.sh` | Stateless eval runner (sets `REMIX_ALLOWED_HOSTS`). |
| `docs/remix-spec.md` | This document. |

CI: `shell-lint` (shellcheck `-S warning`), `mcp-lint` (7 manifests),
`remix-eval` (17 cases) in `.github/workflows/release.yml`.
