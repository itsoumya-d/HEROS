import { createServer } from "node:http";
import { createAgenticApp } from "../../packages/agentic/src/index.js";

const demoCatalog = [
  { sku: "BOOK-1", name: "Agentic Web Primer", price_cents: 1900 },
  { sku: "TEE-1", name: "HEROS Launch Tee", price_cents: 2900 },
  { sku: "KIT-1", name: "AI Agent Safety Kit", price_cents: 4900 }
];

export function createDemoApp() {
  const state = {
    cart: [],
    discount: null
  };

  const agenticApp = createAgenticApp({
    name: "heros-agentic-site-demo",
    version: "0.1.0",
    description: "Demo website actions exposed through HEROS.",
    authorize: ({ context }) => {
      if (context.apiKey === "demo-agent-key") {
        return {
          principal: "agent:demo",
          scopes: ["catalog:read", "cart:write", "checkout:write"]
        };
      }
      return false;
    }
  });

  agenticApp.action({
    name: "catalog.search",
    title: "Search catalog",
    description: "Search demo catalog items by text query.",
    inputSchema: {
      type: "object",
      required: ["query"],
      additionalProperties: false,
      properties: {
        query: {
          type: "string",
          minLength: 1,
          maxLength: 40,
          safeText: true
        }
      }
    },
    annotations: {
      readOnly: true
    },
    handler: ({ input }) => {
      const query = input.query.toLowerCase();
      return {
        items: demoCatalog.filter((item) =>
          item.sku.toLowerCase().includes(query) || item.name.toLowerCase().includes(query)
        )
      };
    }
  });

  agenticApp.action({
    name: "cart.add_item",
    title: "Add item to cart",
    description: "Add a catalog item to the current cart.",
    inputSchema: {
      type: "object",
      required: ["sku", "quantity"],
      additionalProperties: false,
      properties: {
        sku: {
          type: "string",
          minLength: 3,
          maxLength: 32,
          pattern: "^[A-Z0-9-]+$",
          safeText: true
        },
        quantity: {
          type: "integer",
          minimum: 1,
          maximum: 10
        }
      }
    },
    authRequired: true,
    annotations: {
      idempotent: true
    },
    handler: ({ input, auth }) => {
      const item = demoCatalog.find((catalogItem) => catalogItem.sku === input.sku);
      if (!item) {
        throw new Error("Unknown SKU");
      }
      state.cart.push({
        sku: input.sku,
        quantity: input.quantity,
        added_by: auth.principal
      });
      return {
        added: true,
        cart_size: state.cart.length
      };
    }
  });

  agenticApp.action({
    name: "checkout.apply_discount",
    title: "Apply checkout discount",
    description: "Apply a discount code to the current cart after human approval.",
    inputSchema: {
      type: "object",
      required: ["code"],
      additionalProperties: false,
      properties: {
        code: {
          type: "string",
          minLength: 3,
          maxLength: 24,
          pattern: "^[A-Z0-9-]+$",
          safeText: true
        }
      }
    },
    authRequired: true,
    approvalRequired: true,
    annotations: {
      destructive: true
    },
    handler: ({ input }) => {
      state.discount = input.code;
      return {
        discount_applied: input.code
      };
    }
  });

  return {
    agenticApp,
    state
  };
}

export async function createDemoServer({ port = 0 } = {}) {
  const { agenticApp, state } = createDemoApp();

  const server = createServer(async (req, res) => {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);

    if (req.method === "GET" && url.pathname === "/") {
      return sendHtml(res, demoHtml());
    }

    if (req.method === "GET" && url.pathname === "/heros/manifest") {
      return sendJson(res, 200, agenticApp.manifest());
    }

    if (req.method === "GET" && url.pathname === "/cart") {
      return sendJson(res, 200, state);
    }

    if (req.method === "POST" && url.pathname === "/heros/actions") {
      const body = await readJson(req);
      if (!body.ok) {
        return sendJson(res, 400, {
          ok: false,
          error_code: "BAD_JSON",
          error: "Request body must be valid JSON.",
          retryable: false
        });
      }

      const response = await agenticApp.execute({
        name: body.value.name,
        input: body.value.input,
        context: {
          apiKey: parseBearer(req.headers.authorization || "")
        },
        idempotencyKey: body.value.idempotencyKey,
        approvalToken: body.value.approvalToken
      });
      return sendJson(res, response.ok ? 200 : 400, response);
    }

    return sendJson(res, 404, {
      ok: false,
      error_code: "NOT_FOUND",
      error: "No route matches the request.",
      retryable: false
    });
  });

  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  const address = server.address();
  const url = `http://127.0.0.1:${address.port}`;

  return {
    server,
    url,
    agenticApp,
    state
  };
}

function parseBearer(header) {
  const prefix = "Bearer ";
  return header.startsWith(prefix) ? header.slice(prefix.length) : "";
}

async function readJson(req) {
  let body = "";
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 32_000) {
      return { ok: false };
    }
  }
  try {
    return {
      ok: true,
      value: body ? JSON.parse(body) : {}
    };
  } catch {
    return { ok: false };
  }
}

function sendJson(res, status, value) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8"
  });
  res.end(JSON.stringify(value, null, 2));
}

function sendHtml(res, html) {
  res.writeHead(200, {
    "content-type": "text/html; charset=utf-8"
  });
  res.end(html);
}

function demoHtml() {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>HEROS Agentic Site Demo</title>
    <style>
      body { font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem; line-height: 1.5; }
      main { max-width: 760px; }
      code, pre { background: #f4f4f5; border-radius: 6px; padding: 0.15rem 0.35rem; }
      pre { overflow: auto; padding: 1rem; }
      button { padding: 0.55rem 0.8rem; border: 1px solid #18181b; border-radius: 6px; background: #18181b; color: white; }
      .row { display: flex; gap: 0.75rem; flex-wrap: wrap; margin: 1rem 0; }
    </style>
  </head>
  <body>
    <main>
      <h1>HEROS Agentic Site Demo</h1>
      <p>This website exposes explicit agent actions at <code>/heros/manifest</code> and <code>/heros/actions</code>.</p>
      <div class="row">
        <button id="manifest">Load manifest</button>
        <button id="add">Agent add item</button>
      </div>
      <pre id="out">{}</pre>
    </main>
    <script>
      const out = document.querySelector("#out");
      document.querySelector("#manifest").onclick = async () => {
        out.textContent = JSON.stringify(await (await fetch("/heros/manifest")).json(), null, 2);
      };
      document.querySelector("#add").onclick = async () => {
        const response = await fetch("/heros/actions", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "authorization": "Bearer demo-agent-key"
          },
          body: JSON.stringify({
            name: "cart.add_item",
            input: { sku: "BOOK-1", quantity: 1 },
            idempotencyKey: "browser-demo-add"
          })
        });
        out.textContent = JSON.stringify(await response.json(), null, 2);
      };
    </script>
  </body>
</html>`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT || 0);
  const started = await createDemoServer({ port });
  console.log(JSON.stringify({
    ok: true,
    url: started.url,
    manifest: `${started.url}/heros/manifest`,
    actions: `${started.url}/heros/actions`
  }, null, 2));
}
