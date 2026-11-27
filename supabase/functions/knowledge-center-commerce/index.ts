import { createClient } from "npm:@supabase/supabase-js@2";
import {
  opayMode, opayBaseUrl, assertOpayCredentialsMatchMode,
  opayCashierCreateHeaders, opayStatusHeaders, serializeOpayPayload,
  signSerializedOpayPayload, parseOpayInitializationResponse,
  parseOpayStatusResponse,
} from "./opay_checkout.ts";
import { paystackMode, assertPaystackSecretMatchesMode } from "./paystack_checkout.ts";

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
  const mode = paystackMode(Deno.env.get("KC_PAYSTACK_MODE"));
  const key = secret("KC_PAYSTACK_SECRET_KEY");
  assertPaystackSecretMatchesMode(mode, key);
  return key;
}
function opayCredentials() {
  const mode = opayMode(Deno.env.get("KC_OPAY_MODE"));
  const publicKey = secret("KC_OPAY_PUBLIC_KEY");
  const secretKey = secret("KC_OPAY_SECRET_KEY");
  const merchantId = secret("KC_OPAY_MERCHANT_ID");
  assertOpayCredentialsMatchMode(mode, Deno.env.get("KC_OPAY_CREDENTIALS_MODE"), publicKey, secretKey, merchantId);
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
  const currency = String(created.currency ?? "");
  if (!["NGN", "USD"].includes(currency)) throw new Error("The digital order currency is not supported.");
  if (!Number.isSafeInteger(totalMinor) || totalMinor < 0) throw new Error("The digital order total is invalid.");
  if (provider === "opay" && currency !== "NGN") throw new Error("OPay checkout is available for NGN purchases only. Choose Paystack for USD purchases.");
  if (currency === "USD" && Deno.env.get("KC_PAYSTACK_USD_ENABLED")?.trim().toLowerCase() !== "true") {
    throw new Error("USD checkout is not enabled for this Mizpah merchant account yet. Please choose an NGN-priced resource or try again after international USD settlement is activated.");
  }
  if (provider === "paystack" && totalMinor > 0 && ((currency === "NGN" && totalMinor < 5000) || (currency === "USD" && totalMinor < 200))) {
    throw new Error(currency === "USD" ? "Paystack USD transactions must be at least $2.00." : "Paystack NGN transactions must be at least ₦50.00.");
  }

  if (created.status === "paid") {
    return json(req, { success: true, status: "paid", order_number: orderNumber });
  }
  if (created.status !== "pending") {
    throw new Error("This digital order is no longer available for payment. Start a new checkout.");
  }
  if (totalMinor === 0) {
    const { error } = await db().rpc("kc_grant_free_digital_order", { p_order_id: orderId });
    if (error) throw new Error("The free resource could not be added to your library yet.");
    return json(req, { success: true, status: "paid", order_number: orderNumber });
  }

  const client = db();
  const { data: prior, error: priorError } = await client.from("kc_digital_payments")
    .select("reference,provider,checkout_url,status,amount_minor,currency")
    .eq("order_id", orderId).in("status", ["pending", "initialized"])
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (priorError) throw new Error("The previous payment attempt could not be checked.");
  if (prior?.status === "initialized" && prior.checkout_url &&
      Number(prior.amount_minor) === totalMinor && prior.currency === currency) {
    return json(req, {
      success: true, status: "pending", reference: prior.reference,
      checkout_url: prior.checkout_url, provider: prior.provider,
      message: prior.provider === provider
        ? "Continue your existing secure checkout."
        : "A checkout is already open with " + prior.provider.toUpperCase() + ". Complete or resolve it before choosing another provider.",
    });
  }
  if (prior?.status === "pending") {
    throw new Error("A payment attempt is already being prepared. Please wait a moment and refresh.");
  }
  if (prior?.status === "initialized") {
    throw new Error("An existing payment attempt needs review before a new checkout can be started.");
  }

  const reference = newReference();
  const { error: paymentInsertError } = await client.from("kc_digital_payments").insert({
    order_id: orderId, provider, reference, amount_minor: totalMinor, currency, status: "pending",
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
          currency,
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
    await client.from("kc_digital_orders").update({ status: "failed", updated_at: new Date().toISOString() }).eq("id", orderId).eq("status", "pending");
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
    const providerStatus = String(data.status ?? "").toLowerCase();
    if (providerStatus !== "success") {
      if (["failed", "abandoned", "reversed"].includes(providerStatus)) {
        await client.from("kc_digital_payments").update({ status: "failed", updated_at: new Date().toISOString() }).eq("id", payment.id);
        await client.from("kc_digital_orders").update({ status: "failed", updated_at: new Date().toISOString() }).eq("id", order.id).eq("status", "pending");
        return { success: false, status: "failed", order_number: order.order_number };
      }
      return { success: false, status: "pending", order_number: order.order_number };
    }
    if (Number(data.amount) !== Number(payment.amount_minor) || String(data.currency ?? "").toUpperCase() !== payment.currency) {
      throw new Error("The verified Paystack amount or currency does not match this order.");
    }
  } else if (payment.provider === "opay") {
    raw = await opayRequest("status", { country: "NG", reference });
    const parsed = parseOpayStatusResponse(raw, reference, Number(payment.amount_minor));
    if (parsed.status !== "SUCCESS") {
      if (["FAILED", "FAIL", "CANCELLED", "CANCELED", "CLOSED", "EXPIRED"].includes(parsed.status)) {
        await client.from("kc_digital_payments").update({ status: "failed", updated_at: new Date().toISOString() }).eq("id", payment.id);
        await client.from("kc_digital_orders").update({ status: "failed", updated_at: new Date().toISOString() }).eq("id", order.id).eq("status", "pending");
        return { success: false, status: "failed", order_number: order.order_number };
      }
      return { success: false, status: "pending", order_number: order.order_number };
    }
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
  let hasAccess=!entitlementError&&!!entitlement&&(!entitlement.expires_at||new Date(entitlement.expires_at).getTime()>Date.now());
  if(!hasAccess){
    const {data:planAccess}=await client.from("kc_membership_plan_products").select("plan_id").eq("product_id",file.product_id);
    const planIds=(planAccess??[]).map((x:any)=>x.plan_id);
    if(planIds.length){
      const {data:memberships}=await client.from("kc_memberships").select("id,current_period_end,grace_ends_at")
        .eq("user_id",user.id).in("plan_id",planIds).in("status",["active","past_due"]);
      hasAccess=(memberships??[]).some((m:any)=>(m.current_period_end&&new Date(m.current_period_end).getTime()>Date.now())||
        (m.grace_ends_at&&new Date(m.grace_ends_at).getTime()>Date.now()));
    }
  }
  if(!hasAccess) throw new Error("Your account does not have access to this download.");
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
  const rows = (entitlements ?? []).filter((row: any) => !row.expires_at || new Date(row.expires_at).getTime() > Date.now());
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
    .select("id,status,enrolled_at,completed_at,entitlement_id,kc_courses!inner(id,course_title,course_summary,product_id)")
    .eq("user_id", user.id).in("status", ["active", "completed"])
    .order("enrolled_at", { ascending: false });
  if (enrolmentError) throw new Error("Your course enrolments could not be loaded.");

  const { data: orders, error: ordersError } = await client.from("kc_digital_orders")
    .select("id,order_number,status,total_minor,currency,created_at,paid_at")
    .eq("user_id", user.id).order("created_at", { ascending: false }).limit(50);
  if (ordersError) throw new Error("Your digital purchase history could not be loaded.");
  const orderIds = (orders ?? []).map((order: any) => order.id);
  let orderItems: any[] = [];
  if (orderIds.length) {
    const { data: itemRows, error: itemError } = await client.from("kc_digital_order_items")
      .select("order_id,product_title,product_type,quantity,line_total_minor")
      .in("order_id", orderIds);
    if (itemError) throw new Error("Your digital purchase details could not be loaded.");
    orderItems = itemRows ?? [];
  }

  return json(req, {
    success: true,
    customer: { email: user.email },
    entitlements: rows.map((row: any) => ({
      id: row.id, product_id: row.product_id, status: row.status,
      granted_at: row.granted_at, expires_at: row.expires_at,
      product: row.kc_digital_products,
      files: filesByProduct[row.product_id] ?? [],
    })),
    enrolments: (enrolments ?? []).filter((enrolment: any) => rows.some((entitlement: any) => entitlement.id === enrolment.entitlement_id)),
    orders: (orders ?? []).map((order: any) => ({
      ...order,
      items: orderItems.filter((item: any) => item.order_id === order.id),
    })),
  });
}



async function requireCourseEntitlement(userId: string, courseId: string) {
  const client=db();
  const {data:course,error:courseError}=await client.from("kc_courses").select("id,product_id").eq("id",courseId).maybeSingle();
  if(courseError||!course) throw new Error("Course access is not available.");
  const {data:enrolment,error}=await client.from("kc_course_enrolments")
    .select("id,status,entitlement_id").eq("user_id",userId).eq("course_id",courseId)
    .in("status",["active","completed"]).maybeSingle();
  if(!error&&enrolment){
    const {data:entitlement,error:entitlementError}=await client.from("kc_entitlements")
      .select("id,status,expires_at").eq("id",enrolment.entitlement_id).eq("user_id",userId).eq("status","active").maybeSingle();
    if(!entitlementError&&entitlement&&(!entitlement.expires_at||new Date(entitlement.expires_at).getTime()>Date.now())) return enrolment;
  }
  const {data:access,error:accessError}=await client.from("kc_membership_plan_products")
    .select("plan_id").eq("product_id",course.product_id);
  if(accessError||!access?.length) throw new Error("An active course enrolment or membership is required.");
  const planIds=access.map((x:any)=>x.plan_id);
  const {data:memberships,error:membershipError}=await client.from("kc_memberships")
    .select("id,status,current_period_end,grace_ends_at").eq("user_id",userId)
    .in("plan_id",planIds).in("status",["active","past_due"]);
  const now=Date.now();
  const valid=(memberships??[]).find((m:any)=>
    (m.current_period_end&&new Date(m.current_period_end).getTime()>now)||
    (m.grace_ends_at&&new Date(m.grace_ends_at).getTime()>now)
  );
  if(membershipError||!valid) throw new Error("An active course enrolment or membership is required.");
  return {id:"membership:"+valid.id,status:"active",entitlement_id:null};
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
    .select("id,title,lesson_type,content_markdown,video_provider,video_reference,video_privacy_mode,captions_url,video_duration_seconds,duration_minutes,is_preview,published,module_id,kc_course_modules!inner(id,course_id,published,kc_courses!inner(id,product_id,status))")
    .eq("id", lessonId).eq("published", true).maybeSingle();
  if (error || !lesson) throw new Error("This lesson is not available.");
  const module = (lesson as any).kc_course_modules;
  const course = module?.kc_courses;
  if (!module?.published || !course) throw new Error("This lesson is not available.");
  if (lesson.is_preview && course.status !== "published") {
    throw new Error("This preview is not currently available.");
  }
  if (!lesson.is_preview) {
    await requireCourseEntitlement(user.id, course.id);
  }
  let videoEmbedUrl:string|null=null;
  if(lesson.lesson_type==="external_video"){
    const reference=String(lesson.video_reference??"");
    if(lesson.video_provider==="youtube"&&/^[A-Za-z0-9_-]{6,20}$/.test(reference)){
      videoEmbedUrl="https://www.youtube-nocookie.com/embed/"+reference+"?rel=0";
    }else if(lesson.video_provider==="vimeo"&&/^[0-9]{1,15}$/.test(reference)){
      videoEmbedUrl="https://player.vimeo.com/video/"+reference;
    }else{
      throw new Error("This lesson video is not configured with a supported provider.");
    }
  }
  return json(req, {
    success: true,
    lesson: {
      id: lesson.id, title: lesson.title, lesson_type: lesson.lesson_type,
      content_markdown: lesson.content_markdown, video_provider: lesson.video_provider,
      video_reference: lesson.video_reference, video_embed_url:videoEmbedUrl,
      video_privacy_mode:lesson.video_privacy_mode,captions_url:lesson.captions_url,
      video_duration_seconds:lesson.video_duration_seconds,duration_minutes: lesson.duration_minutes,
    },
  });
}

async function adminReport(req: Request) {
  await requireStaff(req);
  const client = db();
  const [{ data: orders, error }, { data: summary, error: summaryError }] = await Promise.all([
    client.from("kc_digital_orders").select("id,order_number,status,total_minor,currency,customer_email,created_at,paid_at").order("created_at", { ascending: false }).limit(100),
    client.rpc("kc_digital_sales_summary"),
  ]);
  if (error || summaryError || !summary) throw new Error("Knowledge Center sales reporting is temporarily unavailable.");
  return json(req, {
    success: true,
    summary,
    recent_orders: orders ?? [],
  });
}


async function assessmentList(req: Request) {
  const user = await requireUser(req);
  const url = new URL(req.url);
  const courseId = safeText(url.searchParams.get("course_id"), 80);
  await requireCourseEntitlement(user.id, courseId);
  const client = db();
  const { data: assessments, error } = await client.from("kc_assessments")
    .select("id,title,instructions,pass_mark,max_attempts,time_limit_minutes,shuffle_questions")
    .eq("course_id", courseId).eq("published", true).order("created_at");
  if (error) throw new Error("Assessments could not be loaded.");
  const ids = (assessments ?? []).map((a: any) => a.id);
  let attempts: any[] = [];
  if (ids.length) {
    const { data, error: attemptError } = await client.from("kc_assessment_attempts")
      .select("id,assessment_id,attempt_number,status,started_at,submitted_at,score,max_score,passed")
      .eq("user_id", user.id).in("assessment_id", ids).order("started_at", { ascending: false });
    if (attemptError) throw new Error("Your assessment history could not be loaded.");
    attempts = data ?? [];
  }
  let counts: Record<string, number> = {};
  if (ids.length) {
    const { data, error: questionError } = await client.from("kc_assessment_questions")
      .select("assessment_id").in("assessment_id", ids);
    if (questionError) throw new Error("Assessment question counts could not be loaded.");
    for (const row of data ?? []) counts[row.assessment_id] = (counts[row.assessment_id] ?? 0) + 1;
  }
  return json(req, { success: true, assessments: (assessments ?? []).map((a: any) => ({
    ...a, question_count: counts[a.id] ?? 0,
    attempts: attempts.filter((attempt: any) => attempt.assessment_id === a.id),
  })) });
}

async function startAssessment(req: Request) {
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({}));
  const assessmentId = safeText(body.assessment_id, 80);
  if (!/^[0-9a-f-]{36}$/i.test(assessmentId)) throw new Error("Invalid assessment.");
  const client = db();
  const { data: attempt, error: startError } = await client.rpc("kc_start_assessment_attempt", {
    p_assessment_id: assessmentId, p_user_id: user.id,
  });
  if (startError || !attempt?.attempt_id) throw new Error(startError?.message || "Assessment could not be started.");
  const { data: assessment, error: assessmentError } = await client.from("kc_assessments")
    .select("id,title,instructions,time_limit_minutes")
    .eq("id", assessmentId).eq("published", true).maybeSingle();
  if (assessmentError || !assessment) throw new Error("Assessment is no longer available.");
  const { data: questions, error: questionError } = await client.from("kc_assessment_questions")
    .select("id,question_type,prompt,options,points,sort_order")
    .eq("assessment_id", assessmentId).order("sort_order");
  if (questionError || !questions?.length) throw new Error("Assessment questions could not be loaded.");
  return json(req, { success: true, attempt, assessment, questions });
}

async function submitAssessment(req: Request) {
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({}));
  const attemptId = safeText(body.attempt_id, 80);
  if (!/^[0-9a-f-]{36}$/i.test(attemptId) || !Array.isArray(body.answers) || body.answers.length > 200) {
    throw new Error("Invalid assessment submission.");
  }
  const { data: result, error } = await db().rpc("kc_grade_assessment_attempt", {
    p_attempt_id: attemptId, p_user_id: user.id, p_answers: body.answers,
  });
  if (error || !result) throw new Error(error?.message || "Your assessment could not be graded.");
  return json(req, { success: true, result });
}


