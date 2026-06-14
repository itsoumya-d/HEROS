# HEROS Agentic Site Demo

This sample website shows the first launchable HEROS SDK flow:

1. A developer imports the local SDK.
2. The site registers explicit actions.
3. The site exposes a manifest at `/heros/manifest`.
4. An agent-like caller executes actions through `/heros/actions`.
5. HEROS preserves auth, approval, idempotency, and receipt behavior.

Run the integration proof:

```bash
node examples/agentic-site/agent-demo.mjs
```

Run the website:

```bash
node examples/agentic-site/server.mjs
```

The server prints the local URL. Open it, load the manifest, then trigger the demo agent action.

The protected API expects:

```text
Authorization: Bearer demo-agent-key
```

The demo intentionally uses declared safe actions instead of DOM auto-clicking. DOM hints and browser-agent adapters belong in a later production tranche.
