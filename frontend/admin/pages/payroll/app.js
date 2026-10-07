import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);
const $ = (selector) => document.querySelector(selector);
const form = $('#payrollForm');
const rows = $('#rows');
const formMsg = $('#formMsg');
const listMsg = $('#listMsg');
const calculationBox = $('#payrollCalculation');
const amountInput = $('#amountPaid');
const calcFields = ['#basePay', '#additions', '#deductions'];
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const money = (value, currency = 'KES') => new Intl.NumberFormat(undefined, { style: 'currency', currency, maximumFractionDigits: 2 }).format(Number(value || 0));
let calculation = null;
let signatureReady = false;
let historyPage = 0;
let historyCount = 0;
let calculationRequest = 0;
let calculationTimer;
const historyPageSize = 100;
let staffAccounts = [];

function monthDate() { return $('#payMonth').value ? `${$('#payMonth').value}-01` : null; }
function calculationArgs() {
  return {
    p_staff_id: $('#staff').value,
    p_pay_month: monthDate(),
    p_base_pay: Number($('#basePay').value || 0),
    p_additions: Number($('#additions').value || 0),
    p_deductions: Number($('#deductions').value || 0),
  };
}

function showCalculation(item) {
  calculation = item;
  calculationBox.hidden = !item;
  if (!item) return;
  const currency = item.currency_code || 'KES';
  $('#calculationSummary').innerHTML = `<article><span>Base pay</span><strong>${escapeHtml(money(item.base_pay,currency))}</strong></article><article><span>Additions</span><strong>${escapeHtml(money(item.additions,currency))}</strong></article><article><span>Deductions</span><strong>${escapeHtml(money(item.deductions,currency))}</strong></article><article><span>Gross pay</span><strong>${escapeHtml(money(item.gross_pay,currency))}</strong></article><article><span>Net pay</span><strong>${escapeHtml(money(item.net_pay,currency))}</strong></article><article><span>Paid to date</span><strong>${escapeHtml(money(item.paid,currency))}</strong></article><article><span>Remaining balance</span><strong>${escapeHtml(money(item.balance,currency))}</strong></article>`;
  $('#periodLocked').textContent = item.period_saved ? 'Saved pay calculation. Use these figures for all installments in this period.' : 'Preview only. Save this calculation before recording a payment.';
  $('#saveCalculation').disabled = item.period_saved;
  for (const selector of calcFields) $(selector).disabled = Boolean(item.period_saved);
  updatePaymentButton();
}

function updatePaymentButton() {
  const amount = Number(amountInput.value);
  $('#recordPayment').disabled = !signatureReady || !calculation || !calculation.period_saved || !Number.isFinite(amount) || amount <= 0 || amount > Number(calculation.balance || 0);
}

async function refreshCalculation() {
  const requestId = ++calculationRequest;
  if (!$('#staff').value || !monthDate() || $('#basePay').value === '') {
    showCalculation(null); $('#saveCalculation').disabled = true; $('#recordPayment').disabled = true; return null;
  }
  $('#saveCalculation').disabled = true; $('#recordPayment').disabled = true;
  formMsg.textContent = 'Calculating pay…';
  const { data, error } = await supabase.rpc('admin_calculate_staff_payroll', calculationArgs());
  if (requestId !== calculationRequest) return null;
  if (error) { calculation = null; calculationBox.hidden = true; formMsg.textContent = error.message; return null; }
  if (data.period_saved) {
    $('#basePay').value = Number(data.base_pay).toFixed(2);
    $('#additions').value = Number(data.additions).toFixed(2);
    $('#deductions').value = Number(data.deductions).toFixed(2);
  }
  showCalculation(data);
  formMsg.textContent = data.period_saved ? 'Loaded the saved calculation for this staff member and month.' : 'Calculation preview updated from the entered pay amounts.';
  return data;
}

function scheduleCalculation() {
  for (const selector of calcFields) $(selector).disabled = false;
  calculation = null; $('#saveCalculation').disabled = true; $('#recordPayment').disabled = true;
  window.clearTimeout(calculationTimer);
  calculationTimer = window.setTimeout(refreshCalculation, 250);
}

