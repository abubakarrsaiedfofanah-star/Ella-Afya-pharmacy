import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);
const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[character]);
const money = (value) => `KSh ${Number(value || 0).toLocaleString()}`;
let medicines = [];

async function init() {
  const { data, error } = await supabase.from('admin_medicine_purchase_catalog')
    .select('id,name,purchase_price').eq('active', true).order('name');
  if (error) { $('#msg').textContent = `Purchase prices could not be loaded: ${error.message}`; return; }
  medicines = data || [];
  addRow();
  await loadBalances();
}

function addRow() {
  const row = document.createElement('div');
  row.className = 'purchase-row';
  row.innerHTML = `<select><option value="">Select medicine</option>${medicines.map((medicine) => `<option value="${escapeHtml(medicine.id)}" data-cost="${Number(medicine.purchase_price)}">${escapeHtml(medicine.name)}</option>`).join('')}</select><input type="number" min="1" value="1" placeholder="Qty"><input type="number" min="0" step="0.01" placeholder="Unit cost"><button class="btn secondary remove" type="button">×</button>`;
  row.querySelector('select').addEventListener('change', (event) => {
    const option = event.target.selectedOptions[0];
    if (option?.dataset.cost) row.querySelectorAll('input')[1].value = option.dataset.cost;
  });
  row.querySelector('.remove').addEventListener('click', () => row.remove());
  $('#items').appendChild(row);
}

async function loadBalances() {
  const { data, error } = await supabase.rpc('admin_supplier_balances');
  if (error) { $('#msg').textContent = error.message; return; }
  $('#balances').innerHTML = (data || []).map((item) => `<div class="seller-row"><strong>${escapeHtml(item.supplier_name)}</strong><strong>${money(item.balance)}</strong></div>`).join('') || '<div class="ok">✓ No outstanding balances.</div>';
}

$('#add').addEventListener('click', addRow);
$('#refresh').addEventListener('click', loadBalances);
$('#create').addEventListener('click', async () => {
  const items = [...document.querySelectorAll('.purchase-row')].map((row) => {
    const inputs = row.querySelectorAll('input');
    return { medicine_id: row.querySelector('select').value, quantity: Number(inputs[0].value), unit_cost: Number(inputs[1].value) };
  }).filter((item) => item.medicine_id);
  const { data, error } = await supabase.rpc('admin_create_purchase_order', {
    p_supplier_id: null, p_supplier_name: $('#supplierName').value,
    p_expected_date: $('#expected').value || null, p_notes: $('#notes').value, p_items: items,
  });
  $('#msg').textContent = error?.message || `Purchase order ${data} created.`;
});
$('#pay').addEventListener('click', async () => {
  const { data, error } = await supabase.rpc('admin_record_supplier_payment', {
    p_supplier_id: null, p_supplier_name: $('#paySupplier').value,
    p_amount: Number($('#payAmount').value), p_reference: $('#payRef').value,
    p_notes: 'Supplier balance payment',
  });
  $('#msg').textContent = error?.message || `Payment ${data} recorded.`;
  if (!error) await loadBalances();
});

init();
