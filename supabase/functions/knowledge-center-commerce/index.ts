import { createClient } from "npm:@supabase/supabase-js@2";
import {
  opayMode, opayBaseUrl, assertOpayCredentialsMatchMode,
  opayCashierCreateHeaders, opayStatusHeaders, serializeOpayPayload,
  signSerializedOpayPayload, parseOpayInitializationResponse,
  parseOpayStatusResponse,
} from "../website-checkout/opay_checkout.ts";
import { paystackMode, assertPaystackSecretMatchesMode } from "../website-checkout/paystack_checkout.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SITE = "https://mizpahtechnology.com.ng";
const ALLOWED_ORIGINS = new Set([SITE, "https://www.mizpahtechnology.com.ng"]);
const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : SITE,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Vary": "Origin",
  "Cache-Control": "no-store",
  "Content-Type": "application/json",
});

function db() {
  if (!SUPABASE_URL || !SERVICE_KEY) throw new Error("Secure digital commerce storage is not configured.");
  return createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
function json(req: Request, body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders(req.headers.get("Origin") ?? SITE),
  });
}
function secret(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(name + " is not configured on the secure backend.");
  return value;
}
function paystackKey() {
  const mode = paystackMode(Deno.env.get("PAYSTACK_MODE"));
  const key = secret("PAYSTACK_SECRET_KEY");
  assertPaystackSecretMatchesMode(mode, key);
  return key;
}
function opayCredentials() {
  const mode = opayMode(Deno.env.get("OPAY_MODE"));
  const publicKey = secret("OPAY_PUBLIC_KEY");
  const secretKey = secret("OPAY_SECRET_KEY");
  const merchantId = secret("OPAY_MERCHANT_ID");
  assertOpayCredentialsMatchMode(mode, Deno.env.get("OPAY_CREDENTIALS_MODE"), publicKey, secretKey, merchantId);
  return { mode, publicKey, secretKey, merchantId };
}
async function providerJson(url: string, init: RequestInit) {
  const response = await fetch(url, { ...init, signal: AbortSignal.timeout(20000) });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error("The payment provider is temporarily unavailable.");
  return data as Record<string, any>;
}
async function opayRequest(kind: "create" | "status", payload: Record<string, unknown>) {
  const credentials = opayCredentials();
  const body = serializeOpayPayload(payload);
  const headers = kind === "create"
    ? opayCashierCreateHeaders(credentials.publicKey, credentials.merchantId)
    : opayStatusHeaders(await signSerializedOpayPayload(body, credentials.secretKey), credentials.merchantId);
  const path = kind === "create"
    ? "/api/v1/international/cashier/create"
    : "/api/v1/international/cashier/status";
  return await providerJson(opayBaseUrl(credentials.mode) + path, {
    method: "POST", headers, body,
  });
}
function bearer(req: Request) {
  const match = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+([^\s]+)$/i);
  if (!match) throw new Error("Please sign in to your Mizpah account.");
  return match[1];
}
async function requireUser(req: Request) {
  const token = bearer(req);
  const { data, error } = await db().auth.getUser(token);
  if (error || !data.user || !data.user.email || !data.user.email_confirmed_at) {
    throw new Error("A verified Mizpah customer account is required.");
  }
  return data.user;
}
async function requireStaff(req: Request) {
  const user = await requireUser(req);
  const { data, error } = await db().from("mizpah_web_staff")
    .select("role,active").eq("user_id", user.id).maybeSingle();
  if (error || !data || data.active !== true || !["owner", "admin", "manager"].includes(data.role)) {
    throw new Error("You are not authorised to access Knowledge Center administration.");
  }
  return user;
}
function safeText(value: unknown, max: number) {
  if (typeof value !== "string") throw new Error("Invalid request.");
  const v = value.trim();
  if (!v || v.length > max) throw new Error("Invalid request.");
  return v;
}
function newReference() {
  return "KC" + crypto.randomUUID().replaceAll("-", "").slice(0, 30).toUpperCase();
}
async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}
async function verifyPaystackSignature(raw: string, signature: string) {
  const key = paystackKey();
  const cryptoKey = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-512" }, false, ["sign"],
  );
  const signed = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(raw));
  const expected = Array.from(new Uint8Array(signed)).map((b) => b.toString(16).padStart(2, "0")).join("");
  return !!signature && constantTimeEqual(signature.toLowerCase(), expected);
}

