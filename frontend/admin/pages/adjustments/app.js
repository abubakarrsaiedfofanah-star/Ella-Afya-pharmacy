import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const rows=document.querySelector('#rows'),msg=document.querySelector('#msg'),esc=window.pharmacyUI.escapeHtml;
async function load(){
  const {data,error}=await supabase.from('stock_adjustment_requests')
    .select('id,medicine_id,batch_id,quantity_change,reason,created_at,medicines(name),batches(batch_number)')
    .eq('status','pending').order('created_at');
  if(error){msg.textContent='Stock adjustment requests could not be loaded.';return}
  rows.innerHTML=(data||[]).map(item=>`<tr><td>${esc(item.medicines?.name||'')}</td><td>${esc(item.batches?.batch_number||'—')}</td><td>${item.quantity_change>0?'+':''}${Number(item.quantity_change)}</td><td>${esc(item.reason)}</td><td>${esc(new Date(item.created_at).toLocaleString())}</td><td><button type="button" class="btn" data-id="${esc(item.id)}" data-ok="1">Approve</button> <button type="button" class="btn secondary" data-id="${esc(item.id)}" data-ok="0">Reject</button></td></tr>`).join('')||'<tr><td colspan="6">No pending adjustments.</td></tr>';
}
rows.addEventListener('click',async event=>{
  const button=event.target.closest('button[data-id]');if(!button||button.disabled)return;
  button.disabled=true;
  const {error}=await supabase.rpc('decide_stock_adjustment',{p_request_id:button.dataset.id,p_approve:button.dataset.ok==='1'});
  msg.textContent=error?'Stock adjustment decision could not be saved.':'Decision saved.';
  if(!error)await load();else button.disabled=false;
});
load();
