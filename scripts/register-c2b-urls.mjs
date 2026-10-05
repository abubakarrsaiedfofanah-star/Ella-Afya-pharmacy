const required = ["MPESA_SHORTCODE", "MPESA_CONSUMER_KEY", "MPESA_CONSUMER_SECRET", "MPESA_CALLBACK_URL", "MPESA_CALLBACK_SECRET"];
const missing = required.filter(name => !String(process.env[name] || "").trim());
if (missing.length) throw new Error(`Missing environment variables: ${missing.join(", ")}`);
if (process.env.MPESA_CALLBACK_SECRET.length < 32) throw new Error("MPESA_CALLBACK_SECRET must contain at least 32 characters.");

const environment = process.env.MPESA_ENV === "production" ? "production" : "sandbox";
if (environment === "production" && process.env.MPESA_PRODUCTION_REGISTRATION_CONFIRMED !== "YES") {
  throw new Error("Production URL registration is a one-time Daraja operation. Set MPESA_PRODUCTION_REGISTRATION_CONFIRMED=YES only after verifying the PayBill and callback URLs.");
}

const base = environment === "production" ? "https://api.safaricom.co.ke" : "https://sandbox.safaricom.co.ke";
const callback = new URL(process.env.MPESA_CALLBACK_URL);
if (callback.protocol !== "https:" || !callback.pathname.endsWith("/functions/v1/payment-callback")) {
  throw new Error("MPESA_CALLBACK_URL must be an HTTPS Supabase payment-callback function URL.");
}
callback.searchParams.set("token", process.env.MPESA_CALLBACK_SECRET);

const validationUrl = new URL(callback);
validationUrl.searchParams.set("stage", "validation");
const confirmationUrl = new URL(callback);
confirmationUrl.searchParams.set("stage", "confirmation");

const credentials = Buffer.from(`${process.env.MPESA_CONSUMER_KEY}:${process.env.MPESA_CONSUMER_SECRET}`).toString("base64");
const tokenResponse = await fetch(`${base}/oauth/v1/generate?grant_type=client_credentials`, {
  headers: { Authorization: `Basic ${credentials}` }
});
const tokenBody = await tokenResponse.json();
if (!tokenResponse.ok || !tokenBody.access_token) throw new Error(`Daraja access-token request failed (${tokenResponse.status}). Check the app credentials and environment.`);

const registrationResponse = await fetch(`${base}/mpesa/c2b/v1/registerurl`, {
  method: "POST",
  headers: { Authorization: `Bearer ${tokenBody.access_token}`, "Content-Type": "application/json" },
  body: JSON.stringify({
    ShortCode: process.env.MPESA_SHORTCODE,
    ResponseType: "Cancelled",
    ConfirmationURL: confirmationUrl.toString(),
    ValidationURL: validationUrl.toString()
  })
});
const registrationBody = await registrationResponse.json();
if (!registrationResponse.ok || String(registrationBody.ResponseCode) !== "0") {
  throw new Error(`Daraja callback registration failed (${registrationResponse.status}): ${registrationBody.errorMessage || registrationBody.ResponseDescription || JSON.stringify(registrationBody)}`);
}

console.log(`C2B callbacks registered in ${environment}.`);
console.log(`Short code: ${process.env.MPESA_SHORTCODE}`);
console.log(`Response: ${registrationBody.ResponseDescription || "Success"}`);