async function initializeCheckout(req: Request) {
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({}));
  const provider = String(body.provider ?? "").toLowerCase();
  if (!["paystack", "opay"].includes(provider)) throw new Error("Choose Paystack or OPay.");
  const productIds = Array.isArray(body.product_ids) ? body.product_ids.map((x: unknown) => String(x)) : [];
  if (productIds.length < 1 || productIds.length > 10 ||
      productIds.some((x: string) => !/^[0-9a-f-]{36}$/i.test(x))) {
    throw new Error("Choose between one and ten valid digital products.");
  }
  const idempotencyKey = safeText(body.idempotency_key, 100);
  if (!/^[A-Za-z0-9_-]{16,100}$/.test(idempotencyKey)) throw new Error("Invalid checkout session. Refresh and try again.");

  const canonicalIds = [...productIds].sort();
  const requestHash = await sha256(canonicalIds.join("|"));
  const { data: created, error: createError } = await db().rpc("kc_create_digital_order", {
    p_user_id: user.id,
    p_customer_email: user.email,
    p_idempotency_key: idempotencyKey,
    p_request_hash: requestHash,
    p_product_ids: productIds,
  });
  if (createError || !created?.order_id) {
    throw new Error(createError?.message || "Your digital order could not be created.");
  }

  const orderId = String(created.order_id);
  const orderNumber = String(created.order_number);
  const totalMinor = Number(created.total_minor);
  if (!Number.isSafeInteger(totalMinor) || totalMinor < 0) throw new Error("The digital order total is invalid.");

  if (created.status === "paid") {
    return json(req, { success: true, status: "paid", order_number: orderNumber });
  }
  if (totalMinor === 0) {
    const { error } = await db().rpc("kc_grant_free_digital_order", { p_order_id: orderId });
    if (error) throw new Error("The free resource could not be added to your library yet.");
    return json(req, { success: true, status: "paid", order_number: orderNumber });
  }

  const client = db();
  const { data: prior, error: priorError } = await client.from("kc_digital_payments")
    .select("reference,provider,checkout_url,status,amount_minor")
    .eq("order_id", orderId).in("status", ["pending", "initialized"])
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (priorError) throw new Error("The previous payment attempt could not be checked.");
  if (prior?.status === "initialized" && prior.checkout_url && prior.provider === provider &&
      Number(prior.amount_minor) === totalMinor) {
    return json(req, { success: true, status: "pending", reference: prior.reference, checkout_url: prior.checkout_url, provider });
  }
  if (prior) {
    await client.from("kc_digital_payments").update({ status: "failed", updated_at: new Date().toISOString() })
      .eq("reference", prior.reference).in("status", ["pending", "initialized"]);
  }

  const reference = newReference();
  const { error: paymentInsertError } = await client.from("kc_digital_payments").insert({
    order_id: orderId, provider, reference, amount_minor: totalMinor, currency: "NGN", status: "pending",
  });
  if (paymentInsertError) throw new Error("A payment attempt is already being processed. Please refresh and try again.");

  try {
    let checkoutUrl = "";
    let providerTransactionId: string | null = null;
    let raw: Record<string, any>;
    if (provider === "paystack") {
      raw = await providerJson("https://api.paystack.co/transaction/initialize", {
        method: "POST",
        headers: { Authorization: "Bearer " + paystackKey(), "Content-Type": "application/json" },
        body: JSON.stringify({
          email: user.email,
          amount: String(totalMinor),
          currency: "NGN",
          reference,
          callback_url: SITE + "/knowledge-checkout.html?payment=return&reference=" + encodeURIComponent(reference),
          metadata: { source: "mizpah_knowledge_center", digitalOrderId: orderId, orderNumber },
        }),
      });
      if (raw.status !== true || !raw.data?.authorization_url) throw new Error("Paystack did not return a checkout link.");
      checkoutUrl = String(raw.data.authorization_url);
      providerTransactionId = raw.data.id == null ? null : String(raw.data.id);
    } else {
      const credentials = opayCredentials();
      const payload = {
        country: "NG",
        reference,
        amount: { total: totalMinor, currency: "NGN" },
        returnUrl: SUPABASE_URL + "/functions/v1/knowledge-center-commerce/return?reference=" + encodeURIComponent(reference),
        cancelUrl: SITE + "/knowledge-checkout.html?payment=cancelled&reference=" + encodeURIComponent(reference),
        expireAt: 30,
        callbackUrl: SUPABASE_URL + "/functions/v1/knowledge-center-commerce/webhook?provider=opay",
        userInfo: { userEmail: user.email, userId: "kc-" + user.id, userName: user.email },
        product: { name: "Mizpah Knowledge Center " + orderNumber, description: "Digital resource or course purchase" },
      };
      raw = await opayRequest("create", payload);
      const parsed = parseOpayInitializationResponse(raw, credentials.mode);
      checkoutUrl = parsed.cashierUrl;
      providerTransactionId = parsed.orderNo;
    }
    const { error: updateError } = await client.from("kc_digital_payments").update({
      status: "initialized",
      checkout_url: checkoutUrl,
      provider_transaction_id: providerTransactionId,
      raw_initialize: raw,
      updated_at: new Date().toISOString(),
    }).eq("reference", reference);
    if (updateError) throw new Error("The payment checkout could not be saved securely.");
    return json(req, { success: true, status: "pending", reference, checkout_url: checkoutUrl, provider, order_number: orderNumber });
  } catch (error) {
    await client.from("kc_digital_payments").update({ status: "failed", updated_at: new Date().toISOString() }).eq("reference", reference);
    throw error;
  }
}

