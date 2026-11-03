export type PaystackMode = "test" | "live";

export function paystackMode(configuredMode: string | undefined): PaystackMode {
  const mode = (configuredMode ?? "test").trim().toLowerCase();
  if (mode !== "test" && mode !== "live") {
    throw new Error("PAYSTACK_MODE must be test or live.");
  }
  return mode;
}

export function assertPaystackSecretMatchesMode(
  mode: PaystackMode,
  secret: string,
): void {
  const expectedPrefix = mode === "test" ? "sk_test_" : "sk_live_";
  if (!secret.startsWith(expectedPrefix) || secret.length <= expectedPrefix.length) {
    throw new Error(
      `PAYSTACK_SECRET_KEY must be a valid ${mode} secret key.`,
    );
  }
}