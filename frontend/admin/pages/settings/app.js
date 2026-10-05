import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);

const form = document.querySelector('#form');
const message = document.querySelector('#msg');
const { data, error } = await supabase.from('pharmacy_settings').select('*').single();

if (error) message.textContent = error.message;
if (data) {
  Object.entries(data).forEach(([key, value]) => {
    if (form.elements[key]) form.elements[key].value = value ?? '';
  });
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const settings = Object.fromEntries(new FormData(form).entries());
  settings.low_stock_threshold = Number(settings.low_stock_threshold);
  settings.expiry_alert_days = Number(settings.expiry_alert_days);
  settings.updated_at = new Date().toISOString();

  const { error: saveError } = await supabase
    .from('pharmacy_settings')
    .update(settings)
    .eq('id', true);
  message.textContent = saveError?.message || 'Settings saved successfully.';
});