async function verifyMembershipReference(referenceValue: string, userId?: string) {
  const reference=referenceValue.trim();
  if(!/^[A-Za-z0-9_-]{12,80}$/.test(reference)) throw new Error("Invalid membership payment reference.");
  const client=db();
  const {data:renewal,error}=await client.from("kc_membership_renewals")
    .select("id,membership_id,provider,reference,amount_minor,currency,status,period_start,period_end")
    .eq("reference",reference).maybeSingle();
  if(error||!renewal) throw new Error("Membership payment reference was not found.");
  const {data:membership,error:membershipError}=await client.from("kc_memberships")
    .select("id,user_id,plan_id,status,current_period_end,kc_membership_plans(grace_period_days)").eq("id",renewal.membership_id).maybeSingle();
  if(membershipError||!membership) throw new Error("Membership record was not found.");
  if(userId&&membership.user_id!==userId) throw new Error("This membership payment does not belong to your account.");
  if(renewal.status==="success") return {success:true,status:"paid",membership_id:membership.id};
  let raw:Record<string,any>;
  if(renewal.provider==="paystack"){
    raw=await providerJson("https://api.paystack.co/transaction/verify/"+encodeURIComponent(reference),{
      method:"GET",headers:{Authorization:"Bearer "+paystackKey(),"Content-Type":"application/json"}
    });
    const data=raw.data??{};
    if(raw.status!==true||String(data.reference??"")!==reference) throw new Error("Paystack could not verify this membership payment.");
    const providerStatus=String(data.status??"").toLowerCase();
    if(providerStatus!=="success"){
      if(["failed","abandoned","reversed"].includes(providerStatus)){
        await client.from("kc_membership_renewals").update({status:"failed",updated_at:new Date().toISOString()}).eq("id",renewal.id);
        if(membership.current_period_end){
          const graceDays=Number((membership as any).kc_membership_plans?.grace_period_days)||0;
          const graceEnd=new Date(new Date(membership.current_period_end).getTime()+graceDays*86400000).toISOString();
          await client.from("kc_memberships").update({status:"past_due",grace_ends_at:graceEnd,updated_at:new Date().toISOString()}).eq("id",membership.id);
        }
        return {success:false,status:"failed",membership_id:membership.id};
      }
      return {success:false,status:"pending",membership_id:membership.id};
    }
    if(Number(data.amount)!==Number(renewal.amount_minor)||String(data.currency??"").toUpperCase()!==renewal.currency)
      throw new Error("The verified Paystack membership amount or currency does not match.");
  }else if(renewal.provider==="opay"){
    raw=await opayRequest("status",{country:"NG",reference});
    const parsed=parseOpayStatusResponse(raw,reference,Number(renewal.amount_minor));
    if(parsed.status!=="SUCCESS"){
      if(["FAILED","FAIL","CANCELLED","CANCELED","CLOSED","EXPIRED"].includes(parsed.status)){
        await client.from("kc_membership_renewals").update({status:"failed",updated_at:new Date().toISOString()}).eq("id",renewal.id);
        if(membership.current_period_end){
          const graceDays=Number((membership as any).kc_membership_plans?.grace_period_days)||0;
          const graceEnd=new Date(new Date(membership.current_period_end).getTime()+graceDays*86400000).toISOString();
          await client.from("kc_memberships").update({status:"past_due",grace_ends_at:graceEnd,updated_at:new Date().toISOString()}).eq("id",membership.id);
        }
        return {success:false,status:"failed",membership_id:membership.id};
      }
      return {success:false,status:"pending",membership_id:membership.id};
    }
  }else throw new Error("Unsupported membership payment provider.");
  const {data:settlement,error:settlementError}=await client.rpc("kc_settle_membership_renewal",{
    p_reference:reference,p_provider_event:raw
  });
  if(settlementError||!settlement?.success) throw new Error("Payment verified, but membership access could not yet be activated. Contact Mizpah with reference "+reference+".");
  return {success:true,status:"paid",membership_id:membership.id,period_end:settlement.period_end};
}

