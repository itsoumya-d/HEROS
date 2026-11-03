import { generateKeyPairSync } from "node:crypto";
import { writeFile } from "node:fs/promises";
import {
  createMemoryReceiptStore,
  createMerkleReceiptStore
} from "../src/index.js";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const store = createMerkleReceiptStore({
  store: createMemoryReceiptStore(),
  signer: { privateKey, publicKey }
});

function receipt(index) {
  return {
    receipt_id: `hr_${String(index).padStart(4, "0")}`,
    action: "demo.migration",
    input_hash: `input-${index}`,
    result_hash: `result-${index}`,
    principal: "agent:demo",
    approval: { required: false },
    idempotency_key: null,
    deliberation: null,
    deliberation_hash: null,
    annotations: { destructive: false },
    metadata: {},
    created_at: "2026-11-03T00:00:00.000Z"
  };
}

await store.append(receipt(1));
await store.append(receipt(2));
await store.append(receipt(3));
const proof = store.signedInclusionProof("hr_0002");
const fixture = {
  ...proof,
  domain_b64: Buffer.from("HEROS-MERKLE-ROOT-v1\u0000", "utf8").toString("base64")
};
await writeFile(
  new URL("../web/proof.json", import.meta.url),
  JSON.stringify(fixture, null, 2) + "\n"
);
console.log(JSON.stringify({ leaf: fixture.leaf, root: fixture.root, size: fixture.size }));