function renderHistory(data) {
  const records = data?.rows || [];
  historyCount = Number(data?.payment_count || 0);
  const currencyTotals = data?.totals_by_currency || [];
  const totalLabel = currencyTotals.length === 1
    ? money(currencyTotals[0].amount, currencyTotals[0].currency)
    : currencyTotals.length ? currencyTotals.map((item) => money(item.amount,item.currency)).join(' · ') : money(0);
  $('#payrollSummary').innerHTML = `<article><span>Total paid in filtered results</span><strong>${escapeHtml(totalLabel)}</strong></article><article><span>Payment entries</span><strong>${historyCount}</strong></article><article><span>Staff paid</span><strong>${Number(data?.staff_count || 0)}</strong></article>`;
  rows.innerHTML = records.map((item) => {
    const periodPaid = Number(item.period_paid || 0), balance = Math.max(0, Number(item.net_pay || 0) - periodPaid);
    return `<tr><td>${escapeHtml(item.payroll_number)}</td><td>${escapeHtml(item.staff_name)}</td><td>${escapeHtml(item.pay_month.slice(0,7))}</td><td>${escapeHtml(money(item.gross_pay,item.currency_code))}</td><td>${escapeHtml(money(item.deductions,item.currency_code))}</td><td>${escapeHtml(money(item.net_pay,item.currency_code))}</td><td>${escapeHtml(money(item.amount,item.currency_code))}</td><td>${escapeHtml(money(periodPaid,item.currency_code))}</td><td>${escapeHtml(money(balance,item.currency_code))}</td><td>${escapeHtml(item.payment_method)}</td><td>${escapeHtml(item.paid_by_name)}</td><td>${escapeHtml(new Date(item.paid_at).toLocaleString())}</td><td><button class="btn secondary" data-print="${escapeHtml(item.id)}" type="button">Print</button></td></tr>`;
  }).join('') || '<tr><td colspan="13" class="muted">No payroll matches these filters.</td></tr>';
  const first = historyCount ? historyPage * historyPageSize + 1 : 0;
  $('#historyPageInfo').textContent = `${first}–${Math.min((historyPage + 1) * historyPageSize,historyCount)} of ${historyCount}`;
  $('#previousPage').disabled = historyPage === 0;
  $('#nextPage').disabled = (historyPage + 1) * historyPageSize >= historyCount;
  listMsg.textContent = 'Totals use recorded installments. Remaining balance is calculated against the saved net pay for each period.';
  rows.querySelectorAll('[data-print]').forEach((button) => button.addEventListener('click', async () => {
    const payment = records.find((item) => item.id === button.dataset.print);
    if (payment) await printPayroll(payment, payment);
  }));
}

async function loadHistory() {
  listMsg.textContent = 'Loading payroll records…';
  const month = $('#historyMonth').value;
  const { data, error } = await supabase.rpc('admin_payroll_history', {
    p_month: month ? `${month}-01` : null,
    p_staff_id: $('#historyStaff').value || null,
    p_search: $('#historySearch').value.trim() || null,
    p_limit: historyPageSize,
    p_offset: historyPage * historyPageSize,
  });
  if (error) { rows.replaceChildren(); listMsg.textContent = `Payroll could not be loaded: ${error.message}`; return; }
  renderHistory(data);
}

async function printPayroll(payment, period = payment, popup = window.open('', '_blank', 'width=460,height=720')) {
  if (!popup) { formMsg.textContent = 'Allow pop-ups to print the payroll receipt.'; return; }
  const { data, error } = await supabase.storage.from('receipt-signatures').createSignedUrl(payment.signature_path, 300);
  if (error || !data?.signedUrl) { popup.close(); formMsg.textContent = 'The saved admin signature could not be loaded.'; return; }
  const currency = payment.currency_code || period.currency_code || 'KES';
  const paidToDate = Number(period.period_paid ?? period.paid ?? payment.amount);
  const balance = Math.max(0, Number(period.net_pay ?? payment.amount) - paidToDate);
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(payment.payroll_number)}</title><style>body{font:14px Arial;max-width:380px;margin:24px auto;color:#111}h1{text-align:center;font-size:20px}.muted{text-align:center;color:#555}.line{display:flex;justify-content:space-between;gap:16px;padding:9px 0;border-bottom:1px solid #ddd}.signature{text-align:center;margin-top:28px}.signature img{display:block;max-width:190px;max-height:75px;object-fit:contain;margin:0 auto 5px}</style></head><body><h1>Payroll payment receipt</h1><p class="muted">${escapeHtml(payment.payroll_number)}</p><div class="line"><span>Staff member</span><b>${escapeHtml(payment.staff_name)}</b></div><div class="line"><span>Pay month</span><b>${escapeHtml(payment.pay_month.slice(0,7))}</b></div><div class="line"><span>Gross pay</span><b>${escapeHtml(money(period.gross_pay,currency))}</b></div><div class="line"><span>Deductions</span><b>${escapeHtml(money(period.deductions,currency))}</b></div><div class="line"><span>Net pay</span><b>${escapeHtml(money(period.net_pay,currency))}</b></div><div class="line"><span>This payment</span><b>${escapeHtml(money(payment.amount,currency))}</b></div><div class="line"><span>Total paid to date</span><b>${escapeHtml(money(paidToDate,currency))}</b></div><div class="line"><span>Remaining balance</span><b>${escapeHtml(money(balance,currency))}</b></div><div class="line"><span>Method</span><b>${escapeHtml(payment.payment_method)}</b></div>${payment.payment_reference?`<div class="line"><span>Reference</span><b>${escapeHtml(payment.payment_reference)}</b></div>`:''}<div class="line"><span>Paid by</span><b>${escapeHtml(payment.paid_by_name)}</b></div><div class="line"><span>Date</span><b>${escapeHtml(new Date(payment.paid_at).toLocaleString())}</b></div><div class="signature"><img src="${escapeHtml(data.signedUrl)}" alt="Authorized administrator signature"><div>Authorized by <b>${escapeHtml(payment.signature_name)}</b></div></div><script>addEventListener('load',()=>{const image=document.querySelector('img');image.decode().then(()=>print()).catch(()=>document.body.insertAdjacentText('beforeend','Signature failed to load; receipt not printed.'))},{once:true})</script></body></html>`;
  popup.document.open(); popup.document.write(html); popup.document.close();
}

