import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const form=document.querySelector('#form'),rows=document.querySelector('#rows'),msg=document.querySelector('#msg');
const esc=window.pharmacyUI.escapeHtml;
async function load(){
  const {data,error}=await supabase.from('suppliers').select('id,name,phone,email').order('name');
  if(error){msg.textContent='Suppliers could not be loaded.';return}
  rows.innerHTML=(data||[]).map(item=>`<tr><td>${esc(item.name)}</td><td>${esc(item.phone||'')}</td><td>${esc(item.email||'')}</td></tr>`).join('')||'<tr><td colspan="3">No suppliers added yet.</td></tr>';
}
form.onsubmit=async event=>{
  event.preventDefault();
  const values=Object.fromEntries(new FormData(form));
  const {error}=await supabase.from('suppliers').insert(values);
  if(error){msg.textContent='Supplier could not be saved.';return}
  msg.textContent='Supplier saved.';form.reset();await load();
};
load();