async function membershipCheckout(req:Request){
  const user=await requireUser(req);
  const body=await req.json().catch(()=>({}));
  const planId=safeText(body.plan_id,80);
  const provider=String(body.provider??"").toLowerCase();
  if(!/^[0-9a-f-]{36}$/i.test(planId)||!["paystack","opay"].includes(provider)) throw new Error("Choose a valid membership plan and payment provider.");
  const client=db();
  const {data:plan,error:planError}=await client.from("kc_membership_plans")
    .select("id,name,price_minor,currency,billing_interval,billing_mode,automatic_billing_enabled,grace_period_days")
    .eq("id",planId).eq("active",true).maybeSingle();
  if(planError||!plan) throw new Error("This membership plan is not available.");
  if(plan.billing_mode!=="manual"||plan.automatic_billing_enabled) throw new Error("Automatic renewals are not enabled. Choose a manual renewal plan or contact Mizpah.");
  const currency=String(plan.currency);
  if(provider==="opay"&&currency!=="NGN") throw new Error("OPay membership payments are available for NGN plans only.");
  if(currency==="USD"&&Deno.env.get("KC_PAYSTACK_USD_ENABLED")?.trim().toLowerCase()!=="true")
    throw new Error("USD membership checkout is not enabled for this merchant account yet.");
  const amount=Number(plan.price_minor);
  if(!Number.isSafeInteger(amount)||amount<=0) throw new Error("Membership price is invalid.");
  if(provider==="paystack"&&((currency==="NGN"&&amount<5000)||(currency==="USD"&&amount<200)))
    throw new Error(currency==="USD"?"Paystack USD transactions must be at least $2.00.":"Paystack NGN transactions must be at least ₦50.00.");
  let membershipId=body.membership_id?String(body.membership_id):"";
  let membership:any=null;
  if(membershipId){
    const found=await client.from("kc_memberships").select("id,user_id,plan_id,status,current_period_end")
      .eq("id",membershipId).eq("user_id",user.id).eq("plan_id",planId).maybeSingle();
    if(found.error||!found.data) throw new Error("Membership record not found.");
    membership=found.data;
  }else{
    const found=await client.from("kc_memberships").select("id,user_id,plan_id,status,current_period_end")
      .eq("user_id",user.id).eq("plan_id",planId).in("status",["pending","active","past_due"])
      .order("created_at",{ascending:false}).limit(1).maybeSingle();
    if(found.error) throw new Error("Your existing membership could not be checked.");
    membership=found.data;
  }
  if(!membership){
    const created=await client.from("kc_memberships").insert({user_id:user.id,plan_id:planId,billing_mode:"manual",status:"pending"})
      .select("id,user_id,plan_id,status,current_period_end").single();
    if(created.error||!created.data) throw new Error("Your membership could not be created.");
    membership=created.data;
  }
  const {data:prior,error:priorError}=await client.from("kc_membership_renewals")
    .select("reference,provider,checkout_url,status,amount_minor,currency")
    .eq("membership_id",membership.id).in("status",["pending","initialized"])
    .order("created_at",{ascending:false}).limit(1).maybeSingle();
  if(priorError) throw new Error("Existing membership payment could not be checked.");
  if(prior?.status==="initialized"&&prior.checkout_url&&Number(prior.amount_minor)===amount&&prior.currency===currency)
    return json(req,{success:true,status:"pending",reference:prior.reference,checkout_url:prior.checkout_url,provider:prior.provider});
  if(prior?.status==="pending") throw new Error("A membership payment is already being prepared. Please wait and refresh.");
  if(prior?.status==="initialized") throw new Error("An existing membership payment needs review before a new one can be started.");
  const now=new Date();
  const currentEnd=membership.current_period_end?new Date(membership.current_period_end):now;
  const periodStart=currentEnd>now?currentEnd:now;
  const periodEnd=new Date(periodStart);
  if(plan.billing_interval==="year") periodEnd.setUTCFullYear(periodEnd.getUTCFullYear()+1);
  else periodEnd.setUTCMonth(periodEnd.getUTCMonth()+1);
  const reference=newReference();
  const inserted=await client.from("kc_membership_renewals").insert({
    membership_id:membership.id,provider,reference,amount_minor:amount,currency,status:"pending",
    period_start:periodStart.toISOString(),period_end:periodEnd.toISOString()
  });
  if(inserted.error) throw new Error("Membership payment attempt could not be recorded.");
  try{
    let checkoutUrl="",raw:Record<string,any>;
    if(provider==="paystack"){
      raw=await providerJson("https://api.paystack.co/transaction/initialize",{
        method:"POST",headers:{Authorization:"Bearer "+paystackKey(),"Content-Type":"application/json"},
        body:JSON.stringify({email:user.email,amount:String(amount),currency,reference,
          callback_url:SITE+"/knowledge-membership.html?payment=return&reference="+encodeURIComponent(reference),
          metadata:{source:"mizpah_knowledge_center_membership",membershipId:membership.id,planId}})
      });
      if(raw.status!==true||!raw.data?.authorization_url) throw new Error("Paystack did not return a membership checkout link.");
      checkoutUrl=String(raw.data.authorization_url);
    }else{
      const credentials=opayCredentials();
      const payload={country:"NG",reference,amount:{total:amount,currency:"NGN"},
        returnUrl:SUPABASE_URL+"/functions/v1/knowledge-center-commerce/return?reference="+encodeURIComponent(reference),
        cancelUrl:SITE+"/knowledge-membership.html?payment=cancelled&reference="+encodeURIComponent(reference),
        expireAt:30,callbackUrl:SUPABASE_URL+"/functions/v1/knowledge-center-commerce/webhook?provider=opay",
        userInfo:{userEmail:user.email,userId:"kc-membership-"+membership.id,userName:user.email},
        product:{name:"Mizpah Academy "+plan.name,description:"Membership "+plan.billing_interval+" renewal"}};
      raw=await opayRequest("create",payload);
      checkoutUrl=parseOpayInitializationResponse(raw,credentials.mode).cashierUrl;
    }
    const updated=await client.from("kc_membership_renewals").update({
      status:"initialized",checkout_url:checkoutUrl,raw_event:raw,updated_at:new Date().toISOString()
    }).eq("reference",reference);
    if(updated.error) throw new Error("Membership checkout could not be saved.");
    return json(req,{success:true,status:"pending",reference,checkout_url:checkoutUrl,provider,membership_id:membership.id});
  }catch(error){
    await client.from("kc_membership_renewals").update({status:"failed",updated_at:new Date().toISOString()}).eq("reference",reference);
    throw error;
  }
}

