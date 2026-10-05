import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const json = (body: unknown, status=200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
function parseTime(v: string | undefined) {
  if (!v || !/^\d{14}$/.test(v)) return null;
  return new Date(`${v.slice(0,4)}-${v.slice(4,6)}-${v.slice(6,8)}T${v.slice(8,10)}:${v.slice(10,12)}:${v.slice(12,14)}+03:00`).toISOString();
}
function safeEqual(a: string,b: string) {
  if (a.length!==b.length) return false;
  let mismatch=0;
  for(let i=0;i<a.length;i++) mismatch|=a.charCodeAt(i)^b.charCodeAt(i);
  return mismatch===0;
}
Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ ResultCode: 1, ResultDesc: "POST required" }, 405);
    const secret=Deno.env.get('MPESA_CALLBACK_SECRET')||'';
    const supplied=new URL(req.url).searchParams.get('token')||'';
    if(secret.length<32||!safeEqual(supplied,secret)) return json({ResultCode:1,ResultDesc:'Unauthorized'},401);
    const payload = await req.json();
    const cb = payload?.Body?.stkCallback;
    if (!cb) {
      const accountReference = payload?.BillRefNumber;
      const amount = Number(payload?.TransAmount || 0);
      const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const stage = new URL(req.url).searchParams.get("stage") || "confirmation";
      if (stage === "validation") {
        if (!accountReference) return json({ ResultCode: "C2B00012", ResultDesc: "Rejected" });
        if (!Number.isFinite(amount) || amount <= 0) return json({ ResultCode: "C2B00013", ResultDesc: "Rejected" });
        const { data: validationCode, error } = await supabase.rpc("validate_mpesa_c2b_account", { p_account_reference: String(accountReference), p_amount: amount });
        if (error) {
          console.error("C2B validation failed", error);
          return json({ ResultCode: "C2B00016", ResultDesc: "Rejected" });
        }
        return json(validationCode === "0" ? { ResultCode: "0", ResultDesc: "Accepted" } : { ResultCode: validationCode || "C2B00016", ResultDesc: "Rejected" });
      }
      if (stage !== "confirmation") return json({ ResultCode: 1, ResultDesc: "Unknown C2B callback stage" }, 400);
      if (!payload?.TransID || !accountReference || !Number.isFinite(amount) || amount <= 0) return json({ ResultCode: 1, ResultDesc: "C2B confirmation missing transaction reference" }, 400);
      const transactionTime = parseTime(payload?.TransTime);
      const msisdn = payload?.MSISDN ? String(payload.MSISDN).replace(/\D/g, "") : "";
      const phone = /^254[17][0-9]{8}$/.test(msisdn) ? msisdn : null;
      const payerName = [payload?.FirstName, payload?.MiddleName, payload?.LastName].filter(Boolean).join(" ");
      const { error } = await supabase.rpc("record_mpesa_c2b_callback", { p_receipt: String(payload.TransID), p_account_reference: String(accountReference), p_amount: amount, p_phone: phone, p_payer_name: payerName || null, p_transaction_time: transactionTime, p_payload: payload });
      if (error) {
        console.error("C2B callback processing failed", error);
        return json({ ResultCode: 1, ResultDesc: "Callback could not be processed" }, 400);
      }
      return json({ ResultCode: 0, ResultDesc: "Accepted" });
    }
    if (!cb?.CheckoutRequestID || typeof cb.ResultCode !== "number") return json({ ResultCode: 1, ResultDesc: "Invalid STK callback" }, 400);
    const metadata = cb.CallbackMetadata?.Item || [];
    const value = (name:string) => metadata.find((x:any)=>x.Name===name)?.Value;
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const resultItems = metadata.reduce((o:any,x:any)=>(o[x.Name]=x.Value,o),{});
    const receipt = value("MpesaReceiptNumber") || null;
    const amount = Number(value("Amount") || 0);
    const phone = value("PhoneNumber") ? String(value("PhoneNumber")) : null;
    const transactionTime = parseTime(value("TransactionDate") ? String(value("TransactionDate")) : undefined);
    const { error } = await supabase.rpc("apply_mpesa_callback", { p_checkout_request_id: cb.CheckoutRequestID, p_merchant_request_id: cb.MerchantRequestID || null, p_result_code: cb.ResultCode, p_result_description: cb.ResultDesc || null, p_receipt: receipt, p_amount: amount, p_phone: phone, p_transaction_time: transactionTime, p_payload: { ...payload, parsed: resultItems } });
    if (error) {
      console.error("STK callback processing failed", error);
      return json({ ResultCode: 1, ResultDesc: "Callback could not be processed" }, 400);
    }
    return json({ ResultCode: 0, ResultDesc: "Accepted" });
  } catch (e) {
    console.error("M-Pesa callback failed", e);
    return json({ ResultCode: 1, ResultDesc: "Callback could not be processed" }, 400);
  }
});
