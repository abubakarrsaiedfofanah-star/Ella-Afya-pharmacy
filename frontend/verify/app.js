import { supabase } from '../shared/js/supabase.js';

const number = document.querySelector('#number');
const result = document.querySelector('#result');

async function verify() {
  const receiptNumber = number.value.trim();
  if (!receiptNumber) {
    result.textContent = 'Enter a receipt number.';
    return;
  }
  result.textContent = 'Checking receipt…';
  const { data, error } = await supabase.from('receipt_verification')
    .select('sale_number,total_amount,status,created_at,authorized_signature_name,signature_attached')
    .eq('sale_number', receiptNumber)
    .maybeSingle();
  if (error || !data) {
    result.textContent = 'Receipt not found.';
    return;
  }
  const currency = [['Receipt', data.sale_number], ['Amount', `KSh ${Number(data.total_amount).toLocaleString()}`], ['Status', data.status], ['Date', new Date(data.created_at).toLocaleString()], ['Authorized by', data.authorized_signature_name || 'Not recorded'], ['Admin signature attached', data.signature_attached ? 'Yes' : 'No']];
  result.replaceChildren(...currency.map(([label, value]) => {
    const line = document.createElement('p');
    const strong = document.createElement('strong');
    line.append(`${label}: `);
    strong.textContent = String(value);
    line.append(strong);
    return line;
  }));
}

document.querySelector('#verify').addEventListener('click', verify);
number.addEventListener('keydown', event => { if (event.key === 'Enter') verify(); });
const receipt = new URLSearchParams(location.search).get('receipt');
if (receipt) {
  number.value = receipt;
  verify();
}