async function verifyReference(referenceValue: string, userId?: string) {
  const reference = referenceValue.trim();
  if (!/^[A-Za-z0-9_-]{12,80}$/.test(reference)) throw new Error("Invalid payment reference.");
  const client = db();
  const { data: payment, error } = await client.from("kc_digital_payments")
    .select("id,order_id,provider,reference,amount_minor,currency,status")
    .eq("reference", reference).maybeSingle();
  if (error || !payment) throw new Error("The digital payment reference was not found.");
  const { data: order, error: orderError } = await client.from("kc_digital_orders")
    .select("id,order_number,user_id,status,total_minor,currency")
    .eq("id", payment.order_id).maybeSingle();
  if (orderError || !order) throw new Error("The digital order was not found.");
  if (userId && order.user_id !== userId) throw new Error("This payment does not belong to your account.");
  if (Number(payment.amount_minor) !== Number(order.total_minor) || payment.currency !== order.currency) {
    throw new Error("The payment amount or currency does not match this order.");
  }
  if (payment.status === "success" && order.status === "paid") {
    return { success: true, status: "paid", order_number: order.order_number };
  }

  let raw: Record<string, any>;
  if (payment.provider === "paystack") {
    raw = await providerJson("https://api.paystack.co/transaction/verify/" + encodeURIComponent(reference), {
      method: "GET", headers: { Authorization: "Bearer " + paystackKey(), "Content-Type": "application/json" },
    });
    const data = raw.data ?? {};
    if (raw.status !== true || String(data.reference ?? "") !== reference) {
      throw new Error("Paystack could not verify this payment reference.");
    }
    if (String(data.status ?? "").toLowerCase() !== "success") {
      return { success: false, status: "pending", order_number: order.order_number };
    }
    if (Number(data.amount) !== Number(payment.amount_minor) || String(data.currency ?? "").toUpperCase() !== "NGN") {
      throw new Error("The verified Paystack amount or currency does not match this order.");
    }
  } else if (payment.provider === "opay") {
    raw = await opayRequest("status", { country: "NG", reference });
    const parsed = parseOpayStatusResponse(raw, reference, Number(payment.amount_minor));
    if (parsed.status !== "SUCCESS") return { success: false, status: "pending", order_number: order.order_number };
  } else {
    throw new Error("Unsupported payment provider.");
  }

  const { data: settlement, error: settlementError } = await client.rpc("kc_settle_digital_order_payment", {
    p_reference: reference,
    p_raw_verify: raw,
  });
  if (settlementError || !settlement?.success) {
    throw new Error("Payment was verified but access could not yet be reconciled. Contact Mizpah with reference " + reference + ".");
  }
  return { success: true, status: "paid", order_number: order.order_number };
}

async function verifyForCustomer(req: Request) {
  const user = await requireUser(req);
  const url = new URL(req.url);
  const reference = safeText(url.searchParams.get("reference"), 80);
  return json(req, await verifyReference(reference, user.id));
}

async function signedDownload(req: Request) {
  const user = await requireUser(req);
  const url = new URL(req.url);
  const fileId = safeText(url.searchParams.get("file_id"), 80);
  const client = db();
  const { data: file, error: fileError } = await client.from("kc_digital_product_files")
    .select("id,product_id,storage_path,download_filename,active")
    .eq("id", fileId).eq("active", true).maybeSingle();
  if (fileError || !file) throw new Error("This download is not available.");
  const { data: entitlement, error: entitlementError } = await client.from("kc_entitlements")
    .select("id,status,expires_at")
    .eq("user_id", user.id).eq("product_id", file.product_id).eq("status", "active")
    .limit(1).maybeSingle();
  if (entitlementError || !entitlement ||
      (entitlement.expires_at && new Date(entitlement.expires_at).getTime() <= Date.now())) {
    throw new Error("Your account does not have access to this download.");
  }
  const { data: signed, error: signedError } = await client.storage.from("mizpah-kc-private")
    .createSignedUrl(file.storage_path, 60, { download: file.download_filename });
  if (signedError || !signed?.signedUrl) throw new Error("A secure download link could not be created.");
  return json(req, { success: true, download_url: signed.signedUrl, expires_in_seconds: 60 });
}


