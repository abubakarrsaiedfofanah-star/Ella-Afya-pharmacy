import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);

const dateInput = document.querySelector('#date');
const summary = document.querySelector('#summary');
const message = document.querySelector('#msg');

dateInput.value = new Date().toISOString().slice(0, 10);

async function loadSnapshot() {
  const { data, error } = await supabase.rpc('admin_end_of_day_snapshot', {
    p_business_date: dateInput.value,
  });

  if (error) {
    message.textContent = error.message;
    return;
  }

  summary.innerHTML = Object.entries(data)
    .filter(([key]) => key !== 'business_date')
    .map(([key, value]) => `<div class="reconcile-item"><small>${key.replaceAll('_', ' ')}</small><strong>KSh ${Number(value || 0).toLocaleString()}</strong></div>`)
    .join('');
}

document.querySelector('#load').addEventListener('click', loadSnapshot);
document.querySelector('#close').addEventListener('click', async () => {
  const { data, error } = await supabase.rpc('close_daily_reconciliation', {
    p_business_date: dateInput.value,
    p_counted_cash: Number(document.querySelector('#counted').value) || 0,
    p_notes: document.querySelector('#notes').value || null,
  });

  message.textContent = error?.message || `Reconciliation closed. Variance: KSh ${Number(data?.variance || 0).toLocaleString()}`;
  if (!error) await loadSnapshot();
});

loadSnapshot();