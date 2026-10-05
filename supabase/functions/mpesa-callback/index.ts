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
      const saleRef = payload?.BillRefNumber || payload?.ThirdPartyTransID;
      const amount = Number(payload?.TransAmount || 0);
      if (!payload?.TransID || !saleRef || !amount) return json({ ResultCode: 1, ResultDesc: "C2B callback missing transaction reference" }, 400);
      const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const transactionTime = parseTime(payload?.TransTime);
      const { error } = await supabase.rpc("apply_mpesa_c2b_callback", { p_receipt: String(payload.TransID), p_sale_number: String(saleRef), p_amount: amount, p_phone: payload.MSISDN ? String(payload.MSISDN).replace(/\D/g, "") : null, p_transaction_time: transactionTime, p_payload: payload });
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