async function membershipVerify(req:Request){
  const user=await requireUser(req);
  const reference=safeText(new URL(req.url).searchParams.get("reference"),80);
  return json(req,await verifyMembershipReference(reference,user.id));
}

async function cancelMembership(req:Request){
  const user=await requireUser(req);const body=await req.json().catch(()=>({}));
  const id=safeText(body.membership_id,80);
  if(!/^[0-9a-f-]{36}$/i.test(id)) throw new Error("Invalid membership.");
  const {data:membership,error}=await db().from("kc_memberships").update({
    cancel_at_period_end:true,updated_at:new Date().toISOString()
  }).eq("id",id).eq("user_id",user.id).in("status",["active","past_due"])
    .select("id,status,current_period_end,cancel_at_period_end").maybeSingle();
  if(error||!membership) throw new Error("This membership could not be cancelled.");
  return json(req,{success:true,membership,message:"Automatic renewal is not enabled; this prevents future manual renewal and leaves current access in place until the period ends."});
}

async function customerMemberships(req:Request){
  const user=await requireUser(req);
  const {data:memberships,error}=await db().from("kc_memberships")
    .select("id,status,billing_mode,provider,current_period_start,current_period_end,grace_ends_at,cancel_at_period_end,created_at,kc_membership_plans(name,description,billing_interval,price_minor,currency)")
    .eq("user_id",user.id).order("created_at",{ascending:false});
  if(error) throw new Error("Your memberships could not be loaded.");
  const ids=(memberships??[]).map((m:any)=>m.id);let renewals:any[]=[];
  if(ids.length){const result=await db().from("kc_membership_renewals")
    .select("membership_id,reference,amount_minor,currency,status,period_start,period_end,paid_at,created_at")
    .in("membership_id",ids).order("created_at",{ascending:false});
    if(result.error) throw new Error("Membership billing history could not be loaded.");renewals=result.data??[];}
  return json(req,{success:true,memberships:(memberships??[]).map((m:any)=>({...m,renewals:renewals.filter((r:any)=>r.membership_id===m.id)}))});
}

