import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const rows=document.querySelector('#rows'),msg=document.querySelector('#msg'),esc=window.pharmacyUI.escapeHtml;
async function load(){
  const {data,error}=await supabase.from('prescriptions')
    .select('id,prescription_number,patient_name,prescriber_name,prescription_date,status,prescription_items(medicine_id,quantity_prescribed,quantity_dispensed,medicines(name,strength))')
    .order('created_at',{ascending:false});
  if(error){msg.textContent='Prescriptions could not be loaded.';return}
  rows.innerHTML=(data||[]).map(item=>{
    const medicines=(item.prescription_items||[]).map(line=>`${esc(line.medicines?.name||'Medicine')} ${esc(line.medicines?.strength||'')} × ${Number(line.quantity_prescribed)} (${Number(line.quantity_dispensed)} dispensed)`).join('<br>');
    const actions=['received','under_review'].includes(item.status)?`<button type="button" data-id="${esc(item.id)}" data-ok="1">Verify</button> <button type="button" data-id="${esc(item.id)}" data-ok="0">Reject</button>`:'';
    return `<tr><td>${esc(item.prescription_number)}</td><td>${esc(item.patient_name)}</td><td>${esc(item.prescriber_name||'')}</td><td>${esc(item.prescription_date)}</td><td>${medicines}</td><td>${esc(item.status)}</td><td>${actions}</td></tr>`;
  }).join('')||'<tr><td colspan="7">No prescriptions found.</td></tr>';
}
rows.addEventListener('click',async event=>{
  const button=event.target.closest('button[data-id]');if(!button||button.disabled)return;
  button.disabled=true;const approve=button.dataset.ok==='1',reason=approve?'Verified by admin':'Rejected during review';
  const {error}=await supabase.rpc('review_prescription',{p_prescription_id:button.dataset.id,p_approve:approve,p_reason:reason});
  msg.textContent=error?'Prescription review could not be saved.':reason;
  if(!error)await load();else button.disabled=false;
});
load();
