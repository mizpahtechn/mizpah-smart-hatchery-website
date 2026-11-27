import {
  opayMode,
  assertOpayCredentialsMatchMode,
  serializeOpayPayload,
  parseOpayInitializationResponse,
  parseOpayStatusResponse,
} from "./opay_checkout.ts";
import {
  paystackMode,
  assertPaystackSecretMatchesMode,
} from "./paystack_checkout.ts";

Deno.test("OPay mode must be explicitly configured", () => {
  let failed = false;
  try { opayMode(undefined); } catch { failed = true; }
  if (!failed) throw new Error("Missing OPay mode should be rejected.");
  if (opayMode("TEST") !== "test") throw new Error("Test mode should normalise.");
});

Deno.test("OPay credentials must match configured mode", () => {
  assertOpayCredentialsMatchMode("test", "test", "public", "secret", "merchant");
  let failed = false;
  try { assertOpayCredentialsMatchMode("live", "test", "public", "secret", "merchant"); }
  catch { failed = true; }
  if (!failed) throw new Error("Mismatched OPay credential mode should be rejected.");
});

Deno.test("OPay payload serialization sorts keys for deterministic signatures", () => {
  const actual = serializeOpayPayload({ z: 1, a: { y: 2, b: 3 } });
  if (actual !== '{"a":{"b":3,"y":2},"z":1}') {
    throw new Error("Unexpected canonical OPay payload: " + actual);
  }
});

Deno.test("OPay initialization response accepts only the test cashier host", () => {
  const parsed = parseOpayInitializationResponse({
    code: "00000",
    data: { cashierUrl: "https://sandboxcashier.opaycheckout.com/checkout/abc", orderNo: "OP-123" },
  }, "test");
  if (parsed.orderNo !== "OP-123") throw new Error("OPay order number was not returned.");
  let failed = false;
  try {
    parseOpayInitializationResponse({
      code: "00000",
      data: { cashierUrl: "https://evil.example/checkout", orderNo: "OP-123" },
    }, "test");
  } catch { failed = true; }
  if (!failed) throw new Error("Unexpected OPay cashier host should be rejected.");
});

Deno.test("OPay status response verifies reference, amount and NGN currency", () => {
  const parsed = parseOpayStatusResponse({
    code: "00000",
    data: {
      reference: "KCREFERENCE123456",
      status: "SUCCESS",
      amount: { total: 12500, currency: "NGN" },
      orderNo: "OP-123",
    },
  }, "KCREFERENCE123456", 12500);
  if (parsed.status !== "SUCCESS") throw new Error("OPay success status was not parsed.");
  let failed = false;
  try {
    parseOpayStatusResponse({
      code: "00000",
      data: { reference: "KCREFERENCE123456", status: "SUCCESS", amount: { total: 12499, currency: "NGN" } },
    }, "KCREFERENCE123456", 12500);
  } catch { failed = true; }
  if (!failed) throw new Error("Mismatched OPay amount should be rejected.");
});

Deno.test("Paystack mode and secret-key prefix must match", () => {
  if (paystackMode(undefined) !== "test") throw new Error("Paystack default mode should be test.");
  assertPaystackSecretMatchesMode("test", "sk_test_example_secret");
  let failed = false;
  try { assertPaystackSecretMatchesMode("live", "sk_test_example_secret"); }
  catch { failed = true; }
  if (!failed) throw new Error("Mismatched Paystack key should be rejected.");
});
