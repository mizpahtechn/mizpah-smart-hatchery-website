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
async function opayRequest(kind: "create"|"status"|"refund_create"|"refund_status", payload: Record<string, unknown>) {
  const c = opayCreds();
  const body = serializeOpayPayload(payload);
  const create = kind === "create";
  const headers = create
    ? opayCashierCreateHeaders(c.publicKey, c.merchantId)
    : opayStatusHeaders(await signSerializedOpayPayload(body, c.secretKey), c.merchantId);
  const path = kind === "create" ? "/api/v1/international/cashier/create"
    : kind === "status" ? "/api/v1/international/cashier/status"
    : kind === "refund_create" ? "/api/v1/international/payment/refund/create"
    : "/api/v1/international/payment/refund/query";
  return await providerJson(opayBaseUrl(c.mode) + path, { method: "POST", headers, body });
}
function newReference(orderNumber: string) {
  const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 16).toUpperCase();
  return ("MZPW" + orderNumber.replace(/[^A-Z0-9]/gi, "").slice(-14) + suffix).slice(0, 40);
}
async function loadOrder(orderNumber: string) {
  if (!/^MZP-[A-Z0-9-]{8,60}$/i.test(orderNumber)) throw new Error("A valid order reference is required.");
  const { data, error } = await db().from("mizpah_web_orders")
    .select("id,order_number,customer_name,customer_email,customer_phone,customer_auth_user_id,items,status,intent,order_total_ngn,quoted_total_ngn,payment_status,payment_reference")
    .eq("order_number", orderNumber).maybeSingle();
  if (error || !data) throw new Error("The order could not be found.");
  const staffQuoted = data.intent === "Quotation request" && Number(data.quoted_total_ngn) > 0;
  if (data.intent !== "Order request" && !staffQuoted) {
    throw new Error("This order requires staff pricing before checkout.");
  }
  if (data.order_total_ngn == null && !staffQuoted) {
    throw new Error("This order requires staff pricing before checkout.");
  }
  if (data.status === "Cancelled" || data.status === "Completed") throw new Error("This order is not available for payment.");
  return data;
}

