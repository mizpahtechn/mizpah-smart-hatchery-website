export type OpayMode = "test" | "live";

const OPAY_TEST_URL = "https://testapi.opaycheckout.com";
const OPAY_LIVE_URL = "https://liveapi.opaycheckout.com";
const OPAY_TEST_CASHIER_HOST = "sandboxcashier.opaycheckout.com";
const OPAY_LIVE_CASHIER_HOST = "cashier.opaycheckout.com";

export class OpayInitializationError extends Error {
  readonly providerCode?: string;

  constructor(
    message: string,
    providerCode?: string,
  ) {
    super(message);
    this.providerCode = providerCode;
  }
}

export function opayMode(configuredMode: string | undefined): OpayMode {
  const mode = configuredMode?.trim().toLowerCase();
  if (mode !== "test" && mode !== "live") {
    throw new Error("OPAY_MODE must be explicitly set to test or live.");
  }
  return mode;
}

export function opayBaseUrl(mode: OpayMode): string {
  return mode === "live" ? OPAY_LIVE_URL : OPAY_TEST_URL;
}

export function assertOpayCredentialsMatchMode(
  mode: OpayMode,
  credentialMode: string | undefined,
  publicKey: string,
  secretKey: string,
  merchantId: string,
): void {
  if (
    !publicKey.trim() ||
    !secretKey.trim() ||
    !merchantId.trim()
  ) {
    throw new Error(
      "OPay credentials are not configured on the secure backend.",
    );
  }

  if (credentialMode?.trim().toLowerCase() !== mode) {
    throw new Error(
      "OPAY_CREDENTIALS_MODE must match OPAY_MODE.",
    );
  }
}

function sortJsonValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJsonValue);
  if (!value || typeof value !== "object") return value;

  const sorted: Record<string, unknown> = {};
  for (const key of Object.keys(value).sort()) {
    sorted[key] = sortJsonValue((value as Record<string, unknown>)[key]);
  }
  return sorted;
}

export function serializeOpayPayload(payload: Record<string, unknown>): string {
  return JSON.stringify(sortJsonValue(payload));
}

export function opayCashierCreateHeaders(
  publicKey: string,
  merchantId: string,
): Record<string, string> {
  const key = publicKey.trim();
  const merchant = merchantId.trim();
  if (!key || !merchant) {
    throw new Error("OPay cashier credentials are not configured.");
  }
  return {
    Authorization: `Bearer ${key}`,
    MerchantId: merchant,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
}

export function opayStatusHeaders(
  signature: string,
  merchantId: string,
): Record<string, string> {
  const signedPayload = signature.trim();
  const merchant = merchantId.trim();
  if (!signedPayload || !merchant) {
    throw new Error("OPay status credentials are not configured.");
  }
  return {
    Authorization: `Bearer ${signedPayload}`,
    MerchantId: merchant,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
}

export async function signSerializedOpayPayload(
  serializedPayload: string,
  secretKey: string,
): Promise<string> {
  if (!secretKey.trim()) {
    throw new Error("OPay signing credentials are not configured.");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secretKey),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(serializedPayload),
  );
  return Array.from(new Uint8Array(signature)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

export function signOpayPayload(
  payload: Record<string, unknown>,
  secretKey: string,
): Promise<string> {
  return signSerializedOpayPayload(serializeOpayPayload(payload), secretKey);
}

export function safeOpayProviderCode(value: unknown): string | undefined {
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const code = String(value).trim();
  return /^[A-Za-z0-9_-]{1,40}$/.test(code) ? code : undefined;
}

export function parseOpayInitializationResponse(
  result: unknown,
  mode: OpayMode,
): { cashierUrl: string; orderNo: string | null } {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new OpayInitializationError(
      "OPay returned an invalid checkout initialization response.",
    );
  }

  const response = result as Record<string, unknown>;
  if (response.code !== "00000") {
    const code = safeOpayProviderCode(response.code);
    throw new OpayInitializationError(
      code
        ? `OPay rejected checkout initialization (provider code ${code}).`
        : "OPay rejected checkout initialization.",
      code,
    );
  }

  const data = response.data;
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new OpayInitializationError(
      "OPay returned an invalid checkout initialization response.",
    );
  }

  const cashierUrl = (data as Record<string, unknown>).cashierUrl;
  if (typeof cashierUrl !== "string" || !cashierUrl.trim()) {
    throw new OpayInitializationError("OPay did not return a cashier URL.");
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(cashierUrl);
  } catch {
    throw new OpayInitializationError(
      "OPay returned an invalid cashier URL.",
    );
  }
  const expectedCashierHost = mode === "test"
    ? OPAY_TEST_CASHIER_HOST
    : OPAY_LIVE_CASHIER_HOST;
  if (
    parsedUrl.protocol !== "https:" ||
    parsedUrl.hostname.toLowerCase() !== expectedCashierHost ||
    parsedUrl.username ||
    parsedUrl.password
  ) {
    throw new OpayInitializationError(
      "OPay returned an invalid cashier URL.",
    );
  }

  const orderNo = (data as Record<string, unknown>).orderNo;
  return {
    cashierUrl: parsedUrl.toString(),
    orderNo: typeof orderNo === "string" && orderNo.trim()
      ? orderNo.trim()
      : null,
  };
}

export function parseOpayStatusResponse(
  result: unknown,
  expectedReference: string,
  expectedAmountMinor: number,
): { status: string; orderNo: string | null } {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error("OPay returned an invalid payment verification response.");
  }
  const response = result as Record<string, unknown>;
  if (response.code !== "00000") {
    const code = safeOpayProviderCode(response.code);
    throw new Error(
      code
        ? `OPay could not verify this payment (provider code ${code}).`
        : "OPay could not verify this payment.",
    );
  }

  const data = response.data;
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new Error("OPay returned an invalid payment verification response.");
  }
  const transaction = data as Record<string, unknown>;
  if (
    typeof transaction.reference !== "string" ||
    transaction.reference.trim() !== expectedReference
  ) {
    throw new Error("OPay returned a different or missing payment reference.");
  }

  const amount = (transaction.amount && typeof transaction.amount === "object")
    ? transaction.amount as Record<string, unknown>
    : {};
  const amountValue = amount.total;
  const amountMinor = typeof amountValue === "number" ||
      typeof amountValue === "string"
    ? Number(amountValue)
    : Number.NaN;
  if (
    !Number.isSafeInteger(amountMinor) || amountMinor !== expectedAmountMinor
  ) {
    throw new Error("OPay returned an invalid or mismatched payment amount.");
  }
  if (
    typeof amount.currency !== "string" ||
    amount.currency.trim().toUpperCase() !== "NGN"
  ) {
    throw new Error(
      "OPay returned a currency that does not match this payment.",
    );
  }

  const statusValue = transaction.status ?? transaction.orderStatus;
  const status = typeof statusValue === "string"
    ? statusValue.trim().toUpperCase()
    : "";
  if (!status) {
    throw new Error("OPay returned an invalid payment status.");
  }
  const orderNo = transaction.orderNo;
  return {
    status,
    orderNo: typeof orderNo === "string" && orderNo.trim()
      ? orderNo.trim()
      : null,
  };
}
