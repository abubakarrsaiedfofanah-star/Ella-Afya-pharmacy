import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);
const $ = (selector) => document.querySelector(selector);
const form = $('#payrollForm');
const rows = $('#rows');
const formMsg = $('#formMsg');
const listMsg = $('#listMsg');
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const money = (value, currency = 'KES') => new Intl.NumberFormat(undefined, { style: 'currency', currency, maximumFractionDigits: 2 }).format(Number(value || 0));

async function printPayroll(payment, popup = window.open('', '_blank', 'width=460,height=720')) {
  if (!popup) { formMsg.textContent = 'Allow pop-ups to print the payroll receipt.'; return; }
  const { data, error } = await supabase.storage.from('receipt-signatures').createSignedUrl(payment.signature_path, 300);
  if (error || !data?.signedUrl) { popup.close(); formMsg.textContent = 'The saved admin signature could not be loaded.'; return; }
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(payment.payroll_number)}</title><style>body{font:14px Arial;max-width:380px;margin:24px auto;color:#111}h1{text-align:center;font-size:20px}.muted{text-align:center;color:#555}.line{display:flex;justify-content:space-between;gap:16px;padding:9px 0;border-bottom:1px solid #ddd}.signature{text-align:center;margin-top:28px}.signature img{display:block;max-width:190px;max-height:75px;object-fit:contain;margin:0 auto 5px}</style></head><body><h1>Payroll payment receipt</h1><p class="muted">${escapeHtml(payment.payroll_number)}</p><div class="line"><span>Staff member</span><b>${escapeHtml(payment.staff_name)}</b></div><div class="line"><span>Pay month</span><b>${escapeHtml(payment.pay_month.slice(0,7))}</b></div><div class="line"><span>Amount paid</span><b>${escapeHtml(money(payment.amount,payment.currency_code))}</b></div><div class="line"><span>Method</span><b>${escapeHtml(payment.payment_method)}</b></div>${payment.payment_reference?`<div class="line"><span>Reference</span><b>${escapeHtml(payment.payment_reference)}</b></div>`:''}<div class="line"><span>Paid by</span><b>${escapeHtml(payment.paid_by_name)}</b></div><div class="line"><span>Date</span><b>${escapeHtml(new Date(payment.paid_at).toLocaleString())}</b></div><div class="signature"><img src="${escapeHtml(data.signedUrl)}" alt="Authorized administrator signature"><div>Authorized by <b>${escapeHtml(payment.signature_name)}</b></div></div><script>addEventListener('load',()=>{const image=document.querySelector('img');image.decode().then(()=>print()).catch(()=>document.body.insertAdjacentText('beforeend','Signature failed to load; receipt not printed.'))},{once:true})</script></body></html>`;
  popup.document.open(); popup.document.write(html); popup.document.close();
}

async function loadHistory() {
  listMsg.textContent = 'Loading payroll records…';
  const { data, error } = await supabase.from('payroll_payments').select('*').order('pay_month', { ascending: false }).order('paid_at', { ascending: false }).limit(300);
  if (error) { rows.replaceChildren(); listMsg.textContent = `Payroll could not be loaded: ${error.message}`; return; }
  listMsg.textContent = `${data?.length || 0} payroll payment${data?.length === 1 ? '' : 's'} recorded.`;
  rows.innerHTML = (data || []).map((item) => `<tr><td>${escapeHtml(item.payroll_number)}</td><td>${escapeHtml(item.staff_name)}</td><td>${escapeHtml(item.pay_month.slice(0,7))}</td><td>${escapeHtml(money(item.amount,item.currency_code))}</td><td>${escapeHtml(item.payment_method)}</td><td>${escapeHtml(item.paid_by_name)}</td><td>${escapeHtml(new Date(item.paid_at).toLocaleString())}</td><td><button class="btn secondary" data-print="${escapeHtml(item.id)}" type="button">Print</button></td></tr>`).join('') || '<tr><td colspan="8" class="muted">No payroll recorded yet.</td></tr>';
  rows.querySelectorAll('[data-print]').forEach((button) => button.addEventListener('click', async () => {
    const payment = (data || []).find((item) => item.id === button.dataset.print);
    if (payment) await printPayroll(payment);
  }));
}

const [{ data: staff, error: staffError }, { data: settings, error: settingsError }] = await Promise.all([
  supabase.from('profiles').select('id,full_name,active').eq('role', 'seller').order('full_name'),
  supabase.from('pharmacy_settings').select('receipt_signature_path,receipt_signature_name').eq('id', true).single(),
]);
if (staffError) formMsg.textContent = `Staff list could not be loaded: ${staffError.message}`;
else $('#staff').innerHTML = '<option value="">Choose staff member</option>' + (staff || []).map((person) => `<option value="${escapeHtml(person.id)}">${escapeHtml(person.full_name)}${person.active ? '' : ' (inactive)'}</option>`).join('');
if (settingsError || !settings?.receipt_signature_path || !settings?.receipt_signature_name) {
  formMsg.textContent = 'Save the admin receipt signature in Pharmacy Settings before recording payroll.';
  $('#recordPayment').disabled = true;
}
$('#payMonth').value = new Date().toISOString().slice(0, 7);
$('#method').addEventListener('change', () => { $('#reference').required = ['mpesa', 'bank'].includes($('#method').value); });
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = $('#recordPayment'); button.disabled = true; formMsg.textContent = 'Recording payment…';
  const receiptWindow = window.open('', '_blank', 'width=460,height=720');
  if (receiptWindow) { receiptWindow.document.write('<!doctype html><title>Preparing payroll receipt</title><p>Preparing signed payroll receipt…</p>'); }
  const month = $('#payMonth').value;
  const { data, error } = await supabase.rpc('admin_record_staff_payroll', {
    p_staff_id: $('#staff').value,
    p_pay_month: `${month}-01`,
    p_amount: Number($('#amount').value),
    p_payment_method: $('#method').value,
    p_payment_reference: $('#reference').value.trim() || null,
    p_notes: $('#notes').value.trim() || null,
  });
  button.disabled = false;
  if (error) { receiptWindow?.close(); formMsg.textContent = error.message.includes('payroll_payments_staff_id_pay_month_key') ? 'A payroll payment is already recorded for this staff member and month.' : error.message; return; }
  formMsg.textContent = `Recorded ${data.payroll_number}. Preparing signed receipt…`;
  await printPayroll(data, receiptWindow || undefined);
  form.reset(); $('#payMonth').value = new Date().toISOString().slice(0, 7); $('#reference').required = false;
  await loadHistory();
});
$('#refresh').addEventListener('click', loadHistory);
loadHistory();
