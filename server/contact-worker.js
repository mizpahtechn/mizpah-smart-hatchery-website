/**
 * Mizpah Smart Hatchery website enquiry endpoint.
 *
 * Cloudflare Worker secrets/vars:
 *   RESEND_API_KEY (secret)
 *   ADMIN_EMAIL (var; defaults to info@mizpahtechnology.com.ng)
 *   FROM_EMAIL (var; must be a sender/domain verified in Resend)
 *
 * Never put RESEND_API_KEY in website JavaScript or commit it to Git.
 */
const SITE_ORIGINS = new Set([
  "https://mizpahtechnology.com.ng",
  "https://www.mizpahtechnology.com.ng",
]);

function corsHeaders(origin) {
  return {
    "Access-Control-Allow-Origin": SITE_ORIGINS.has(origin) ? origin : "https://mizpahtechnology.com.ng",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Vary": "Origin",
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  };
}

function json(data, status, origin) {
  return new Response(JSON.stringify(data), { status, headers: corsHeaders(origin) });
}

function clean(value, max) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

const MAX_REQUEST_BYTES = 16 * 1024;

async function readJsonBody(request) {
  const contentLength = Number(request.headers.get("Content-Length") || 0);
  if (contentLength > MAX_REQUEST_BYTES) {
    return { error: "too_large" };
  }

  if (!request.body) {
    return { error: "invalid_json" };
  }

  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_REQUEST_BYTES) {
        await reader.cancel();
        return { error: "too_large" };
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return { body: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { error: "invalid_json" };
  }
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get("Origin") || "";
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(origin) });
    }
    if (request.method !== "POST") {
      return json({ success: false, message: "Use POST to submit an enquiry." }, 405, origin);
    }
    if (!SITE_ORIGINS.has(origin)) {
      return json({ success: false, message: "This website origin is not allowed." }, 403, origin);
    }
    if (!env.RESEND_API_KEY || !env.FROM_EMAIL) {
      return json({ success: false, message: "The enquiry email service is not configured yet." }, 503, origin);
    }

    const contentType = request.headers.get("Content-Type") || "";
    if (!/^application\\/json(?:\\s*;|$)/i.test(contentType)) {
      return json({ success: false, message: "Please submit the form using the website form." }, 415, origin);
    }

    const parsed = await readJsonBody(request);
    if (parsed.error === "too_large") {
      return json({ success: false, message: "Your enquiry is too large. Please shorten your message and try again." }, 413, origin);
    }
    if (parsed.error || !parsed.body || typeof parsed.body !== "object" || Array.isArray(parsed.body)) {
      return json({ success: false, message: "Please submit the form again." }, 400, origin);
    }
    const body = parsed.body;

    // Quietly accept honeypot submissions without sending email.
    if (clean(body?._honey, 200)) {
      return json({ success: true }, 202, origin);
    }

    const name = clean(body?.name, 120);
    const email = clean(body?.email, 254);
    const phone = clean(body?.phone, 30);
    const message = clean(body?.message, 3000);

    if (!name || !email || !message) {
      return json({ success: false, message: "Please complete your name, email address, and enquiry message." }, 400, origin);
    }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return json({ success: false, message: "Please provide a valid email address." }, 400, origin);
    }
    if (/[\r\n]/.test(email)) {
      return json({ success: false, message: "Please provide a valid email address." }, 400, origin);
    }

    const adminEmail = env.ADMIN_EMAIL || "info@mizpahtechnology.com.ng";
    const submittedAt = new Date().toISOString();
    const text = [
      "New customer enquiry — Mizpah Smart Hatchery",
      "",
      "Name: " + name,
      "Email: " + email,
      "Phone: " + (phone || "Not provided"),
      "",
      "Enquiry:",
      message,
      "",
      "Website: https://mizpahtechnology.com.ng/",
      "Received (UTC): " + submittedAt,
    ].join("\n");

    let providerResponse;
    try {
      providerResponse = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + env.RESEND_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: env.FROM_EMAIL,
          to: [adminEmail],
          reply_to: email,
          subject: "New customer enquiry — Mizpah Smart Hatchery",
          text,
        }),
      });
    } catch {
      return json({ success: false, message: "The email service could not be reached. Please try again or contact us by phone/WhatsApp." }, 502, origin);
    }

    if (!providerResponse.ok) {
      // Do not return provider response details or credentials to the browser.
      return json({ success: false, message: "The email service did not accept the enquiry. Please try again or contact us by phone/WhatsApp." }, 502, origin);
    }

    let providerData = {};
    try { providerData = await providerResponse.json(); } catch {}
    return json({ success: true, accepted: true, id: providerData.id || null }, 202, origin);
  },
};
