import { createClient } from "npm:@supabase/supabase-js@2";
import { opayMode, opayBaseUrl, assertOpayCredentialsMatchMode, opayCashierCreateHeaders, opayStatusHeaders, serializeOpayPayload, signSerializedOpayPayload, parseOpayInitializationResponse, parseOpayStatusResponse } from "./opay_checkout.ts";
import { paystackMode, assertPaystackSecretMatchesMode } from "./paystack_checkout.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SITE = "https://mizpahtechnology.com.ng";
const cors = {
  "Access-Control-Allow-Origin": SITE,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const db = () => {
  if (!SUPABASE_URL || !SERVICE_KEY) throw new Error("Secure payment storage is not configured.");
  return createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
};
function response(body: Record<string, unknown>, status=200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}
function secret(name: string) {
  const v = Deno.env.get(name)?.trim();
  if (!v) throw new Error(name + " is not configured on the secure backend.");
  return v;
}
function amountMinor(ngn: unknown) {
  const n = Number(ngn);
  if (!Number.isFinite(n) || n <= 0 || !Number.isSafeInteger(Math.round(n * 100))) throw new Error("The order total is invalid.");
  return Math.round(n * 100);
}
function paystackKey() {
  const mode = paystackMode(Deno.env.get("PAYSTACK_MODE"));
  const key = secret("PAYSTACK_SECRET_KEY");
  assertPaystackSecretMatchesMode(mode, key);
  return key;
}
function opayCreds() {
  const mode = opayMode(Deno.env.get("OPAY_MODE"));
  const publicKey = secret("OPAY_PUBLIC_KEY");
  const secretKey = secret("OPAY_SECRET_KEY");
  const merchantId = secret("OPAY_MERCHANT_ID");
  assertOpayCredentialsMatchMode(mode, Deno.env.get("OPAY_CREDENTIALS_MODE"), publicKey, secretKey, merchantId);
  return { mode, publicKey, secretKey, merchantId };
}
async function providerJson(url: string, init: RequestInit) {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(20000) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error("The payment provider is temporarily unavailable.");
  return data as Record<string, any>;
}
async function opayRequest(kind: "create"|"status", payload: Record<string, unknown>) {
  const c = opayCreds();
  const body = serializeOpayPayload(payload);
  const headers = kind === "create"
    ? opayCashierCreateHeaders(c.publicKey, c.merchantId)
    : opayStatusHeaders(await signSerializedOpayPayload(body, c.secretKey), c.merchantId);
  const path = kind === "create" ? "/api/v1/international/cashier/create" : "/api/v1/international/cashier/status";
  return await providerJson(opayBaseUrl(c.mode) + path, { method: "POST", headers, body });
}
function newReference(orderNumber: string) {
  const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 16).toUpperCase();
  return ("MZPW" + orderNumber.replace(/[^A-Z0-9]/gi, "").slice(-14) + suffix).slice(0, 40);
}
async function loadOrder(orderNumber: string) {
  if (!/^MZP-[A-Z0-9-]{8,60}$/i.test(orderNumber)) throw new Error("A valid order reference is required.");
  const { data, error } = await db().from("mizpah_web_orders")
    .select("id,order_number,customer_name,customer_email,customer_phone,items,status,intent,order_total_ngn,payment_status,payment_reference")
    .eq("order_number", orderNumber).maybeSingle();
  if (error || !data) throw new Error("The order could not be found.");
  if (data.intent !== "Order request" || data.payment_status === "quote_required" || data.order_total_ngn == null) {
    throw new Error("This order requires staff pricing before checkout.");
  }
  if (data.status === "Cancelled" || data.status === "Completed") throw new Error("This order is not available for payment.");
  return data;
}
async function initialize(req: Request) {
  const body = await req.json().catch(() => ({}));
  const order = await loadOrder(String(body.order_number ?? ""));
  const provider = String(body.provider ?? "").toLowerCase();
  if (!["paystack","opay"].includes(provider)) throw new Error("Choose OPay or Paystack.");
  const total = amountMinor(order.order_total_ngn);
  if (order.payment_status === "paid") throw new Error("This order has already been paid.");
  const client = db();
  const { data: prior } = await client.from("mizpah_web_order_payments")
    .select("reference,provider,checkout_url,status,amount_minor")
    .eq("order_id", order.id).in("status", ["pending","initialized","success"]).maybeSingle();
  if (prior?.status === "success") throw new Error("This order has already been paid.");
  if (prior?.status === "initialized" && prior.checkout_url && prior.provider === provider && Number(prior.amount_minor) === total) {
    return response({ success:true, reference:prior.reference, checkoutUrl:prior.checkout_url, provider, reused:true });
  }
  if (prior) {
    await client.from("mizpah_web_order_payments").update({status:"failed"}).eq("reference",prior.reference);
  }
  const reference = newReference(order.order_number);
  const { error: insertError } = await client.from("mizpah_web_order_payments").insert({
    order_id:order.id, provider, reference, amount_minor:total, currency:"NGN", status:"pending"
  });
  if (insertError) throw new Error("A payment attempt is already being processed. Please refresh and try again.");
  try {
    let checkoutUrl = "";
    let providerId: string|null = null;
    let raw: Record<string, any>;
    if (provider === "paystack") {
      const key = paystackKey();
      raw = await providerJson("https://api.paystack.co/transaction/initialize", {
        method:"POST",
        headers:{Authorization:"Bearer "+key,"Content-Type":"application/json"},
        body:JSON.stringify({
          email:order.customer_email, amount:String(total), currency:"NGN", reference,
          callback_url:SUPABASE_URL+"/functions/v1/website-checkout/return?reference="+encodeURIComponent(reference),
          metadata:{source:"mizpah_website",webOrderId:order.id,orderNumber:order.order_number,requestedAmountMinor:total}
        })
      });
      if (raw.status !== true || !raw.data?.authorization_url) throw new Error("Paystack did not return a checkout link.");
      checkoutUrl = String(raw.data.authorization_url);
      providerId = raw.data.id == null ? null : String(raw.data.id);
    } else {
      const c = opayCreds();
      const payload = {
        country:"NG", reference, amount:{total,currency:"NGN"},
        returnUrl:SUPABASE_URL+"/functions/v1/website-checkout/return?reference="+encodeURIComponent(reference),
        cancelUrl:SITE+"/?payment=cancelled&reference="+encodeURIComponent(reference),
        expireAt:30,
        callbackUrl:SUPABASE_URL+"/functions/v1/website-checkout/webhook?provider=opay",
        userInfo:{userEmail:order.customer_email,userId:"web-"+order.id,userMobile:order.customer_phone,userName:order.customer_name},
        product:{name:"Mizpah order "+order.order_number,description:"Payment for Mizpah Technology website order "+order.order_number}
      };
      raw = await opayRequest("create",payload);
      const checkout = parseOpayInitializationResponse(raw,c.mode);
      checkoutUrl = checkout.cashierUrl;
      providerId = checkout.orderNo;
    }
    const { error: updateError } = await client.from("mizpah_web_order_payments").update({
      status:"initialized",checkout_url:checkoutUrl,provider_transaction_id:providerId,raw_initialize:raw
    }).eq("reference",reference);
    if (updateError) throw new Error("The payment attempt could not be saved securely.");
    const { error: orderError } = await client.from("mizpah_web_orders").update({
      payment_status:"initiated",payment_method:provider,payment_reference:reference,
      payment_checkout_url:checkoutUrl,payment_updated_at:new Date().toISOString()
    }).eq("id",order.id);
    if (orderError) throw new Error("The order payment status could not be updated.");
    return response({success:true,reference,checkoutUrl,provider,amount:total/100});
  } catch (error) {
    await client.from("mizpah_web_order_payments").update({status:"failed"}).eq("reference",reference);
    await client.from("mizpah_web_orders").update({payment_status:"failed",payment_updated_at:new Date().toISOString()}).eq("id",order.id);
    throw error;
  }
}
async function verifyReference(referenceValue: string) {
  const reference = referenceValue.trim();
  if (!/^[A-Za-z0-9.=_:-]{8,80}$/.test(reference)) throw new Error("Invalid payment reference.");
  const client = db();
  const { data: payment, error } = await client.from("mizpah_web_order_payments")
    .select("id,order_id,provider,reference,amount_minor,status")
    .eq("reference",reference).maybeSingle();
  if (error || !payment) throw new Error("The payment reference was not found.");
  const { data: order, error: orderError } = await client.from("mizpah_web_orders")
    .select("id,order_number,order_total_ngn,status,payment_status")
    .eq("id",payment.order_id).maybeSingle();
  if (orderError || !order) throw new Error("The linked order was not found.");
  const expected = amountMinor(order.order_total_ngn);
  if (expected !== Number(payment.amount_minor)) throw new Error("The payment amount no longer matches the order total.");
  if (payment.status === "success" || order.payment_status === "paid") return response({success:true,status:"success",reference,orderNumber:order.order_number});
  let verified: Record<string,any>;
  if (payment.provider === "paystack") {
    verified = await providerJson("https://api.paystack.co/transaction/verify/"+encodeURIComponent(reference),{
      method:"GET",headers:{Authorization:"Bearer "+paystackKey(),"Content-Type":"application/json"}
    });
    const d = verified.data ?? {};
    if (verified.status !== true || String(d.reference ?? "") !== reference) throw new Error("Paystack could not verify this payment reference.");
    if (String(d.status ?? "").toLowerCase() !== "success") return response({success:false,status:"pending",reference,message:"Payment is not yet confirmed by Paystack."});
    if (Number(d.amount) !== expected || String(d.currency ?? "").toUpperCase() !== "NGN") throw new Error("The verified Paystack amount or currency does not match this order.");
  } else if (payment.provider === "opay") {
    verified = await opayRequest("status",{country:"NG",reference});
    const d = parseOpayStatusResponse(verified,reference,expected);
    if (d.status !== "SUCCESS") return response({success:false,status:"pending",reference,message:"Payment is not yet confirmed by OPay."});
  } else {
    throw new Error("Unsupported payment provider.");
  }
  const now = new Date().toISOString();
  const { error: orderUpdateError } = await client.from("mizpah_web_orders").update({
    payment_status:"paid",status:"Confirmed",paid_at:now,payment_updated_at:now
  }).eq("id",order.id).neq("payment_status","paid");
  if (orderUpdateError) throw new Error("Payment was verified but the order status could not be updated. Please contact Mizpah with reference "+reference+".");
  const { error: paymentUpdateError } = await client.from("mizpah_web_order_payments").update({
    status:"success",raw_verify:verified,verified_at:now
  }).eq("reference",reference);
  if (paymentUpdateError) throw new Error("Payment was verified but its audit record could not be updated. Please contact Mizpah with reference "+reference+".");
  return response({success:true,status:"success",reference,orderNumber:order.order_number});
}
async function webhook(req: Request, provider: string) {
  const raw = await req.text();
  if (provider === "paystack") {
    const signature = req.headers.get("x-paystack-signature") ?? "";
    const key = paystackKey();
    const cryptoKey = await crypto.subtle.importKey("raw",new TextEncoder().encode(key),{name:"HMAC",hash:"SHA-512"},false,["sign"]);
    const signed = await crypto.subtle.sign("HMAC",cryptoKey,new TextEncoder().encode(raw));
    const expected = Array.from(new Uint8Array(signed)).map(x=>x.toString(16).padStart(2,"0")).join("");
    if (!signature || signature !== expected) return response({success:false,message:"Invalid webhook signature."},401);
  }
  const payload = JSON.parse(raw);
  const reference = String(payload?.data?.reference ?? payload?.reference ?? "");
  const result = await verifyReference(reference);
  return result;
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null,{status:204,headers:cors});
  const url = new URL(req.url);
  const origin = req.headers.get("Origin") ?? "";
  if (origin && origin !== SITE && origin !== "https://www.mizpahtechnology.com.ng") return response({success:false,message:"Origin not allowed."},403);
  try {
    if (req.method === "GET" && url.pathname.endsWith("/return")) {
      const ref = url.searchParams.get("reference") ?? "";
      return Response.redirect(SITE+"/?payment=return&reference="+encodeURIComponent(ref),303);
    }
    if (req.method === "POST" && url.pathname.endsWith("/webhook")) {
      return await webhook(req,String(url.searchParams.get("provider") ?? "").toLowerCase());
    }
    if (req.method === "POST" && url.pathname.endsWith("/initialize")) return await initialize(req);
    if (req.method === "POST" && url.pathname.endsWith("/verify")) {
      const body = await req.json().catch(()=>({}));
      return await verifyReference(String(body.reference ?? ""));
    }
    return response({success:false,message:"Unknown website payment action."},404);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Website payment request failed.";
    return response({success:false,message},400);
  }
});