async function sponsorPlacements(req:Request){
  const url=new URL(req.url);const slot=safeText(url.searchParams.get("slot"),40);
  if(!["home_feature","article_inline","library_sidebar","academy_sidebar","newsletter"].includes(slot)) throw new Error("Invalid sponsorship placement.");
  const {data,error}=await db().from("kc_sponsor_placements")
    .select("id,placement_key,priority,kc_sponsor_campaigns!inner(id,title,disclosure_label,destination_url,kc_sponsors!inner(organisation_name,status),kc_sponsor_creatives!inner(id,headline,body,image_url,alt_text,active))")
    .eq("placement_key",slot).eq("active",true).order("priority").limit(5);
  if(error) throw new Error("Sponsored placements are temporarily unavailable.");
  const now=Date.now();
  const now=Date.now();
  const rows=(data??[]).filter((p:any)=>{
    const c=p.kc_sponsor_campaigns, s=c?.kc_sponsors, cr=c?.kc_sponsor_creatives;
    return c?.status==="approved"&&s?.status==="approved"&&
      (!c.starts_at||new Date(c.starts_at).getTime()<=now)&&
      (!c.ends_at||new Date(c.ends_at).getTime()>now)&&
      Array.isArray(cr)&&cr.some((x:any)=>x.active);
  }).map((p:any)=>{
    const c=p.kc_sponsor_campaigns,cr=(c.kc_sponsor_creatives||[]).find((x:any)=>x.active);
    let destinationUrl="";
    try{const parsed=new URL(String(c.destination_url||""));if(parsed.protocol==="https:")destinationUrl=parsed.toString();}catch{}
    return {placement_id:p.id,placement_key:p.placement_key,disclosure_label:c.disclosure_label,
      sponsor:c.kc_sponsors?.organisation_name,campaign_title:c.title,destination_url:destinationUrl,
      creative:cr};
  }).filter((p:any)=>p.destination_url);
  return json(req,{success:true,placements:rows});
}
async function sponsorEvent(req:Request){
  const body=await req.json().catch(()=>({}));
  const placementId=safeText(body.placement_id,80),eventType=String(body.event_type??"");
  const eventKey=safeText(body.event_key,100);
  if(!/^[0-9a-f-]{36}$/i.test(placementId)||!["impression","click"].includes(eventType)||!/^[A-Za-z0-9_-]{12,100}$/.test(eventKey))
    throw new Error("Invalid sponsorship event.");
  const {data:placement,error}=await db().from("kc_sponsor_placements")
    .select("id,campaign_id,active,kc_sponsor_campaigns!inner(status,starts_at,ends_at,kc_sponsors!inner(status))")
    .eq("id",placementId).eq("active",true).maybeSingle();
  if(error||!placement) throw new Error("This sponsored placement is not active.");
  const campaign=(placement as any).kc_sponsor_campaigns;
  if(campaign?.status!=="approved"||campaign.kc_sponsors?.status!=="approved"||
     (campaign.starts_at&&new Date(campaign.starts_at).getTime()>Date.now())||
     (campaign.ends_at&&new Date(campaign.ends_at).getTime()<=Date.now()))
    throw new Error("This sponsored placement is not currently approved.");
  const eventHash=await sha256(placementId+"|"+eventKey);
  const {error:insertError}=await db().from("kc_sponsor_events").upsert({
    campaign_id:placement.campaign_id,placement_id:placement.id,event_type:eventType,event_key:eventHash
  },{onConflict:"event_key,event_type",ignoreDuplicates:true});
  if(insertError) throw new Error("Sponsorship event could not be recorded.");
  return json(req,{success:true,recorded:true});
}