function cleanText(value: unknown, max: number, required=false): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (required && !text) throw new Error("Please complete all required customer details.");
  if (text.length > max) throw new Error("One of the submitted fields is too long.");
  return text;
}
function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c] as string));
}
function naira(value: unknown): string {
  return new Intl.NumberFormat("en-NG",{style:"currency",currency:"NGN",maximumFractionDigits:2}).format(Number(value)||0);
}
async function sendOrderEmail(
  order: Record<string, any>,
  eventType: "payment_started"|"payment_success",
  details: {provider?:string;reference?:string;amountMinor?:number;checkoutUrl?:string}
): Promise<boolean> {
  const client=db();
  const {data:claimed,error:claimError}=await client.rpc("claim_mizpah_web_order_email",{
    p_order_id:order.id,p_event_type:eventType
  });
  if(claimError || claimed!==true){
    if(claimError) console.error("Could not claim Mizpah order email:",claimError.message);
    return false;
  }
  const apiKey=Deno.env.get("RESEND_API_KEY")?.trim();
  if(!apiKey){
    await client.from("mizpah_web_order_email_events").update({
      status:"failed",last_error:"RESEND_API_KEY is not configured.",updated_at:new Date().toISOString()
    }).eq("order_id",order.id).eq("event_type",eventType);
    console.error("Mizpah customer email not sent: RESEND_API_KEY is not configured.");
    return false;
  }
  const amount=(Number(details.amountMinor)||0)/100;
  const items=Array.isArray(order.items)?order.items:[];
  const itemRows=items.map((item:any)=>(
    "<tr><td style='padding:10px;border-bottom:1px solid #e5ece5'>"+escapeHtml(item.name||"Item")+
    "<br><small>"+escapeHtml(item.quantity??"")+" × "+naira(item.unit_price_ngn)+"</small></td>"+
    "<td style='padding:10px;border-bottom:1px solid #e5ece5;text-align:right'>"+naira(item.line_total_ngn)+"</td></tr>"
  )).join("");
  const paid=eventType==="payment_success";
  const title=paid?"Payment received successfully":"Your Mizpah order has been received";
  const subject=paid
    ?"Payment successful — "+order.order_number
    :"Order received — "+order.order_number+" | Continue to payment";
  const statusText=paid
    ?"We have verified your payment successfully. Thank you for choosing Mizpah Smart Hatchery."
    :"Your order has been saved and your payment checkout has been prepared. Your order is awaiting verified payment.";
  const paymentInfo=paid
    ?"<p><strong>Payment status:</strong> <span style='color:#08752e'>PAID / SUCCESSFUL</span></p>"
    :"<p><strong>Payment status:</strong> Awaiting payment confirmation</p>";
  const checkout=(!paid&&details.checkoutUrl)
    ?"<p style='margin:24px 0'><a href='"+escapeHtml(details.checkoutUrl)+"' style='background:#075b28;color:#fff;padding:13px 22px;border-radius:24px;text-decoration:none;font-weight:bold'>Continue to secure payment</a></p>"
    :"";
  const html="<!doctype html><html><body style='margin:0;background:#f5f8f4;font-family:Arial,sans-serif;color:#17251b'>"+
    "<div style='max-width:640px;margin:24px auto;background:#fff;border:1px solid #dce7dd;border-radius:14px;overflow:hidden'>"+
    "<div style='background:#03451f;color:#fff;padding:22px;text-align:center'><div style='font-size:20px;font-weight:bold'>MIZPAH SMART HATCHERY</div><div style='color:#e5d18a;font-size:12px;margin-top:5px'>HEALTHY CHICKS | BETTER TOMORROW</div></div>"+
    "<div style='padding:26px'><h2 style='color:#075b28;margin-top:0'>"+title+"</h2><p>Hello "+escapeHtml(order.customer_name||"Customer")+",</p><p>"+statusText+"</p>"+
    "<div style='background:#eef6ed;border:1px solid #c9dfc9;border-radius:9px;padding:14px;margin:18px 0'><div style='font-size:12px;color:#5e6c61'>MIZPAH ORDER NUMBER</div><div style='font-size:22px;font-weight:bold;color:#075b28'>"+escapeHtml(order.order_number)+"</div></div>"+
    "<h3 style='color:#075b28'>Order summary</h3><table style='width:100%;border-collapse:collapse'>"+itemRows+"</table>"+
    "<p style='font-size:18px;font-weight:bold;color:#075b28;text-align:right'>Order total: "+naira(amount)+"</p>"+
    paymentInfo+
    "<p><strong>Payment provider:</strong> "+escapeHtml((details.provider||"").toUpperCase())+"</p>"+
    (details.reference?"<p><strong>Payment reference:</strong> "+escapeHtml(details.reference)+"</p>":"")+
    checkout+
    "<p>If you need assistance, contact <a href='mailto:info@mizpahtechnology.com.ng' style='color:#075b28'>info@mizpahtechnology.com.ng</a> or call +234 706 864 5654.</p>"+
    "<p>Thank you for choosing Mizpah Smart Hatchery.</p></div></div></body></html>";
  try{
    const res=await fetch("https://api.resend.com/emails",{
      method:"POST",
      headers:{
        "Authorization":"Bearer "+apiKey,
        "Content-Type":"application/json",
        "Idempotency-Key":"mizpah-"+eventType+"-"+order.id
      },
      body:JSON.stringify({
        from:"Mizpah Smart Hatchery <info@mizpahtechnology.com.ng>",
        to:[String(order.customer_email)],
        subject,html
      }),
      signal:AbortSignal.timeout(15000)
    });
    const result=await res.json().catch(()=>({}));
    if(!res.ok || !result.id) throw new Error(String(result.message||"Resend rejected the email request."));
    const {error:updateError}=await client.from("mizpah_web_order_email_events").update({
      status:"sent",provider_message_id:String(result.id),last_error:null,
      sent_at:new Date().toISOString(),updated_at:new Date().toISOString()
    }).eq("order_id",order.id).eq("event_type",eventType);
    if(updateError) console.error("Mizpah email sent but event audit update failed:",updateError.message);
    return true;
  }catch(error){
    const message=error instanceof Error?error.message:"Email delivery failed.";
    await client.from("mizpah_web_order_email_events").update({
      status:"failed",last_error:message.slice(0,500),updated_at:new Date().toISOString()
    }).eq("order_id",order.id).eq("event_type",eventType);
    console.error("Mizpah customer email failed:",message);
    return false;
  }
}