async function customerLibrary(req: Request) {
  const user = await requireUser(req);
  const client = db();
  const { data: entitlements, error } = await client.from("kc_entitlements")
    .select("id,product_id,status,granted_at,expires_at,kc_digital_products!inner(id,title,slug,product_type,summary,cover_image_url)")
    .eq("user_id", user.id).eq("status", "active")
    .order("granted_at", { ascending: false });
  if (error) throw new Error("Your Knowledge Library could not be loaded.");
  const rows = entitlements ?? [];
  const productIds = rows.map((row: any) => row.product_id);
  let filesByProduct: Record<string, any[]> = {};
  if (productIds.length) {
    const { data: files, error: fileError } = await client.from("kc_digital_product_files")
      .select("id,product_id,download_filename,file_size_bytes,mime_type")
      .in("product_id", productIds).eq("active", true);
    if (fileError) throw new Error("Your download list could not be loaded.");
    for (const file of files ?? []) {
      (filesByProduct[file.product_id] ??= []).push({
        id: file.id, filename: file.download_filename,
        size_bytes: file.file_size_bytes, mime_type: file.mime_type,
      });
    }
  }
  const { data: enrolments, error: enrolmentError } = await client.from("kc_course_enrolments")
    .select("id,status,enrolled_at,completed_at,kc_courses!inner(id,course_title,course_summary,product_id)")
    .eq("user_id", user.id).in("status", ["active", "completed"])
    .order("enrolled_at", { ascending: false });
  if (enrolmentError) throw new Error("Your course enrolments could not be loaded.");
  return json(req, {
    success: true,
    customer: { email: user.email },
    entitlements: rows.map((row: any) => ({
      id: row.id, product_id: row.product_id, status: row.status,
      granted_at: row.granted_at, expires_at: row.expires_at,
      product: row.kc_digital_products,
      files: filesByProduct[row.product_id] ?? [],
    })),
    enrolments: enrolments ?? [],
  });
}



async function requireCourseEntitlement(userId: string, courseId: string) {
  const client = db();
  const { data: enrolment, error } = await client.from("kc_course_enrolments")
    .select("id,status,entitlement_id")
    .eq("user_id", userId).eq("course_id", courseId)
    .in("status", ["active", "completed"]).maybeSingle();
  if (error || !enrolment) throw new Error("An active course enrolment is required.");
  const { data: entitlement, error: entitlementError } = await client.from("kc_entitlements")
    .select("id,status,expires_at")
    .eq("id", enrolment.entitlement_id).eq("user_id", userId).eq("status", "active").maybeSingle();
  if (entitlementError || !entitlement ||
      (entitlement.expires_at && new Date(entitlement.expires_at).getTime() <= Date.now())) {
    throw new Error("Your course access is no longer active.");
  }
  return enrolment;
}

async function courseOutline(req: Request) {
  const user = await requireUser(req);
  const url = new URL(req.url);
  const courseId = safeText(url.searchParams.get("course_id"), 80);
  const client = db();
  await requireCourseEntitlement(user.id, courseId);
  const { data: modules, error } = await client.from("kc_course_modules")
    .select("id,title,description,sort_order")
    .eq("course_id", courseId).eq("published", true).order("sort_order");
  if (error) throw new Error("The course outline could not be loaded.");
  const moduleIds = (modules ?? []).map((m: any) => m.id);
  let lessons: any[] = [];
  if (moduleIds.length) {
    const { data, error: lessonError } = await client.from("kc_course_lessons")
      .select("id,module_id,title,lesson_type,duration_minutes,sort_order,is_preview")
      .in("module_id", moduleIds).eq("published", true).order("sort_order");
    if (lessonError) throw new Error("The course lessons could not be loaded.");
    lessons = data ?? [];
  }
  return json(req, {
    success: true,
    modules: (modules ?? []).map((m: any) => ({
      ...m,
      lessons: lessons.filter((lesson: any) => lesson.module_id === m.id),
    })),
  });
}

