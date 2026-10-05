import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);

const rows = document.querySelector('#rows');
const message = document.querySelector('#msg');
const esc = window.pharmacyUI.escapeHtml;

async function loadSessions() {
  const { data, error } = await supabase
    .from('device_sessions')
    .select('id,device_label,user_agent,last_seen_at,created_at,revoked_at,user_id,profiles(full_name,role)')
    .order('last_seen_at', { ascending: false })
    .limit(300);

  if (error) {
    message.textContent = error.message;
    return;
  }

  rows.innerHTML = (data || []).map((session) => `<tr><td>${esc(session.profiles?.full_name || session.user_id)}</td><td>${esc(session.device_label || 'Unknown')}<br><small>${esc((session.user_agent || '').slice(0, 80))}</small></td><td>${esc(new Date(session.last_seen_at).toLocaleString())}</td><td>${esc(new Date(session.created_at).toLocaleString())}</td><td>${session.revoked_at ? 'Revoked' : 'Active'}</td><td>${session.revoked_at ? '' : `<button type="button" class="btn secondary" data-id="${esc(session.id)}">Revoke</button>`}</td></tr>`).join('') || '<tr><td colspan="6">No device sessions recorded.</td></tr>';

  rows.querySelectorAll('button[data-id]').forEach((button) => {
    button.addEventListener('click', async () => {
      if (!confirm('Revoke this device session?')) return;
      button.disabled = true;
      const { error: revokeError } = await supabase.rpc('revoke_device_session', {
        p_session_id: button.dataset.id,
      });
      message.textContent = revokeError ? 'Session could not be revoked.' : 'Session revoked.';
      if (!revokeError) await loadSessions();
      else button.disabled = false;
    });
  });
}

loadSessions();