async function requireVerifiedCustomer(req: Request, expectedEmail?: string) {
  const authorization = req.headers.get("Authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) throw new Error("Please sign in to your Mizpah customer account before placing an order.");
  const { data, error } = await db().auth.getUser(match[1]);
  if (error || !data.user) throw new Error("Your customer session is invalid. Please sign in again.");
  const user = data.user;
  if (!user.email || !user.email_confirmed_at) throw new Error("Please verify your email address before placing an order.");
  if (expectedEmail && user.email.trim().toLowerCase() !== expectedEmail.trim().toLowerCase()) {
    throw new Error("The order email must match the email address on your signed-in Mizpah account.");
  }
  return user;
}

async function reserveOrder(req: Request) {
  const body = await req.json().catch(() => ({}));
  const token = String(body.draft_token ?? "").trim();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(token)) {
    throw new Error("A valid order draft token is required.");
  }
  const { data, error } = await db().rpc("reserve_mizpah_web_order_number_v2", {p_draft_token:token}).maybeSingle();
  if (error?.message?.includes("already been converted")) {
    return response({
      success:false,
      code:"DRAFT_ALREADY_CONVERTED",
      message:"This order draft has already been saved. A new draft will be started."
    },409);
  }
  if (error || !data) {
    console.error("Website order number reservation failed:", error?.message ?? "no row returned");
    throw new Error("We could not reserve your Mizpah order number. Please try again.");
  }
  return response({success:true,draft_token:data.draft_token,order_number:data.order_number,expires_at:data.expires_at});
}

