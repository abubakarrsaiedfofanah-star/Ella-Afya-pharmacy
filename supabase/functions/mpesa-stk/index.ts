import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function token(base: string, key: string, secret: string) {
  const basic = btoa(`${key}:${secret}`);
  const r = await fetch(`${base}/oauth/v1/generate?grant_type=client_credentials`, { headers: { Authorization: `Basic ${basic}` } });
  if (!r.ok) throw new Error(`M-Pesa auth failed: ${r.status}`);
  return (await r.json()).access_token;
}

function timestamp() {
  const parts = new Intl.DateTimeFormat("en-GB", { timeZone: "Africa/Nairobi", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }).formatToParts(new Date());
  const v:any = Object.fromEntries(parts.filter(x => x.type !== "literal").map(x => [x.type, x.value]));
  return `${v.year}${v.month}${v.day}${v.hour}${v.minute}${v.second}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let adminClient: ReturnType<typeof createClient> | null = null;
  let paymentRecordId: string | null = null;
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const shortcode = Deno.env.get("MPESA_SHORTCODE") || "";
    const passkey = Deno.env.get("MPESA_PASSKEY") || "";
    const key = Deno.env.get("MPESA_CONSUMER_KEY") || "";
    const secret = Deno.env.get("MPESA_CONSUMER_SECRET") || "";
    const callbackBase = Deno.env.get("MPESA_CALLBACK_URL") || "";
    const callbackSecret = Deno.env.get("MPESA_CALLBACK_SECRET") || "";
    if (!shortcode || !passkey || !key || !secret || !callbackBase || callbackSecret.length < 32) {
      return json({ error: "M-Pesa payment service is not configured." }, 503);
    }
    const callbackUrl = new URL(callbackBase);
    if (callbackUrl.protocol !== "https:") return json({ error: "M-Pesa callback URL must use HTTPS." }, 503);
    callbackUrl.searchParams.set("token", callbackSecret);

    const auth = req.headers.get("Authorization");
    if (!auth) return json({ error: "Authorization required" }, 401);
    const userClient = createClient(supabaseUrl, anon, { global: { headers: { Authorization: auth } } });
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const body = await req.json();
    if (!body || typeof body.sale_id !== "string" || typeof body.phone !== "string") {
      return json({ error: "Sale and phone details are required." }, 400);
    }
    const normalizedPhone = body.phone.replace(/\D/g, "").replace(/^0/, "254");
    if (!/^254[17]\d{8}$/.test(normalizedPhone)) return json({ error: "Enter a valid Kenyan phone number." }, 400);

    adminClient = createClient(supabaseUrl, service, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: paymentId, error: prepError } = await userClient.rpc("prepare_mpesa_payment", { p_sale_id: body.sale_id, p_phone: normalizedPhone });
    if (prepError || !paymentId) return json({ error: prepError?.message || "Could not prepare M-Pesa payment." }, 400);
    paymentRecordId = paymentId;

    const base = Deno.env.get("MPESA_ENV") === "production" ? "https://api.safaricom.co.ke" : "https://sandbox.safaricom.co.ke";
    const { data: payment, error: paymentError } = await adminClient.from("payments").select("id,sale_id,amount,phone_number").eq("id", paymentId).single();
    if (paymentError || !payment) throw new Error("Prepared M-Pesa payment could not be loaded");
    const paymentAmount = Number(payment.amount);
    if (!Number.isSafeInteger(paymentAmount) || paymentAmount <= 0) throw new Error("M-Pesa amount must be a positive whole shilling amount");
    const { data: sale, error: saleError } = await adminClient.from("sales").select("sale_number,total_amount").eq("id", body.sale_id).single();
    if (saleError || !sale) throw new Error("Sale could not be loaded");

    const ts = timestamp();
    const password = btoa(`${shortcode}${passkey}${ts}`);
    const access = await token(base, key, secret);
    const payload = { BusinessShortCode: shortcode, Password: password, Timestamp: ts, TransactionType: Deno.env.get("MPESA_TRANSACTION_TYPE") || "CustomerBuyGoodsOnline", Amount: paymentAmount, PartyA: normalizedPhone, PartyB: shortcode, PhoneNumber: normalizedPhone, CallBackURL: callbackUrl.toString(), AccountReference: sale.sale_number, TransactionDesc: `Pharmacy sale ${sale.sale_number}` };
    const r = await fetch(`${base}/mpesa/stkpush/v1/processrequest`, { method: "POST", headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    const result = await r.json();
    if (!r.ok || result.ResponseCode !== "0") {
      const { error: updateError } = await adminClient.from("payments").update({ status: "failed", callback_payload: result }).eq("id", payment.id).eq("status", "pending");
      if (updateError) throw updateError;
      return json({ error: "M-Pesa STK request failed. Please try again." }, 502);
    }
    const { error: updateError } = await adminClient.from("payments").update({ merchant_request_id: result.MerchantRequestID, checkout_request_id: result.CheckoutRequestID }).eq("id", payment.id);
    if (updateError) throw updateError;
    return json({ ok: true, payment_id: payment.id, checkout_request_id: result.CheckoutRequestID, customer_message: result.CustomerMessage });
  } catch (e) {
    if (adminClient && paymentRecordId) {
      try {
        const { error } = await adminClient.from("payments").update({ status: "failed" }).eq("id", paymentRecordId).eq("status", "pending");
        if (error) console.error("Failed to mark M-Pesa payment failed", error);
      } catch (cleanupError) {
        console.error("Failed to clean up pending M-Pesa payment", cleanupError);
      }
    }
    console.error("M-Pesa STK request failed", e);
    return json({ error: "M-Pesa payment could not be started. Please try again." }, 502);
  }
});