async function affiliateClick(req:Request){
  const body=await req.json().catch(()=>({}));
  const code=safeText(body.code,32);
  const {data:link,error}=await db().from("kc_affiliate_links")
    .select("id,code,destination_path,kc_affiliate_partners!inner(id,status,attribution_days)")
    .eq("code",code).eq("active",true).maybeSingle();
  if(error||!link||(link as any).kc_affiliate_partners?.status!=="approved")
    throw new Error("This affiliate link is not active.");
  const destination=String(link.destination_path||"/digital-library.html");
  if(!destination.startsWith("/")||destination.startsWith("//")||destination.includes("\\"))
    throw new Error("Affiliate destination is invalid.");
  const clickToken=crypto.randomUUID().replaceAll("-","");
  const referrer=req.headers.get("Referer")||"";
  let referrerHost=null;try{if(referrer)referrerHost=new URL(referrer).host;}catch{}
  const ua=req.headers.get("User-Agent")||"";
  const inserted=await db().from("kc_affiliate_clicks").insert({
    link_id:link.id,click_token:clickToken,referrer_host:referrerHost,user_agent_hash:await sha256(ua)
  });
  if(inserted.error) throw new Error("Affiliate click could not be recorded.");
  return json(req,{success:true,click_token:clickToken,destination});
}
async function affiliateAttribute(req:Request){
  const user=await requireUser(req);const body=await req.json().catch(()=>({}));
  const clickToken=safeText(body.click_token,64);
  const {data:click,error}=await db().from("kc_affiliate_clicks").select("id,link_id,clicked_at")
    .eq("click_token",clickToken).maybeSingle();
  if(error||!click) throw new Error("Affiliate referral was not found.");
  const {data:link,error:linkError}=await db().from("kc_affiliate_links")
    .select("id,partner_id,active,kc_affiliate_partners!inner(status,attribution_days)")
    .eq("id",click.link_id).eq("active",true).maybeSingle();
  if(linkError||!link||(link as any).kc_affiliate_partners?.status!=="approved")
    throw new Error("Affiliate referral is no longer active.");
  const days=Number((link as any).kc_affiliate_partners.attribution_days)||30;
  if(Date.now()-new Date(click.clicked_at).getTime()>days*86400000) throw new Error("Affiliate referral has expired.");
  const expires=new Date(Date.now()+days*86400000).toISOString();
  const {error:insertError}=await db().from("kc_affiliate_attributions").insert({
    partner_id:link.partner_id,link_id:link.id,click_id:click.id,customer_user_id:user.id,
    expires_at:expires,status:"active"
  });
  if(insertError){
    if(insertError.code==="23505") return json(req,{success:true,already_attributed:true});
    throw new Error("Affiliate referral could not be attached to your account.");
  }
  return json(req,{success:true,attributed:true});
}


