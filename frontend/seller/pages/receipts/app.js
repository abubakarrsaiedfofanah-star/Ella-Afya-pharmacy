import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

const session = await requireUser(['seller']);
const $ = (selector) => document.querySelector(selector);
const rows = $('#rows');
const message = $('#msg');
const pageSize = 100;
let page = 0;
let visibleSales = [];
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const money = (value) => `KSh ${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;

function dateBounds(value) {
  if (!value) return null;
  const start = new Date(`${value}T00:00:00`);
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { start: start.toISOString(), end: end.toISOString() };
}

async function loadReceipts() {
  rows.innerHTML = '<tr><td colspan="6">Loading receipts…</td></tr>';
  message.textContent = '';
  let query = supabase.from('sales')
    .select('id,sale_number,total_amount,status,created_at,customer_name,customer_phone', { count: 'exact' })
    .eq('seller_id', session.user.id)
    .order('created_at', { ascending: false }).order('id', { ascending: false });
  const search = $('#receiptSearch').value.trim().replace(/[^\p{L}\p{N}+\- ]/gu, '').slice(0, 80);
  if (search) query = query.or(`sale_number.ilike.%${search}%,customer_name.ilike.%${search}%,customer_phone.ilike.%${search}%`);
  const bounds = dateBounds($('#receiptDate').value);
  if (bounds) query = query.gte('created_at', bounds.start).lt('created_at', bounds.end);
  const { data, error, count } = await query.range(page * pageSize, (page + 1) * pageSize - 1);
  if (error) { rows.replaceChildren(); message.textContent = 'Receipts could not be loaded. Please try again.'; return; }
  visibleSales = data || [];
  const { data: claimData } = await supabase.rpc('seller_manual_mpesa_claim_status', { p_sale_ids: visibleSales.map((sale) => sale.id) });
  const claimBySale = new Map((claimData || []).map((claim) => [claim.sale_id, claim.claim_status]));
  rows.innerHTML = visibleSales.map((sale) => {
    const canIssue = sale.status === 'paid';
    const claimStatus = claimBySale.get(sale.id);
    const actions = canIssue
      ? `<button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="print" type="button">Print</button>${sale.customer_phone ? ` <button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="sms" type="button">SMS</button>` : ''} <button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="refund" type="button">Refund</button>`
      : sale.status === 'pending_payment'
        ? `${claimStatus === 'pending' ? '<small>Waiting for statement match</small>' : `<a class="btn secondary" href="/seller/pages/pos/?resume=${encodeURIComponent(sale.id)}">${claimStatus === 'rejected' ? 'Retry payment' : 'Resume payment'}</a>`} <button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="cancel_sale" type="button">Cancel</button>` : '';
    const buyer = [sale.customer_name, sale.customer_phone].filter(Boolean).map(escapeHtml).join(' · ') || '—';
    const statusLabel = sale.status === 'pending_payment' && claimStatus === 'pending' ? 'awaiting statement' : sale.status === 'pending_payment' && claimStatus === 'rejected' ? 'payment rejected' : sale.status.replaceAll('_', ' ');
    const statusCell=sale.status==='pending_payment'
      ? `<a class="btn secondary" href="/seller/pages/pos/?resume=${encodeURIComponent(sale.id)}">${escapeHtml(statusLabel)} · Continue</a>`
      : escapeHtml(statusLabel);
    return `<tr><td>${escapeHtml(sale.sale_number)}</td><td>${buyer}</td><td>${money(sale.total_amount)}</td><td>${statusCell}</td><td>${escapeHtml(new Date(sale.created_at).toLocaleString())}</td><td class="no-print">${actions}</td></tr>`;
  }).join('') || '<tr><td colspan="6" class="muted">No receipts match.</td></tr>';
  const pages = Math.max(1, Math.ceil((count || 0) / pageSize));
  $('#pageInfo').textContent = `Page ${page + 1} of ${pages} · ${count || 0} receipts`;
  $('#previousPage').disabled = page === 0;
  $('#nextPage').disabled = page + 1 >= pages;
}

async function receiptData(id) {
  const [saleResult, itemResult, paymentResult, settingResult] = await Promise.all([
    supabase.from('sales').select('sale_number,total_amount,created_at,status,customer_name,customer_phone,authorized_signature_path,authorized_signature_name,signature_applied_at').eq('id', id).single(),
    supabase.from('sale_items').select('quantity,unit_price,total,medicines(name,strength)').eq('sale_id', id),
    supabase.from('payments').select('amount,method,status,cash_tendered,change_due').eq('sale_id', id).eq('status', 'paid'),
    supabase.from('pharmacy_settings').select('pharmacy_name,address,phone,receipt_footer').eq('id', true).maybeSingle(),
  ]);
  const error = saleResult.error || itemResult.error || paymentResult.error || settingResult.error;
  if (error) throw error;
  return { sale: saleResult.data, items: itemResult.data || [], payments: paymentResult.data || [], settings: settingResult.data };
}

async function printReceipt(id) {
  const printWindow = window.open('', '_blank', 'width=420,height=700');
  if (!printWindow) { message.textContent = 'Allow pop-ups to print receipts.'; return; }
  printWindow.document.write('<!doctype html><title>Preparing receipt</title><p>Preparing receipt…</p>');
  try {
    const { sale, items, payments, settings } = await receiptData(id);
    if (!sale || sale.status !== 'paid') throw new Error('Only completed sales can be receipted.');
    if (!sale.authorized_signature_path || !sale.authorized_signature_name || !sale.signature_applied_at) throw new Error('This receipt needs an Admin signature.');
    const { data: signature, error } = await supabase.storage.from('receipt-signatures').createSignedUrl(sale.authorized_signature_path, 300);
    if (error || !signature?.signedUrl) throw new Error('The receipt signature is unavailable.');
    const units = items.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
    const itemRows = items.map((item) => `<div class="line"><span>${escapeHtml(item.medicines?.name || 'Medicine')} ${escapeHtml(item.medicines?.strength || '')}<br>${money(item.unit_price)} × ${Number(item.quantity || 0)}</span><b>${money(item.total)}</b></div>`).join('');
    const paid = payments.reduce((sum, item) => sum + Math.round(Number(item.amount || 0) * 100), 0) / 100;
    const tendered = payments.reduce((sum, item) => sum + Math.round(Number(item.cash_tendered || 0) * 100), 0) / 100;
    const change = payments.reduce((sum, item) => sum + Math.round(Number(item.change_due || 0) * 100), 0) / 100;
    const methods = [...new Set(payments.map((item) => item.method))].join(', ');
    const buyer = [sale.customer_name, sale.customer_phone].filter(Boolean).map(escapeHtml).join(' · ');
    const verifyUrl = `${location.origin}/verify/?receipt=${encodeURIComponent(sale.sale_number)}`;
    const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(sale.sale_number)}</title><style>body{font:13px Arial;max-width:360px;margin:20px auto;color:#111}h2{text-align:center;margin:0 0 4px}.center{text-align:center;color:#555}.line{display:flex;justify-content:space-between;gap:12px;border-bottom:1px dashed #bbb;padding:7px 0}.total{font-size:18px;font-weight:800;margin-top:10px}.foot{text-align:center;margin-top:18px;font-size:11px;color:#555}.signature{margin:20px 0 8px;text-align:center;border-top:1px solid #bbb;padding-top:12px}.signature img{display:block;max-width:190px;max-height:76px;object-fit:contain;margin:0 auto 5px}.verify{font-size:10px;overflow-wrap:anywhere;text-align:center}</style></head><body><h2>${escapeHtml(settings?.pharmacy_name || 'Pharmacy')}</h2><div class="center">${escapeHtml(settings?.address || '')}<br>${escapeHtml(settings?.phone || '')}</div><hr><div>Receipt: <b>${escapeHtml(sale.sale_number)}</b><br>${escapeHtml(new Date(sale.created_at).toLocaleString())}${buyer ? `<br>Buyer: ${buyer}` : ''}</div>${itemRows}<div class="line"><span>Total units</span><b>${units}</b></div><div class="line"><span>Payment</span><b>${escapeHtml(methods || '—')}</b></div><div class="line"><span>Paid</span><b>${money(paid)}</b></div>${tendered ? `<div class="line"><span>Cash received</span><b>${money(tendered)}</b></div><div class="line"><span>Change</span><b>${money(change)}</b></div>` : ''}<div class="line total"><span>TOTAL</span><span>${money(sale.total_amount)}</span></div><div class="foot">${escapeHtml(settings?.receipt_footer || 'Thank you for choosing our pharmacy.')}</div><div class="signature"><img src="${escapeHtml(signature.signedUrl)}" alt="Authorized administrator signature"><div>Authorized by <b>${escapeHtml(sale.authorized_signature_name)}</b></div></div><div class="verify">Verify receipt: ${escapeHtml(verifyUrl)}</div></body></html>`;
    printWindow.document.open(); printWindow.document.write(html); printWindow.document.close();
    printWindow.addEventListener('load', () => { const image = printWindow.document.querySelector('img'); image.decode().then(() => printWindow.print()).catch(() => { message.textContent = 'The signature could not load; the receipt was not printed.'; }); }, { once: true });
  } catch (error) { printWindow.close(); message.textContent = error.message || 'The receipt could not be prepared.'; }
}