async function lessonContent(req: Request) {
  const user = await requireUser(req);
  const url = new URL(req.url);
  const lessonId = safeText(url.searchParams.get("lesson_id"), 80);
  const client = db();
  const { data: lesson, error } = await client.from("kc_course_lessons")
    .select("id,title,lesson_type,content_markdown,video_provider,video_reference,duration_minutes,is_preview,published,module_id,kc_course_modules!inner(id,course_id,published,kc_courses!inner(id,product_id,status))")
    .eq("id", lessonId).eq("published", true).maybeSingle();
  if (error || !lesson) throw new Error("This lesson is not available.");
  const module = (lesson as any).kc_course_modules;
  const course = module?.kc_courses;
  if (!module?.published || course?.status !== "published") throw new Error("This lesson is not available.");
  if (!lesson.is_preview) {
    await requireCourseEntitlement(user.id, course.id);
  }
  return json(req, {
    success: true,
    lesson: {
      id: lesson.id, title: lesson.title, lesson_type: lesson.lesson_type,
      content_markdown: lesson.content_markdown, video_provider: lesson.video_provider,
      video_reference: lesson.video_reference, duration_minutes: lesson.duration_minutes,
    },
  });
}

async function adminReport(req: Request) {
  await requireStaff(req);
  const client = db();
  const [{ data: orders, error }, { data: products, error: productError }] = await Promise.all([
    client.from("kc_digital_orders").select("id,order_number,status,total_minor,currency,customer_email,created_at,paid_at").order("created_at", { ascending: false }).limit(500),
    client.from("kc_digital_products").select("id,status,product_type"),
  ]);
  if (error || productError) throw new Error("Knowledge Center sales reporting is temporarily unavailable.");
  const rows = orders ?? [];
  const paid = rows.filter((o) => o.status === "paid");
  return json(req, {
    success: true,
    summary: {
      orders: rows.length,
      paid_orders: paid.length,
      pending_orders: rows.filter((o) => o.status === "pending").length,
      gross_revenue_minor: paid.reduce((sum, o) => sum + Number(o.total_minor || 0), 0),
      published_products: (products ?? []).filter((p) => p.status === "published").length,
    },
    recent_orders: rows.slice(0, 100),
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req.headers.get("Origin") ?? SITE) });
  const url = new URL(req.url);
  try {
    const origin = req.headers.get("Origin") ?? "";
    if (origin && !ALLOWED_ORIGINS.has(origin)) return json(req, { success: false, message: "Origin not allowed." }, 403);

    if (url.pathname.endsWith("/checkout") && req.method === "POST") return await initializeCheckout(req);
    if (url.pathname.endsWith("/verify") && req.method === "GET") return await verifyForCustomer(req);
    if (url.pathname.endsWith("/download") && req.method === "GET") return await signedDownload(req);\n    if (url.pathname.endsWith("/library") && req.method === "GET") return await customerLibrary(req);
    if (url.pathname.endsWith("/lesson") && req.method === "GET") return await lessonContent(req);\n    if (url.pathname.endsWith("/course-outline") && req.method === "GET") return await courseOutline(req);
    if (url.pathname.endsWith("/admin-report") && req.method === "GET") return await adminReport(req);

    if (url.pathname.endsWith("/return") && req.method === "GET") {
      const reference = url.searchParams.get("reference") ?? "";
      const destination = SITE + "/knowledge-checkout.html?payment=return&reference=" + encodeURIComponent(reference);
      return Response.redirect(destination, 303);
    }

    if (url.pathname.endsWith("/webhook") && req.method === "POST") {
      const provider = (url.searchParams.get("provider") ?? "").toLowerCase();
      if (!["paystack", "opay"].includes(provider)) return json(req, { success: false, message: "Unsupported payment provider." }, 400);
      const rawBody = await req.text();
      if (provider === "paystack") {
        const signature = req.headers.get("x-paystack-signature") ?? "";
        if (!await verifyPaystackSignature(rawBody, signature)) return json(req, { success: false, message: "Invalid payment webhook signature." }, 401);
      }
      const payload = JSON.parse(rawBody);
      const reference = String(payload?.data?.reference ?? payload?.reference ?? "");
      if (!reference) return json(req, { success: false, message: "Payment reference missing." }, 400);
      const result = await verifyReference(reference);
      return json(req, { success: true, ...result });
    }

    return json(req, { success: false, message: "Unknown Knowledge Center commerce endpoint." }, 404);
  } catch (error) {
    const message = error instanceof Error ? error.message : "The request could not be completed.";
    return json(req, { success: false, message }, 400);
  }
});
