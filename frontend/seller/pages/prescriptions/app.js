import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['seller']);

const form=document.querySelector('#form'),medicineSelect=document.querySelector('#medicine'),quantityInput=document.querySelector('#qty'),doseInput=document.querySelector('#dose'),draft=document.querySelector('#draft'),rows=document.querySelector('#rows'),msg=document.querySelector('#msg'),saveButton=document.querySelector('#save');
const esc=window.pharmacyUI.escapeHtml;
let items=[],medicines=[];

async function load(){
  const {data:medicineData,error:medicineError}=await supabase.from('medicines').select('id,name,strength').eq('active',true).order('name');
  if(medicineError){msg.textContent='Medicine catalogue could not be loaded.';return}
  medicines=medicineData||[];
  medicineSelect.innerHTML='<option value="">Select medicine</option>'+medicines.map(item=>`<option value="${esc(item.id)}">${esc(item.name)} ${esc(item.strength||'')}</option>`).join('');
  const {data:prescriptions,error}=await supabase.from('prescriptions')
    .select('id,prescription_number,patient_name,status,prescription_items(id,medicine_id,quantity_prescribed,quantity_dispensed,medicines(id,name,strength))')
    .order('created_at',{ascending:false}).limit(20);
  if(error){msg.textContent='Recent prescriptions could not be loaded.';return}
  rows.innerHTML=(prescriptions||[]).map(item=>{
    const lines=(item.prescription_items||[]).map(line=>`${esc(line.medicines?.name||'Medicine')} (${Number(line.quantity_dispensed)}/${Number(line.quantity_prescribed)})`).join('<br>');
    const use=['verified','dispensing','dispensed'].includes(item.status)?`<a href="/seller/pages/pos/?prescription=${encodeURIComponent(item.id)}">Use in POS</a>`:'';
    return `<tr><td>${esc(item.prescription_number)}</td><td>${esc(item.patient_name)}</td><td>${esc(item.status)}</td><td>${lines}</td><td>${use}</td></tr>`;
  }).join('')||'<tr><td colspan="5">No prescriptions created yet.</td></tr>';
}

form.addEventListener('submit',event=>{
  event.preventDefault();
  const selected=medicines.find(item=>item.id===medicineSelect.value),quantity=Number(quantityInput.value);
  if(!selected){msg.textContent='Choose a medicine first.';return}
  if(!Number.isInteger(quantity)||quantity<1){msg.textContent='Quantity must be a whole number above zero.';quantityInput.focus();return}
  items.push({medicine_id:selected.id,medicine_name:selected.name,quantity_prescribed:quantity,dosage_instructions:doseInput.value.trim()});
  renderDraft();medicineSelect.value='';quantityInput.value='';doseInput.value='';medicineSelect.focus();
});

function renderDraft(){
  draft.innerHTML=items.map((item,index)=>`<div>${esc(item.medicine_name)} × ${item.quantity_prescribed} — ${esc(item.dosage_instructions||'')} <button type="button" data-index="${index}">Remove</button></div>`).join('')||'<p class="muted">No medicines added to this prescription.</p>';
}
draft.addEventListener('click',event=>{
  const button=event.target.closest('button[data-index]');if(!button)return;
  items.splice(Number(button.dataset.index),1);renderDraft();
});
saveButton.addEventListener('click',async()=>{
  const values=Object.fromEntries(new FormData(form));
  if(!items.length){msg.textContent='Add at least one medicine.';return}
  saveButton.disabled=true;msg.textContent='Creating prescription…';
  const {error}=await supabase.rpc('create_prescription',{p_patient_name:values.patient_name,p_prescriber_name:values.prescriber_name||null,p_prescription_date:values.prescription_date||null,p_items:items.map(({medicine_id,quantity_prescribed,dosage_instructions})=>({medicine_id,quantity_prescribed,dosage_instructions}))});
  saveButton.disabled=false;
  if(error){msg.textContent='Prescription could not be created.';return}
  msg.textContent='Prescription created and sent for review.';items=[];renderDraft();form.reset();await load();
});

renderDraft();load();