async function sendSms(id) {
  const sale = visibleSales.find((item) => item.id === id);
  if (!sale?.customer_phone || sale.status !== 'paid') return;
  const verifyUrl = `${location.origin}/verify/?receipt=${encodeURIComponent(sale.sale_number)}`;
  const body = `Ella Afya Pharmacy receipt ${sale.sale_number}. Total ${money(sale.total_amount)}. View receipt: ${verifyUrl}`;
  if (!/Android|iPhone|iPad|iPod/i.test(navigator.userAgent)) { message.textContent = 'Open Receipts on a phone with a messaging app to send this SMS.'; return; }
  const separator = /iPhone|iPad|iPod/i.test(navigator.userAgent) ? '&' : '?';
  location.href = `sms:${encodeURIComponent(sale.customer_phone)}${separator}body=${encodeURIComponent(body)}`;
}

rows.addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;
  if (button.dataset.action === 'print') { await printReceipt(button.dataset.id); return; }
  if (button.dataset.action === 'sms') { await sendSms(button.dataset.id); return; }
  const reason = prompt('Reason for this request:');
  if (!reason?.trim()) return;
  button.disabled = true;
  const { error } = await supabase.rpc('request_action', { p_action_type: button.dataset.action, p_target_id: button.dataset.id, p_reason: reason.trim() });
  message.textContent = error ? 'Your request could not be submitted.' : 'Request sent to admin.';
  if (!error) await loadReceipts(); else button.disabled = false;
});

$('#receiptFilters').addEventListener('submit', (event) => { event.preventDefault(); page = 0; loadReceipts(); });
$('#clearFilters').addEventListener('click', () => { $('#receiptSearch').value = ''; $('#receiptDate').value = ''; page = 0; loadReceipts(); });
$('#previousPage').addEventListener('click', () => { if (page) { page--; loadReceipts(); } });
$('#nextPage').addEventListener('click', () => { page++; loadReceipts(); });
$('#printPage').addEventListener('click', () => window.print());
loadReceipts();
