import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const $=selector=>document.querySelector(selector),form=$('#form'),medicineSelect=$('#medicine'),lines=$('#lines'),rows=$('#rows'),msg=$('#msg'),receiveButton=$('#receive');
const esc=window.pharmacyUI.escapeHtml;
let medicines=[],items=[];
const localDate=()=>{const now=new Date();return `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`};

async function load(){
  const {data:medicineData,error:medicineError}=await supabase.from('medicines').select('id,name,strength').eq('active',true).order('name');
  if(medicineError){msg.textContent='Medicine catalogue could not be loaded.';return}
  medicines=medicineData||[];
  medicineSelect.innerHTML='<option value="">Select medicine</option>'+medicines.map(item=>`<option value="${esc(item.id)}">${esc(item.name)} ${esc(item.strength||'')}</option>`).join('');
  const {data:receiptData,error}=await supabase.from('stock_receipts').select('receipt_number,supplier_name,invoice_number,total_cost,received_at').order('received_at',{ascending:false}).limit(30);
  if(error){msg.textContent='Recent receipts could not be loaded.';return}
  rows.innerHTML=(receiptData||[]).map(item=>`<tr><td>${esc(item.receipt_number)}</td><td>${esc(item.supplier_name||'')}</td><td>${esc(item.invoice_number||'')}</td><td>KSh ${Number(item.total_cost).toLocaleString()}</td><td>${esc(new Date(item.received_at).toLocaleString())}</td></tr>`).join('')||'<tr><td colspan="5">No stock receipts yet.</td></tr>';
}

form.addEventListener('submit',event=>{
  event.preventDefault();
  const selected=medicines.find(item=>item.id===medicineSelect.value),batch=$('#batch').value.trim(),expiry=$('#expiry').value,quantity=Number($('#qty').value),cost=Number($('#cost').value);
  if(!selected){msg.textContent='Choose a medicine.';return}
  if(!batch){msg.textContent='Enter the batch number.';$('#batch').focus();return}
  if(!expiry||expiry<localDate()){msg.textContent='Choose an expiry date that has not passed.';$('#expiry').focus();return}
  if(!Number.isInteger(quantity)||quantity<1){msg.textContent='Quantity must be a whole number above zero.';$('#qty').focus();return}
  if(!Number.isFinite(cost)||cost<0){msg.textContent='Enter a valid unit cost.';$('#cost').focus();return}
  items.push({medicine_id:selected.id,name:selected.name,batch_number:batch,expiry_date:expiry,quantity,unit_cost:cost});
  renderLines();$('#batch').value='';$('#expiry').value='';$('#qty').value='';$('#cost').value='';medicineSelect.value='';medicineSelect.focus();
});

function renderLines(){
  lines.innerHTML=items.map((item,index)=>`<div class="purchase-row"><span><strong>${esc(item.name)}</strong><br>Batch ${esc(item.batch_number)} · Exp ${esc(item.expiry_date)} · ${item.quantity} units · KSh ${item.unit_cost.toLocaleString()}</span><button type="button" class="btn secondary" data-index="${index}">Remove</button></div>`).join('')||'<p class="muted">No items added to this receipt.</p>';
}
lines.addEventListener('click',event=>{
  const button=event.target.closest('button[data-index]');if(!button)return;
  items.splice(Number(button.dataset.index),1);renderLines();
});

receiveButton.addEventListener('click',async()=>{
  if(!items.length){msg.textContent='Add at least one receiving line.';return}
  receiveButton.disabled=true;msg.textContent='Recording stock receipt…';
  try{
    const values=new FormData(form);
    const {error}=await supabase.rpc('receive_stock',{p_supplier_name:values.get('supplier_name'),p_invoice_number:values.get('invoice_number'),p_items:items.map(({medicine_id,batch_number,expiry_date,quantity,unit_cost})=>({medicine_id,batch_number,expiry_date,quantity,unit_cost}))});
    if(error){msg.textContent='Stock receipt could not be recorded.';return}
    msg.textContent='Stock received successfully.';items=[];renderLines();form.reset();await load();
  }catch{msg.textContent='Stock receiving is temporarily unavailable.'}
  finally{receiveButton.disabled=false}
});
renderLines();load();