async function affiliateApply(req:Request){
  const user=await requireUser(req);const body=await req.json().catch(()=>({}));
  const displayName=safeText(body.display_name,140);
  const client=db();
  const {data:existing,error}=await client.from("kc_affiliate_partners")
    .select("id,status").eq("user_id",user.id).maybeSingle();
  if(error) throw new Error("Your affiliate application could not be checked.");
  if(existing) return json(req,{success:true,partner:existing,already_applied:true});
  const {data:partner,error:insertError}=await client.from("kc_affiliate_partners").insert({
    user_id:user.id,display_name:displayName,contact_email:user.email,status:"pending"
  }).select("id,status,display_name").single();
  if(insertError||!partner) throw new Error("Your affiliate application could not be submitted.");
  return json(req,{success:true,partner});
}
async function affiliateDashboard(req:Request){
  const user=await requireUser(req);const client=db();
  const {data:partner,error}=await client.from("kc_affiliate_partners")
    .select("id,display_name,status,default_commission_basis_points,attribution_days,created_at")
    .eq("user_id",user.id).maybeSingle();
  if(error) throw new Error("Affiliate profile could not be loaded.");
  if(!partner) return json(req,{success:true,partner:null,links:[],commissions:[]});
  const [{data:links,error:linkError},{data:commissions,error:commissionError}]=await Promise.all([
    client.from("kc_affiliate_links").select("id,code,destination_path,active,created_at").eq("partner_id",partner.id).order("created_at",{ascending:false}),
    client.from("kc_affiliate_commissions").select("amount_minor,currency,status,created_at").eq("partner_id",partner.id).order("created_at",{ascending:false}).limit(100)
  ]);
  if(linkError||commissionError) throw new Error("Affiliate reports could not be loaded.");
  return json(req,{success:true,partner,links:links??[],commissions:commissions??[]});
}
async function sponsorApply(req:Request){
  const user=await requireUser(req);const body=await req.json().catch(()=>({}));
  const organisation=safeText(body.organisation_name,180);
  const description=typeof body.description==="string"?body.description.trim().slice(0,2000):"";
  const website=typeof body.website_url==="string"?body.website_url.trim().slice(0,300):"";
  if(website){const parsed=new URL(website);if(!["https:","http:"].includes(parsed.protocol))throw new Error("Enter a valid sponsor website URL.");}
  const client=db();
  const {data:existing,error}=await client.from("kc_sponsors").select("id,status")
    .eq("user_id",user.id).maybeSingle();
  if(error) throw new Error("Your sponsor application could not be checked.");
  if(existing) return json(req,{success:true,sponsor:existing,already_applied:true});
  const {data:sponsor,error:insertError}=await client.from("kc_sponsors").insert({
    user_id:user.id,organisation_name:organisation,contact_email:user.email,
    description,website_url:website||null,status:"pending"
  }).select("id,status,organisation_name").single();
  if(insertError||!sponsor) throw new Error("Your sponsor application could not be submitted.");
  return json(req,{success:true,sponsor});
}
async function sponsorDashboard(req:Request){
  const user=await requireUser(req);const client=db();
  const {data:sponsor,error}=await client.from("kc_sponsors").select("id,organisation_name,status,created_at")
    .eq("user_id",user.id).maybeSingle();
  if(error) throw new Error("Sponsor profile could not be loaded.");
  if(!sponsor) return json(req,{success:true,sponsor:null,campaigns:[]});
  const {data:campaigns,error:campaignError}=await client.from("kc_sponsor_campaigns")
    .select("id,title,campaign_type,status,starts_at,ends_at,budget_minor,currency,created_at")
    .eq("sponsor_id",sponsor.id).order("created_at",{ascending:false});
  if(campaignError) throw new Error("Sponsor campaigns could not be loaded.");
  return json(req,{success:true,sponsor,campaigns:campaigns??[]});
}


async function recommendations(req:Request){
  const url=new URL(req.url);const sourceId=url.searchParams.get("product_id");
  const client=db();let source:any=null;
  if(sourceId){
    const result=await client.from("kc_digital_products").select("id,product_type").eq("id",sourceId).eq("status","published").maybeSingle();
    if(result.error||!result.data) throw new Error("The requested resource is not available.");
    source=result.data;
  }
  let userId:string|null=null;
  const token=(req.headers.get("Authorization")??"").match(/^Bearer\s+([^\s]+)$/i)?.[1];
  if(token){const auth=await client.auth.getUser(token);if(!auth.error&&auth.data.user)userId=auth.data.user.id;}
  let owned:string[]=[];
  if(userId){
    const {data}=await client.from("kc_entitlements").select("product_id").eq("user_id",userId).eq("status","active");
    owned=(data??[]).map((x:any)=>x.product_id);
  }
  let query=client.from("kc_digital_products")
    .select("id,slug,title,product_type,summary,cover_image_url,price_minor,currency,is_featured")
    .eq("status","published").neq("product_type","")
    .order("is_featured",{ascending:false}).order("published_at",{ascending:false}).limit(8);
  if(source) query=query.eq("product_type",source.product_type).neq("id",source.id);
  const {data,error}=await query;
  if(error) throw new Error("Recommendations are temporarily unavailable.");
  const rows=(data??[]).filter((p:any)=>!owned.includes(p.id)).slice(0,6);
  return json(req,{success:true,recommendations:rows});
}
async function recommendationEvent(req:Request){
  const body=await req.json().catch(()=>({}));
  const productId=safeText(body.recommended_product_id,80);
  const sourceId=body.source_product_id?String(body.source_product_id):null;
  const type=String(body.event_type??"");
  const eventKey=safeText(body.event_key,100);
  if(!/^[0-9a-f-]{36}$/i.test(productId)||sourceId&&!/^[0-9a-f-]{36}$/i.test(sourceId)||
     !["impression","click"].includes(type)||!/^[A-Za-z0-9_-]{12,100}$/.test(eventKey))
    throw new Error("Invalid recommendation event.");
  const client=db();
  const {data:product,error}=await client.from("kc_digital_products")
    .select("id,product_type,status").eq("id",productId).eq("status","published").maybeSingle();
  if(error||!product) throw new Error("Recommended resource is not available.");
  let userId:string|null=null;
  const token=(req.headers.get("Authorization")??"").match(/^Bearer\s+([^\s]+)$/i)?.[1];
  if(token){const auth=await client.auth.getUser(token);if(!auth.error&&auth.data.user)userId=auth.data.user.id;}
  const key=await sha256(productId+"|"+type+"|"+eventKey);
  const {error:insertError}=await client.from("kc_recommendation_events").upsert({
    user_id:userId,source_product_id:sourceId,recommended_product_id:productId,
    event_type:type,category_key:product.product_type,event_key:key
  },{onConflict:"event_key",ignoreDuplicates:true});
  if(insertError) throw new Error("Recommendation event could not be recorded.");
  return json(req,{success:true,recorded:true});
}
async function adminGrowthReport(req:Request){
  await requireStaff(req);const client=db();
  const [memberships,campaigns,sponsorEvents,commissions,recommendationEvents]=await Promise.all([
    client.from("kc_memberships").select("status"),
    client.from("kc_sponsor_campaigns").select("id,status"),
    client.from("kc_sponsor_events").select("event_type"),
    client.from("kc_affiliate_commissions").select("status,currency,amount_minor"),
    client.from("kc_recommendation_events").select("event_type")
  ]);
  if(memberships.error||campaigns.error||sponsorEvents.error||commissions.error||recommendationEvents.error)
    throw new Error("Growth reporting is temporarily unavailable.");
  const count=(rows:any[],key:string)=>rows.reduce((out:any,row:any)=>{out[row[key]]=(out[row[key]]||0)+1;return out;},{});
  const commissionTotals:any={};
  for(const row of commissions.data??[]){const k=row.currency+":"+row.status;commissionTotals[k]=(commissionTotals[k]||0)+Number(row.amount_minor||0);}
  return json(req,{success:true,memberships:count(memberships.data??[],"status"),
    campaigns:count(campaigns.data??[],"status"),sponsor_events:count(sponsorEvents.data??[],"event_type"),
    affiliate_commissions:commissionTotals,recommendation_events:count(recommendationEvents.data??[],"event_type")});
}