async function createOrder(req: Request) {
  const body = await req.json().catch(() => ({}));
  const customer_name = cleanText(body.name,120,true);
  const customer_email = cleanText(body.email,254,true);
  const customer_phone = cleanText(body.phone,40,true);
  const country = cleanText(body.country ?? "Nigeria",100,true);
  const state = cleanText(body.state,80,true);
  const city = cleanText(body.city,100,true);
  const delivery_address = cleanText(body.address,300,true);
  const notes = cleanText(body.notes,3000,false);
  const fulfilment = cleanText(body.fulfilment,40,true);
  const customer_type = cleanText(body.customer_type,60,false) || null;
  const preferred_date = cleanText(body.preferred_date,10,false) || null;
  const referral_code = cleanText(body.referral_code,40,false).toUpperCase();
  if (referral_code && !/^[A-Z0-9-]{3,40}$/.test(referral_code)) {
    throw new Error("Enter a valid Mizpah referral code.");
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(customer_email)) throw new Error("Please provide a valid email address.");
  const authenticatedCustomer = await requireVerifiedCustomer(req, customer_email);
  if (!["Delivery","Collection","To be discussed"].includes(fulfilment)) throw new Error("Choose a valid delivery or collection method.");
  if (customer_type && !["Individual farmer","Poultry farm","Distributor / reseller","Business / institution"].includes(customer_type)) throw new Error("Choose a valid customer type.");
  if (preferred_date && !/^\d{4}-\d{2}-\d{2}$/.test(preferred_date)) throw new Error("Choose a valid preferred date.");
  if (!Array.isArray(body.items) || body.items.length < 1 || body.items.length > 30) throw new Error("An order must contain between 1 and 30 items.");
  const items = body.items.map((item: any) => {
    const product_id = String(item?.product_id ?? "").trim();
    const quantity = Number(item?.quantity);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(product_id) || !Number.isSafeInteger(quantity) || quantity < 1 || quantity > 100000000) {
      throw new Error("A selected item or quantity is invalid. Please refresh the catalogue.");
    }
    return { product_id, quantity };
  });
  if (new Set(items.map((item: any) => item.product_id)).size !== items.length) throw new Error("Please combine duplicate items into one quantity.");
  const draft_token = String(body.draft_token ?? "").trim();
  const order_number = String(body.order_number ?? "").trim();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(draft_token) ||
      !/^MZP-[A-Z0-9-]{8,60}$/i.test(order_number)) {
    throw new Error("Your reserved Mizpah order number is missing. Return to the order form and try again.");
  }
  const customer = {
    name:customer_name,email:customer_email,phone:customer_phone,country,state,city,
    address:delivery_address,notes,fulfilment,customer_type,preferred_date,
    auth_user_id:authenticatedCustomer.id
  };
  const { data, error } = await db().rpc("create_mizpah_web_order_from_draft", {
    p_draft_token:draft_token,p_order_number:order_number,p_customer:customer,p_items:items
  });
  if (error || !data) {
    console.error("Website order conversion failed:", error?.message ?? "no row returned");
    throw new Error(error?.message?.includes("reservation") || error?.message?.includes("expired")
      ? error.message
      : "We could not save this order. Please check your details and try again.");
  }
  const client = db();
  const { data: matchingCustomers, error: customerLookupError } = await client.from("customers")
    .select("id,auth_user_id").eq("email",customer_email).eq("phone",customer_phone).limit(2);
  if (customerLookupError) throw new Error("Your order was saved but your existing customer profile could not be checked.");
  if (matchingCustomers?.length === 1) {
    const existing = matchingCustomers[0];
    if (existing.auth_user_id && existing.auth_user_id !== authenticatedCustomer.id) {
      throw new Error("This customer profile is already linked to another sign-in. Please contact Mizpah support.");
    }
    if (!existing.auth_user_id) {
      const { error: linkError } = await client.from("customers").update({auth_user_id:authenticatedCustomer.id})
        .eq("id",existing.id).is("auth_user_id",null);
      if (linkError) throw new Error("Your order was saved but your existing customer profile could not be linked.");
    }
  }

  // A referral must be attached before payment. If a previous submission already
  // attached it, the database settlement trigger will have handled the reward.
  const { data: referralOrder, error: referralOrderError } = await client
    .from("mizpah_web_orders")
    .select("payment_status,paid_at,referral_state_order_id")
    .eq("order_number",order_number)
    .maybeSingle();
  if (referralOrderError || !referralOrder) {
    throw new Error("We could not verify the saved order before recording its referral.");
  }
  if (!referralOrder.referral_state_order_id &&
      (String(referralOrder.payment_status).toLowerCase() === "paid" || referralOrder.paid_at)) {
    if (referral_code) {
      throw new Error("Referral codes must be applied before an order is paid. Please contact Mizpah if you need help.");
    }
  } else if (!referralOrder.referral_state_order_id) {
    // Attach an entered code, or carry forward an existing app referral for a
    // returning customer. Rewards are issued only by the shared settlement trigger.
    const { error: referralError } = await client.rpc("register_mizpah_web_order_referral", {
      p_order_number:order_number,
      p_referral_code:referral_code || null
    });
    if (referralError) {
      console.error("Website order referral attribution failed:", referralError.message);
      throw new Error(referralError.message || "We could not record the referral code. Please check it and try again.");
    }
  }

  return response({success:true,order:data});
}
async function resumeSavedOrder(req: Request) {
  const body = await req.json().catch(() => ({}));
  const orderNumber = cleanText(body.order_number, 80, true).toUpperCase();
  const email = cleanText(body.email, 254, true).toLowerCase();
  if (!/^MZP-[A-Z0-9-]{8,60}$/.test(orderNumber) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("Enter a valid Mizpah order number and the email address used for that order.");
  }
  const authenticatedCustomer = await requireVerifiedCustomer(req, email);
  const { data, error } = await db().from("mizpah_web_orders")
    .select("customer_auth_user_id,order_number,customer_name,customer_email,customer_phone,country,state,city,delivery_address,fulfilment,preferred_date,notes,items,status,intent,order_total_ngn,quoted_total_ngn,payment_status,payment_method,payment_reference,paid_at,created_at")
    .eq("order_number", orderNumber).maybeSingle();
  if (error || !data ||
      String(data.customer_email || "").trim().toLowerCase() !== email ||
      String(data.customer_auth_user_id || "") !== authenticatedCustomer.id) {
    throw new Error("We could not find an order matching your signed-in account, order number and email address.");
  }
  const total = data.order_total_ngn ?? data.quoted_total_ngn;
  const items = Array.isArray(data.items) ? data.items.map((item: any) => ({
    name: String(item?.name ?? item?.product_name ?? "Order item"),
    category: String(item?.category ?? ""),
    item_type: String(item?.item_type ?? "product"),
    quantity: Number(item?.quantity ?? 0),
    price_on_request: item?.price_on_request === true || (item?.unit_price_ngn == null && item?.unit_price == null),
    unit_price_ngn: item?.unit_price_ngn == null && item?.unit_price == null
      ? null
      : Number(item?.unit_price_ngn ?? item?.unit_price),
    line_total_ngn: item?.line_total_ngn == null && item?.line_total == null
      ? null
      : Number(item?.line_total_ngn ?? item?.line_total)
  })) : [];
  return response({
    success: true,
    order: {
      order_number: data.order_number,
      customer_name: data.customer_name,
      customer_email: data.customer_email,
      customer_phone: data.customer_phone,
      country: data.country,
      state: data.state,
      city: data.city,
      delivery_address: data.delivery_address,
      fulfilment: data.fulfilment,
      preferred_date: data.preferred_date,
      notes: data.notes,
      items,
      status: data.status,
      payment_status: data.payment_status,
      payment_method: data.payment_method,
      payment_reference: data.payment_reference,
      paid_at: data.paid_at,
      created_at: data.created_at,
      total_ngn: total == null ? null : Number(total),
      is_paid: data.payment_status === "paid",
      payable: (data.intent === "Order request" || (data.intent === "Quotation request" && data.quoted_total_ngn != null && Number(data.quoted_total_ngn) > 0)) && total != null && data.payment_status !== "paid" && data.status !== "Cancelled" && data.status !== "Completed"
    }
  });
}
async function initialize(req: Request) {
  const body = await req.json().catch(() => ({}));
  const order = await loadOrder(String(body.order_number ?? ""));
  const authenticatedCustomer = await requireVerifiedCustomer(req, order.customer_email);
  if (order.customer_auth_user_id !== authenticatedCustomer.id) throw new Error("This order does not belong to your signed-in customer account.");
  const provider = String(body.provider ?? "").toLowerCase();
  if (!["paystack","opay"].includes(provider)) throw new Error("Choose OPay or Paystack.");
  const total = amountMinor(order.order_total_ngn ?? order.quoted_total_ngn);
  if (order.payment_status === "paid") throw new Error("This order has already been paid.");
  const client = db();
  const { data: prior } = await client.from("mizpah_web_order_payments")
    .select("reference,provider,checkout_url,status,amount_minor")
    .eq("order_id", order.id).in("status", ["pending","initialized","success"]).maybeSingle();
  if (prior?.status === "success") throw new Error("This order has already been paid.");
  if (prior?.status === "initialized" && prior.checkout_url && prior.provider === provider && Number(prior.amount_minor) === total) {
    await sendOrderEmail(order,"payment_started",{provider,reference:prior.reference,amountMinor:total,checkoutUrl:prior.checkout_url});
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
          callback_url:SITE+"/order.html?payment=return&reference="+encodeURIComponent(reference),
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
        cancelUrl:SITE+"/order.html?payment=cancelled&reference="+encodeURIComponent(reference),
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
    await sendOrderEmail(order,"payment_started",{provider,reference,amountMinor:total,checkoutUrl});
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
    .select("id,order_number,customer_name,customer_email,items,order_total_ngn,quoted_total_ngn,status,payment_status")
    .eq("id",payment.order_id).maybeSingle();
  if (orderError || !order) throw new Error("The linked order was not found.");
  if (order.status === "Cancelled" || order.status === "Completed") throw new Error("This order is not available for payment verification.");
  const expected = amountMinor(order.order_total_ngn ?? order.quoted_total_ngn);
  if (expected !== Number(payment.amount_minor)) throw new Error("The payment amount no longer matches the order total.");
  if (payment.status === "success") {
    await sendOrderEmail(order,"payment_success",{provider:payment.provider,reference,amountMinor:expected});
    return response({success:true,status:"success",reference,orderNumber:order.order_number});
  }
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
  const { data: settlement, error: settlementError } = await client.rpc("settle_mizpah_web_order_payment", {
    p_reference:reference,
    p_raw_verify:verified
  });
  if (settlementError || !settlement) {
    console.error("Atomic website payment settlement failed:",settlementError?.message ?? "no result");
    throw new Error("Payment was verified but could not yet be reconciled safely. Please contact Mizpah with reference "+reference+".");
  }
  await sendOrderEmail(order,"payment_success",{provider:payment.provider,reference,amountMinor:expected});
  return response({success:true,status:"success",reference,orderNumber:order.order_number});
}
async function requireRefundManager(req: Request) {
  const authorization=req.headers.get("Authorization")??"";
  const match=authorization.match(/^Bearer\\s+(.+)$/i);
  if(!match) throw new Error("Administrator sign-in is required to manage refunds.");
  const client=db();
  const {data,error}=await client.auth.getUser(match[1]);
  if(error||!data.user) throw new Error("Your administrator session is invalid. Sign in again.");
  const {data:staff,error:staffError}=await client.from("mizpah_web_staff")
    .select("role,active").eq("user_id",data.user.id).maybeSingle();
  if(staffError||!staff||staff.active!==true||!["owner","admin","manager"].includes(staff.role))
    throw new Error("Only an active owner, admin or manager can manage refunds.");
  return data.user;
}
function refundStatus(provider:string, raw:Record<string,any>):string {
  const value=provider==="paystack" ? String(raw?.data?.status??"").toLowerCase()
    : String(raw?.data?.orderStatus??"").toUpperCase();
  if(provider==="paystack"){
    if(value==="processed") return "processed";
    if(value==="processing") return "processing";
    if(value==="needs-attention") return "needs_attention";
    if(value==="failed") return "failed";
    return "pending";
  }
  if(value==="SUCCESS") return "processed";
  if(value==="FAIL") return "failed";
  if(value==="PENDING") return "processing";
  return "pending";
}
async function createRefund(req:Request) {
  const actor=await requireRefundManager(req);
  const body=await req.json().catch(()=>({}));
  const orderNumber=cleanText(body.order_number,80,true).toUpperCase();
  const amount=amountMinor(body.amount_ngn);
  const reason=cleanText(body.reason,500,true);
  const refundReference="MZPR"+crypto.randomUUID().replaceAll("-","").slice(0,28).toUpperCase();
  const client=db();
  const {data:reserved,error:reserveError}=await client.rpc("reserve_mizpah_web_refund",{
    p_order_number:orderNumber,p_amount_minor:amount,p_reason:reason,
    p_requested_by:actor.id,p_refund_reference:refundReference
  });
  if(reserveError||!reserved) throw new Error(reserveError?.message||"The refund could not be reserved safely.");
  try{
    let raw:Record<string,any>;
    if(reserved.provider==="paystack"){
      raw=await providerJson("https://api.paystack.co/refund",{
        method:"POST",
        headers:{Authorization:"Bearer "+paystackKey(),"Content-Type":"application/json"},
        body:JSON.stringify({
          transaction:reserved.original_payment_reference,
          amount,
          currency:"NGN",
          reference:refundReference,
          customer_note:reason,
          merchant_note:"Mizpah order "+orderNumber+" refund"
        })
      });
      if(raw.status!==true||!raw.data) throw new Error("Paystack did not accept the refund request.");
    }else if(reserved.provider==="opay"){
      const rawCreate=await opayRequest("refund_create",{
        amount:{currency:"NGN",total:amount},
        callbackUrl:SUPABASE_URL+"/functions/v1/website-checkout/webhook?provider=opay",
        country:"NG",
        originalReference:reserved.original_payment_reference,
        reference:refundReference,
        refundWay:"Original",
        refundReason:reason
      });
      if(rawCreate.code!=="00000"||!rawCreate.data) throw new Error("OPay did not accept the refund request.");
      raw=rawCreate;
    }else{
      throw new Error("Unsupported refund provider.");
    }
    const status=refundStatus(reserved.provider,raw);
    const providerRefundId=String(raw?.data?.id??raw?.data?.orderNo??"");
    const {error:saveError}=await client.rpc("apply_mizpah_web_refund_status",{
      p_refund_reference:refundReference,p_status:status,
      p_provider_refund_id:providerRefundId,p_provider_response:raw
    });
    if(saveError) throw new Error("Provider accepted the refund but its status could not be saved. Reference: "+refundReference);
    return response({success:true,refund_reference:refundReference,status,amount_minor:amount,provider:reserved.provider});
  }catch(error){
    const message=error instanceof Error?error.message:"Refund request failed.";
    await client.rpc("apply_mizpah_web_refund_status",{
      p_refund_reference:refundReference,p_status:"failed",p_provider_refund_id:"",
      p_provider_response:{error:message.slice(0,400)}
    });
    throw error;
  }
}
async function syncRefund(req:Request) {
  await requireRefundManager(req);
  const body=await req.json().catch(()=>({}));
  const refundReference=cleanText(body.refund_reference,80,true);
  const client=db();
  const {data:refund,error}=await client.from("mizpah_web_refunds").select("*")
    .eq("refund_reference",refundReference).maybeSingle();
  if(error||!refund) throw new Error("Refund record not found.");
  if(refund.status==="processed") return response({success:true,status:"processed",refund_reference:refundReference});
  let raw:Record<string,any>;
  if(refund.provider==="paystack"){
    if(refund.provider_refund_id){
      raw=await providerJson("https://api.paystack.co/refund/"+encodeURIComponent(refund.provider_refund_id),{
        method:"GET",headers:{Authorization:"Bearer "+paystackKey()}
      });
    }else{
      raw=await providerJson("https://api.paystack.co/refund?reference="+encodeURIComponent(refundReference),{
        method:"GET",headers:{Authorization:"Bearer "+paystackKey()}
      });
      if(!Array.isArray(raw.data)||!raw.data.length) throw new Error("Paystack has not returned this refund yet. Try syncing again later.");
      raw={status:raw.status,data:raw.data[0]};
    }
    if(raw.status!==true||!raw.data) throw new Error("Paystack could not verify this refund.");
  }else if(refund.provider==="opay"){
    raw=await opayRequest("refund_status",{country:"NG",reference:refundReference});
    if(raw.code!=="00000"||!raw.data) throw new Error("OPay could not verify this refund.");
  }else{
    throw new Error("Unsupported refund provider.");
  }
  const status=refundStatus(refund.provider,raw);
  const providerRefundId=String(raw?.data?.id??raw?.data?.orderNo??refund.provider_refund_id??"");
  const {data:updated,error:updateError}=await client.rpc("apply_mizpah_web_refund_status",{
    p_refund_reference:refundReference,p_status:status,
    p_provider_refund_id:providerRefundId,p_provider_response:raw
  });
  if(updateError||!updated) throw new Error("The verified refund status could not be recorded safely.");
  return response({success:true,refund_reference:refundReference,status,order_payment_status:updated.order_payment_status});
}
\nasync function webhook(req: Request, provider: string) {
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
      const destination = new URL("/order.html", SITE);
      destination.searchParams.set("payment", "return");
      if (ref) destination.searchParams.set("reference", ref);
      return Response.redirect(destination.toString(), 303);
    }
    if (req.method === "POST" && url.pathname.endsWith("/webhook")) {
      return await webhook(req,String(url.searchParams.get("provider") ?? "").toLowerCase());
    }
    if (req.method === "POST" && url.pathname.endsWith("/reserve")) return await reserveOrder(req);
    if (req.method === "POST" && url.pathname.endsWith("/create")) return await createOrder(req);
    if (req.method === "POST" && url.pathname.endsWith("/resume")) return await resumeSavedOrder(req);
    if (req.method === "POST" && url.pathname.endsWith("/initialize")) return await initialize(req);
    if (req.method === "POST" && url.pathname.endsWith("/refund/create")) return await createRefund(req);
    if (req.method === "POST" && url.pathname.endsWith("/refund/sync")) return await syncRefund(req);
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
