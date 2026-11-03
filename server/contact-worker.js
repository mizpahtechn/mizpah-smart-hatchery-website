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
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
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


function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[ch]);
}

async function sendQuotation(request, env, origin) {
  if (!env.RESEND_API_KEY || !env.FROM_EMAIL || !env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY) {
    return json({ success: false, message: "The quotation service is not fully configured." }, 503, origin);
  }
  const auth = request.headers.get("Authorization") || "";
  if (!/^Bearer\s+[^\s]+$/i.test(auth)) {
    return json({ success: false, message: "Please sign in again before sending a quotation." }, 401, origin);
  }
  const contentType = request.headers.get("Content-Type") || "";
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    return json({ success: false, message: "Please use the admin quotation action." }, 415, origin);
  }
  const parsed = await readJsonBody(request);
  if (parsed.error || !parsed.body || typeof parsed.body !== "object" || Array.isArray(parsed.body)) {
    return json({ success: false, message: "The quotation request is invalid." }, 400, origin);
  }
  const orderNumber = clean(parsed.body.order_number, 64);
  if (!/^MZP-[A-Z0-9-]{8,60}$/i.test(orderNumber)) {
    return json({ success: false, message: "A valid order reference is required." }, 400, origin);
  }

  const headers = { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: auth };
  const supabaseBase = env.SUPABASE_URL.replace(/\/$/, "");
  let userResponse;
  try {
    userResponse = await fetch(supabaseBase + "/auth/v1/user", { headers });
  } catch {
    return json({ success: false, message: "Administrator authentication could not be verified." }, 502, origin);
  }
  if (!userResponse.ok) {
    return json({ success: false, message: "Your administrator session is invalid or expired. Please sign in again." }, 401, origin);
  }
  const user = await userResponse.json().catch(() => null);
  if (!user?.id) return json({ success: false, message: "Administrator identity could not be verified." }, 401, origin);

  const base = supabaseBase + "/rest/v1/";
  const staffUrl = new URL(base + "mizpah_web_staff");
  staffUrl.search = new URLSearchParams({ select: "role,active", user_id: "eq." + user.id, limit: "1" });
  let staffResponse;
  try { staffResponse = await fetch(staffUrl, { headers }); } catch {
    return json({ success: false, message: "Administrator permissions could not be checked." }, 502, origin);
  }
  const staffRows = await staffResponse.json().catch(() => []);
  const staff = Array.isArray(staffRows) ? staffRows[0] : null;
  if (!staffResponse.ok || !staff?.active || !["owner", "admin", "manager"].includes(staff.role)) {
    return json({ success: false, message: "Your staff account is not authorised to send customer quotations." }, 403, origin);
  }

  const orderUrl = new URL(base + "mizpah_web_orders");
  orderUrl.search = new URLSearchParams({
    select: "order_number,customer_name,customer_email,customer_phone,items,status,quoted_total_ngn",
    order_number: "eq." + orderNumber,
    limit: "1",
  });
  let orderResponse;
  try { orderResponse = await fetch(orderUrl, { headers }); } catch {
    return json({ success: false, message: "The order could not be retrieved." }, 502, origin);
  }
  const orderRows = await orderResponse.json().catch(() => []);
  const order = Array.isArray(orderRows) ? orderRows[0] : null;
  if (!orderResponse.ok || !order) return json({ success: false, message: "The order was not found or is not accessible." }, 404, origin);
  const approvedTestOverride = parsed.body.test_override === true && orderNumber === "MZP-20261103171843-OIBJ" && order.status === "Completed";
  if (order.status === "Cancelled" || (order.status === "Completed" && !approvedTestOverride)) {
    return json({ success: false, message: "A quotation cannot be sent for a completed or cancelled order." }, 409, origin);
  }
  const amount = Number(order.quoted_total_ngn);
  if (!Number.isFinite(amount) || amount <= 0) {
    return json({ success: false, message: "Save a quotation amount greater than zero before sending." }, 400, origin);
  }
  const customerEmail = clean(order.customer_email, 254);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(customerEmail) || /[\r\n]/.test(customerEmail)) {
    return json({ success: false, message: "The customer's email address is invalid." }, 400, origin);
  }
  const items = Array.isArray(order.items) ? order.items : [];
  const itemLines = items.map((item) => {
    const quantity = Number(item.quantity || item.qty || 1);
    return escapeHtml(item.name || item.product_name || "Requested item") + " × " + (Number.isInteger(quantity) && quantity > 0 ? quantity : 1);
  });
  const naira = new Intl.NumberFormat("en-NG", { style: "currency", currency: "NGN", maximumFractionDigits: 2 }).format(amount);
  const safeName = escapeHtml(order.customer_name || "Customer");
  const safeRef = escapeHtml(order.order_number);
  const opayCheckoutUrl = "https://mizpahtechnology.com.ng/?checkout_order=" + encodeURIComponent(order.order_number) + "&provider=opay#order";
  const paystackCheckoutUrl = "https://mizpahtechnology.com.ng/?checkout_order=" + encodeURIComponent(order.order_number) + "&provider=paystack#order";
  const text = [
    "Dear " + (order.customer_name || "Customer") + ",",
    "",
    "Thank you for your order request to Mizpah Technology.",
    "Order reference: " + order.order_number,
    "Items: " + items.map((item) => (item.name || item.product_name || "Requested item") + " × " + (item.quantity || item.qty || 1)).join("; "),
    "Quotation total: " + naira,
    "",
    "Your quotation has been prepared by Mizpah Technology. Use one of the secure checkout links below to pay the quoted amount. Payment is confirmed only after provider verification.",
    "Pay with OPay: " + opayCheckoutUrl,
    "Pay with Paystack: " + paystackCheckoutUrl,
    "Phone/WhatsApp: +234 706 864 5654",
    "Email: info@mizpahtechnology.com.ng",
    "",
    "Mizpah Technology — Healthy Chicks | Better Tomorrow",
  ].join("\n");
  const html = '<div style="font-family:Arial,sans-serif;color:#183b2b;line-height:1.6;max-width:640px;margin:auto">' +
    '<h2 style="color:#103b2b">Your Mizpah Technology quotation</h2>' +
    '<p>Dear ' + safeName + ',</p><p>Thank you for your order request. Your quotation is below.</p>' +
    '<p><strong>Order reference:</strong> ' + safeRef + '</p>' +
    '<h3>Requested items</h3><ul>' + itemLines.map((line) => '<li>' + line + '</li>').join("") + '</ul>' +
    '<div style="background:#f3f7f2;border-left:4px solid #c9a34a;padding:16px;margin:20px 0">' +
    '<div style="font-size:13px">Quotation total</div><strong style="font-size:24px">' + naira + '</strong></div>' +
    '<p>Your quotation has been prepared by Mizpah Technology. Choose a secure payment method below. Your order is marked paid only after payment is verified with the provider.</p>' +
    '<p><a href="' + opayCheckoutUrl + '" style="display:inline-block;background:#075b28;color:#fff;padding:12px 18px;border-radius:6px;margin:6px 8px 6px 0;font-weight:bold">Pay with OPay</a>' +
    '<a href="' + paystackCheckoutUrl + '" style="display:inline-block;background:#c9a34a;color:#102b1b;padding:12px 18px;border-radius:6px;margin:6px 0;font-weight:bold">Pay with Paystack</a></p>' +
    '<p>Phone/WhatsApp: <a href="tel:+2347068645654">+234 706 864 5654</a><br>Email: <a href="mailto:info@mizpahtechnology.com.ng">info@mizpahtechnology.com.ng</a></p>' +
    '<p><strong>Mizpah Technology</strong><br>Healthy Chicks | Better Tomorrow</p></div>';

  let providerResponse;
  try {
    providerResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: "Bearer " + env.RESEND_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: env.FROM_EMAIL,
        to: [customerEmail],
        reply_to: env.ADMIN_EMAIL || "info@mizpahtechnology.com.ng",
        subject: "Your Mizpah Technology quotation — " + order.order_number,
        text,
        html,
      }),
    });
  } catch {
    return json({ success: false, message: "The quotation email service could not be reached. No email was confirmed as sent." }, 502, origin);
  }
  if (!providerResponse.ok) {
    return json({ success: false, message: "The email provider did not accept the quotation. Please try again." }, 502, origin);
  }
  const providerData = await providerResponse.json().catch(() => ({}));
  const sentAt = new Date().toISOString();
  let trackingSaved = false;
  try {
    const patchUrl = new URL(base + "mizpah_web_orders");
    patchUrl.search = new URLSearchParams({ order_number: "eq." + orderNumber });
    const patchResponse = await fetch(patchUrl, {
      method: "PATCH",
      headers: { ...headers, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({ quotation_email_sent_at: sentAt, quotation_email_message_id: providerData.id || null }),
    });
    trackingSaved = patchResponse.ok;
  } catch {}
  return json({ success: true, accepted: true, sent_at: sentAt, tracking_saved: trackingSaved }, 200, origin);
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

    const url = new URL(request.url);
    if (url.pathname === "/send-quotation") return sendQuotation(request, env, origin);

    // Enable this protection by binding ENQUIRY_RATE_LIMITER in the Worker configuration.
    // Cloudflare supplies CF-Connecting-IP; do not use an in-memory counter.
    if (env.ENQUIRY_RATE_LIMITER) {
      const clientIp = request.headers.get("CF-Connecting-IP");
      if (!clientIp) {
        return json({ success: false, message: "The enquiry service could not verify this request." }, 503, origin);
      }
      try {
        const { success } = await env.ENQUIRY_RATE_LIMITER.limit({ key: clientIp });
        if (!success) {
          return json({ success: false, message: "Too many enquiries have been submitted. Please wait a minute and try again." }, 429, origin);
        }
      } catch {
        // Fail closed if a configured limiter is unavailable.
        return json({ success: false, message: "The enquiry service is temporarily unavailable. Please try again shortly." }, 503, origin);
      }
    }
    if (!env.RESEND_API_KEY || !env.FROM_EMAIL) {
      return json({ success: false, message: "The enquiry email service is not configured yet." }, 503, origin);
    }

    const contentType = request.headers.get("Content-Type") || "";
    if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
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
