import { createHmac, timingSafeEqual } from "node:crypto";

export function computeWebhookSignature(rawBody, secret) {
  return createHmac("sha256", secret).update(rawBody).digest("hex");
}

export function verifyWebhookSignature(rawBody, signatureHeader, secret) {
  if (!signatureHeader || !secret) {
    return false;
  }
  const cleanSignature = signatureHeader.replace(/^sha256=/, "").trim();
  const expectedSignature = computeWebhookSignature(rawBody, secret);
  if (cleanSignature.length !== expectedSignature.length) {
    return false;
  }
  return timingSafeEqual(Buffer.from(cleanSignature, "hex"), Buffer.from(expectedSignature, "hex"));
}

export function createWebhookDispatcher(options = {}) {
  const secret = options.secret || "";
  const maxRetries = Number.isInteger(options.maxRetries) ? options.maxRetries : 3;
  const initialBackoffMs = Number.isInteger(options.initialBackoffMs) ? options.initialBackoffMs : 10;
  const processedEvents = new Map();
  const deadLetterQueue = [];

  async function dispatch(rawBody, signature, handler) {
    if (!verifyWebhookSignature(rawBody, signature, secret)) {
      const err = new Error("Invalid webhook signature");
      err.code = "INVALID_SIGNATURE";
      err.statusCode = 401;
      throw err;
    }

    let payload;
    try {
      payload = typeof rawBody === "string" ? JSON.parse(rawBody) : JSON.parse(rawBody.toString("utf8"));
    } catch {
      const err = new Error("Malformed JSON payload");
      err.code = "MALFORMED_JSON";
      err.statusCode = 400;
      throw err;
    }

    const eventId = payload.id || payload.event_id || payload.eventId || payload.idempotency_key;
    if (eventId && processedEvents.has(eventId)) {
      return {
        replayed: true,
        eventId,
        result: processedEvents.get(eventId)
      };
    }

    let attempts = 0;
    let lastError = null;

    while (attempts < maxRetries) {
      attempts++;
      try {
        const result = await handler(payload, { attempt: attempts, eventId });
        if (eventId) {
          processedEvents.set(eventId, result);
        }
        return {
          replayed: false,
          eventId,
          attempts,
          result
        };
      } catch (err) {
        lastError = err;
        if (attempts < maxRetries) {
          const delay = initialBackoffMs * Math.pow(2, attempts - 1);
          await new Promise((res) => setTimeout(res, delay));
        }
      }
    }

    const failedRecord = {
      eventId: eventId || null,
      attempts,
      payload,
      error: lastError ? lastError.message : "Handler failed",
      failedAt: new Date().toISOString()
    };
    deadLetterQueue.push(failedRecord);

    const err = new Error(`Webhook handler failed after ${attempts} attempts: ${lastError?.message}`);
    err.code = "DISPATCH_EXHAUSTED";
    err.attempts = attempts;
    err.deadLetter = failedRecord;
    throw err;
  }

  return {
    dispatch,
    getProcessedEventsCount: () => processedEvents.size,
    getDeadLetters: () => [...deadLetterQueue],
    clearDeadLetters: () => {
      deadLetterQueue.length = 0;
    }
  };
}