async function knowledgeSitemap(req:Request){
  const {data:products,error}=await db().from("kc_digital_products")
    .select("slug,updated_at").eq("status","published").order("updated_at",{ascending:false}).limit(5000);
  if(error) throw new Error("Knowledge Center sitemap is temporarily unavailable.");
  const base="https://mizpahtechnology.com.ng/";
  const entries=[
    {url:base+"digital-library.html",lastmod:new Date().toISOString(),priority:"0.8"},
    {url:base+"academy.html",lastmod:new Date().toISOString(),priority:"0.8"},
    ...(products??[]).map((p:any)=>({url:base+"knowledge-product.html?slug="+encodeURIComponent(p.slug),
      lastmod:p.updated_at||new Date().toISOString(),priority:"0.7"}))
  ];
  const xmlEscape=(value:string)=>value.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&apos;");
  const xml='<?xml version="1.0" encoding="UTF-8"?>\n'+
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'+
    entries.map(x=>'  <url><loc>'+xmlEscape(x.url)+'</loc><lastmod>'+xmlEscape(x.lastmod)+'</lastmod><changefreq>weekly</changefreq><priority>'+x.priority+'</priority></url>').join("\n")+
    '\n</urlset>';
  const origin=req.headers.get("Origin")??SITE;
  return new Response(xml,{status:200,headers:{
    ...corsHeaders(origin),"Content-Type":"application/xml; charset=utf-8",
    "Cache-Control":"public, max-age=300, s-maxage=300"
  }});
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req.headers.get("Origin") ?? SITE) });
  const url = new URL(req.url);
  try {
    const origin = req.headers.get("Origin") ?? "";
    if (origin && !ALLOWED_ORIGINS.has(origin)) return json(req, { success: false, message: "Origin not allowed." }, 403);

    if (url.pathname.endsWith("/checkout") && req.method === "POST") return await initializeCheckout(req);
    if (url.pathname.endsWith("/verify") && req.method === "GET") return await verifyForCustomer(req);
    if (url.pathname.endsWith("/download") && req.method === "GET") return await signedDownload(req);
    if (url.pathname.endsWith("/library") && req.method === "GET") return await customerLibrary(req);
    if (url.pathname.endsWith("/lesson") && req.method === "GET") return await lessonContent(req);
    if (url.pathname.endsWith("/course-outline") && req.method === "GET") return await courseOutline(req);
    if (url.pathname.endsWith("/assessment-list") && req.method === "GET") return await assessmentList(req);
    if (url.pathname.endsWith("/assessment-start") && req.method === "POST") return await startAssessment(req);
    if (url.pathname.endsWith("/assessment-submit") && req.method === "POST") return await submitAssessment(req);
    if (url.pathname.endsWith("/membership-checkout") && req.method === "POST") return await membershipCheckout(req);
    if (url.pathname.endsWith("/membership-verify") && req.method === "GET") return await membershipVerify(req);
    if (url.pathname.endsWith("/memberships") && req.method === "GET") return await customerMemberships(req);
    if (url.pathname.endsWith("/membership-cancel") && req.method === "POST") return await cancelMembership(req);
    if (url.pathname.endsWith("/sponsor-placements") && req.method === "GET") return await sponsorPlacements(req);
    if (url.pathname.endsWith("/sponsor-event") && req.method === "POST") return await sponsorEvent(req);
    if (url.pathname.endsWith("/affiliate-click") && req.method === "POST") return await affiliateClick(req);
    if (url.pathname.endsWith("/affiliate-attribute") && req.method === "POST") return await affiliateAttribute(req);
    if (url.pathname.endsWith("/affiliate-apply") && req.method === "POST") return await affiliateApply(req);
    if (url.pathname.endsWith("/affiliate-dashboard") && req.method === "GET") return await affiliateDashboard(req);
    if (url.pathname.endsWith("/sponsor-apply") && req.method === "POST") return await sponsorApply(req);
    if (url.pathname.endsWith("/sponsor-dashboard") && req.method === "GET") return await sponsorDashboard(req);
    if (url.pathname.endsWith("/recommendations") && req.method === "GET") return await recommendations(req);
    if (url.pathname.endsWith("/recommendation-event") && req.method === "POST") return await recommendationEvent(req);
    if (url.pathname.endsWith("/admin-growth-report") && req.method === "GET") return await adminGrowthReport(req);
    if (url.pathname.endsWith("/sitemap") && req.method === "GET") return await knowledgeSitemap(req);
    if (url.pathname.endsWith("/admin-report") && req.method === "GET") return await adminReport(req);

    if (url.pathname.endsWith("/return") && req.method === "GET") {
      const reference = url.searchParams.get("reference") ?? "";
      const {data:membershipRenewal}=await db().from("kc_membership_renewals").select("reference").eq("reference",reference).maybeSingle();
      const destination = SITE + (membershipRenewal ? "/knowledge-membership.html" : "/knowledge-checkout.html") + "?payment=return&reference=" + encodeURIComponent(reference);
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
      const {data:membershipRenewal}=await db().from("kc_membership_renewals").select("reference").eq("reference",reference).maybeSingle();
      const result = membershipRenewal ? await verifyMembershipReference(reference) : await verifyReference(reference);
      return json(req, { ...result });
    }

    return json(req, { success: false, message: "Unknown Knowledge Center commerce endpoint." }, 404);
  } catch (error) {
    const message = error instanceof Error ? error.message : "The request could not be completed.";
    return json(req, { success: false, message }, 400);
  }
});
