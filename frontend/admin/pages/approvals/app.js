import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const rows=document.querySelector('#rows'),msg=document.querySelector('#msg');
const esc=window.pharmacyUI.escapeHtml;

async function load(){
  const {data,error}=await supabase.from('approvals')
    .select('id,action_type,target_id,reason,created_at,profiles:requested_by(full_name)')
    .eq('status','pending').order('created_at',{ascending:false});
  if(error){msg.textContent='Pending requests could not be loaded.';return}
  rows.innerHTML=(data||[]).map(item=>`<tr><td>${esc(item.action_type)}</td><td>${esc(item.profiles?.full_name||'')}</td><td>${esc(item.reason)}</td><td>${esc(new Date(item.created_at).toLocaleString())}</td><td><button type="button" data-id="${esc(item.id)}" data-ok="1">Approve</button> <button type="button" data-id="${esc(item.id)}" data-ok="0">Reject</button></td></tr>`).join('')||'<tr><td colspan="5">No requests are waiting for review.</td></tr>';
}

rows.addEventListener('click',async event=>{
  const button=event.target.closest('button[data-id]');
  if(!button||button.disabled)return;
  button.disabled=true;
  const {error}=await supabase.rpc('decide_approval',{p_approval_id:button.dataset.id,p_approve:button.dataset.ok==='1'});
  msg.textContent=error?'The request decision could not be saved.':'Decision recorded.';
  if(!error)await load();else button.disabled=false;
});
load();