const [{ data: staff, error: staffError }, { data: settings, error: settingsError }] = await Promise.all([
  supabase.from('profiles').select('id,full_name,active').eq('role', 'seller').order('full_name'),
  supabase.from('pharmacy_settings').select('receipt_signature_path,receipt_signature_name').eq('id', true).single(),
]);
if (staffError) formMsg.textContent = `Staff list could not be loaded: ${staffError.message}`;
else {
  staffAccounts = staff || [];
  $('#staff').innerHTML = '<option value="">Choose staff member</option>' + (staff || []).map((person) => `<option value="${escapeHtml(person.id)}">${escapeHtml(person.full_name)}${person.active ? '' : ' (inactive)'}</option>`).join('');
  $('#historyStaff').innerHTML = '<option value="">All staff</option>' + (staff || []).map((person) => `<option value="${escapeHtml(person.id)}">${escapeHtml(person.full_name)}${person.active ? '' : ' (inactive)'}</option>`).join('');
  $('#bulkStaff').innerHTML = staffAccounts.map((person) => `<label class="bulk-staff-option"><input type="checkbox" value="${escapeHtml(person.id)}"><span>${escapeHtml(person.full_name)}${person.active ? '' : ' (inactive)'}</span></label>`).join('') || '<p class="muted">No staff accounts found.</p>';
}
signatureReady = !settingsError && Boolean(settings?.receipt_signature_path && settings?.receipt_signature_name);
if (!signatureReady) formMsg.textContent = 'Save the admin receipt signature in Pharmacy Settings before recording payroll.';
$('#payMonth').value = new Date().toISOString().slice(0,7);
$('#method').addEventListener('change', () => { $('#reference').required = ['mpesa','bank'].includes($('#method').value); });
function selectedBulkStaff() {
  const selectedIds = new Set([...$('#bulkStaff').querySelectorAll('input:checked')].map((input) => input.value));
  return staffAccounts.filter((person) => selectedIds.has(person.id));
}
function renderBulkRows() {
  const selected = selectedBulkStaff();
  $('#runBulkPayroll').disabled = !selected.length || !signatureReady;
  if (!selected.length) { $('#bulkRows').innerHTML = '<p class="muted">Select staff members to enter their pay details.</p>'; return; }
  $('#bulkRows').innerHTML = `<table class="table"><thead><tr><th>Staff member</th><th>Base pay</th><th>Additions</th><th>Deductions</th><th>Amount paid now</th></tr></thead><tbody>${selected.map((person) => `<tr data-bulk-staff="${escapeHtml(person.id)}"><td>${escapeHtml(person.full_name)}${person.active ? '' : ' (inactive)'}</td><td><input data-pay="base" type="number" min="0" step="0.01" value="0.00" aria-label="Base pay for ${escapeHtml(person.full_name)}"></td><td><input data-pay="additions" type="number" min="0" step="0.01" value="0.00" aria-label="Additions for ${escapeHtml(person.full_name)}"></td><td><input data-pay="deductions" type="number" min="0" step="0.01" value="0.00" aria-label="Deductions for ${escapeHtml(person.full_name)}"></td><td><input data-pay="amount" type="number" min="0.01" step="0.01" placeholder="Installment" aria-label="Amount paid now for ${escapeHtml(person.full_name)}"></td></tr>`).join('')}</tbody></table>`;
}
$('#bulkStaff').addEventListener('change', renderBulkRows);
$('#selectAllStaff').addEventListener('click', () => { $('#bulkStaff').querySelectorAll('input[type="checkbox"]').forEach((input) => { input.checked = true; }); renderBulkRows(); });
$('#clearStaffSelection').addEventListener('click', () => { $('#bulkStaff').querySelectorAll('input[type="checkbox"]').forEach((input) => { input.checked = false; }); renderBulkRows(); });
$('#bulkMethod').addEventListener('change', () => { $('#bulkReference').required = ['mpesa','bank'].includes($('#bulkMethod').value); });
renderBulkRows();
for (const selector of ['#staff','#payMonth',...calcFields]) $(selector).addEventListener(selector === '#staff' ? 'change' : 'input', scheduleCalculation);
$('#saveCalculation').addEventListener('click', async () => {
  if (!calculation || calculation.period_saved) return;
  const button = $('#saveCalculation'); button.disabled = true; formMsg.textContent = 'Saving pay calculation…';
  const { data, error } = await supabase.rpc('admin_save_staff_payroll_period', calculationArgs());
  if (error) { formMsg.textContent = error.message; button.disabled = false; return; }
  showCalculation(data); formMsg.textContent = 'Pay calculation saved. You can now record one or more installments.';
});
$('#runBulkPayroll').addEventListener('click', async () => {
  const selected = selectedBulkStaff();
  const month = monthDate();
  const method = $('#bulkMethod').value;
  const reference = $('#bulkReference').value.trim() || null;
  const notes = $('#bulkNotes').value.trim() || null;
  if (!signatureReady) { $('#bulkMsg').textContent = 'Save the Admin receipt signature before recording payroll.'; return; }
  if (!month) { $('#bulkMsg').textContent = 'Choose the pay month in the form above.'; return; }
  if (!selected.length) { $('#bulkMsg').textContent = 'Select at least one staff member.'; return; }
  if (['mpesa','bank'].includes(method) && !reference) { $('#bulkMsg').textContent = 'Enter the payment reference for this method.'; return; }

  const entries = selected.map((person) => {
    const row = [...$('#bulkRows').querySelectorAll('[data-bulk-staff]')].find((item) => item.dataset.bulkStaff === person.id);
    const field = (name) => row?.querySelector(`[data-pay="${name}"]`)?.value ?? '';
    return { person, base: Number(field('base')), additions: Number(field('additions')), deductions: Number(field('deductions')), amount: Number(field('amount')) };
  });
  const invalid = entries.find((entry) => !Number.isFinite(entry.base) || !Number.isFinite(entry.additions) || !Number.isFinite(entry.deductions) || !Number.isFinite(entry.amount) || Math.min(entry.base,entry.additions,entry.deductions)<0 || entry.amount<=0 || entry.base+entry.additions<entry.deductions);
  if (invalid) { $('#bulkMsg').textContent = `Enter valid pay figures and a payment greater than zero for ${invalid.person.full_name}.`; return; }
  if (entries.some((entry) => [entry.base,entry.additions,entry.deductions,entry.amount].some((value) => Number(value.toFixed(2))!==value))) { $('#bulkMsg').textContent = 'Use no more than two decimal places for pay amounts.'; return; }

  const button = $('#runBulkPayroll'); button.disabled = true;
  const prepared = [];
  let recorded = 0;
  $('#bulkMsg').textContent = `Checking ${entries.length} staff pay calculations…`;
  try {
    for (const entry of entries) {
      const args = { p_staff_id: entry.person.id, p_pay_month: month, p_base_pay: entry.base, p_additions: entry.additions, p_deductions: entry.deductions };
      const preview = await supabase.rpc('admin_calculate_staff_payroll', args);
      if (preview.error) throw new Error(`${entry.person.full_name}: ${preview.error.message}`);
      let period = preview.data;
      if (period.period_saved) {
        if (Number(period.base_pay)!==entry.base || Number(period.additions)!==entry.additions || Number(period.deductions)!==entry.deductions) throw new Error(`${entry.person.full_name} already has different saved pay figures for this month. Use the individual payroll form to review them.`);
      } else {
        const saved = await supabase.rpc('admin_save_staff_payroll_period', args);
        if (saved.error) throw new Error(`${entry.person.full_name}: ${saved.error.message}`);
        period = saved.data;
      }
      if (entry.amount > Number(period.balance||0)) throw new Error(`${entry.person.full_name}: amount exceeds the remaining net pay balance (${money(period.balance,period.currency_code)}).`);
      prepared.push({ ...entry, period });
    }

    for (const entry of prepared) {
      $('#bulkMsg').textContent = `Recording payment ${recorded+1} of ${prepared.length}…`;
      const result = await supabase.rpc('admin_record_staff_payroll', {
        p_staff_id: entry.person.id, p_pay_month: month, p_base_pay: entry.base,
        p_additions: entry.additions, p_deductions: entry.deductions, p_amount_paid: entry.amount,
        p_payment_method: method, p_payment_reference: reference,
        p_notes: notes ? `Bulk payroll: ${notes}` : 'Bulk payroll run',
      });
      if (result.error) throw new Error(`${entry.person.full_name}: ${result.error.message}`);
      recorded++;
    }
    $('#bulkMsg').textContent = `Recorded payroll for ${recorded} staff member${recorded===1?'':'s'}. Individual receipts are available in Recorded payroll below.`;
    $('#bulkNotes').value = ''; $('#bulkReference').value = '';
    $('#bulkStaff').querySelectorAll('input[type="checkbox"]').forEach((input) => { input.checked = false; });
    renderBulkRows();
    await loadHistory();
  } catch (error) {
    $('#bulkMsg').textContent = recorded ? `Recorded payments for ${recorded} of ${entries.length} staff before an error: ${error.message} Check Recorded payroll for the saved receipts.` : error.message;
    if (recorded) { $('#bulkStaff').querySelectorAll('input[type="checkbox"]').forEach((input) => { input.checked = false; }); renderBulkRows(); }
    await loadHistory();
  } finally {
    button.disabled = !selectedBulkStaff().length || !signatureReady;
  }
});
amountInput.addEventListener('input', updatePaymentButton);
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!calculation?.period_saved) { formMsg.textContent = 'Save the pay calculation before recording a payment.'; return; }
  const amount = Number(amountInput.value);
  if (!Number.isFinite(amount) || amount <= 0 || amount > Number(calculation.balance)) { formMsg.textContent = 'Enter a payment greater than zero and no higher than the remaining balance.'; return; }
  const button = $('#recordPayment'); button.disabled = true; formMsg.textContent = 'Recording payroll installment…';
  const receiptWindow = window.open('', '_blank', 'width=460,height=720');
  if (receiptWindow) receiptWindow.document.write('<!doctype html><title>Preparing payroll receipt</title><p>Preparing signed payroll receipt…</p>');
  const month = $('#payMonth').value;
  const { data, error } = await supabase.rpc('admin_record_staff_payroll', {
    ...calculationArgs(), p_amount_paid: amount, p_payment_method: $('#method').value,
    p_payment_reference: $('#reference').value.trim() || null, p_notes: $('#notes').value.trim() || null,
  });
  if (error) { receiptWindow?.close(); formMsg.textContent = error.message; updatePaymentButton(); return; }
  const priorCalculation = calculation;
  const period = await refreshCalculation();
  formMsg.textContent = `Recorded ${data.payroll_number}.`;
  const receiptPeriod = period || { ...priorCalculation, period_paid: Number(priorCalculation.paid || 0) + Number(data.amount), balance: Math.max(0, Number(priorCalculation.net_pay || 0) - Number(priorCalculation.paid || 0) - Number(data.amount)) };
  await printPayroll(data, receiptPeriod, receiptWindow);
  amountInput.value = ''; $('#reference').value = ''; $('#notes').value = ''; updatePaymentButton();
  await loadHistory();
});

$('#refresh').addEventListener('click', loadHistory);
for (const selector of ['#historyMonth','#historyStaff']) $(selector).addEventListener('change', () => { historyPage = 0; loadHistory(); });
let historySearchTimer;
$('#historySearch').addEventListener('input', () => { historyPage = 0; window.clearTimeout(historySearchTimer); historySearchTimer = window.setTimeout(loadHistory,250); });
$('#previousPage').addEventListener('click', () => { if (historyPage > 0) { historyPage--; loadHistory(); } });
$('#nextPage').addEventListener('click', () => { if ((historyPage + 1) * historyPageSize < historyCount) { historyPage++; loadHistory(); } });
loadHistory();
