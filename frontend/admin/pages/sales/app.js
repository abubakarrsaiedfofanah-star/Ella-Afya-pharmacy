import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const rows=document.querySelector('#rows'),msg=document.querySelector('#msg'),esc=window.pharmacyUI.escapeHtml;
async function load(){
  const {data,error}=await supabase.from('sales').select('sale_number,total_amount,status,created_at,seller_id').order('created_at',{ascending:false}).limit(200);
  if(error){msg.textContent='Sales could not be loaded.';return}
  rows.innerHTML=(data||[]).map(item=>`<tr><td>${esc(item.sale_number)}</td><td>${esc(item.seller_id)}</td><td>KSh ${Number(item.total_amount).toLocaleString()}</td><td>${esc(item.status)}</td><td>${esc(new Date(item.created_at).toLocaleString())}</td></tr>`).join('')||'<tr><td colspan="5">No sales recorded.</td></tr>';
}
load();
