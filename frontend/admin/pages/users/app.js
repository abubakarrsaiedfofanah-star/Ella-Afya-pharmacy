import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
import {isStrongPassword,PASSWORD_POLICY_MESSAGE} from '../../../shared/js/password-policy.js';

const session=await requireUser(['admin']);
if(!session)throw new Error('Unauthorized');
const $=selector=>document.querySelector(selector),esc=window.pharmacyUI.escapeHtml;
const rows=$('#rows'),msg=$('#msg'),createMsg=$('#createMsg'),permSeller=$('#permSeller'),permMsg=$('#permMsg');

async function loadSellers(){
  rows.innerHTML='<tr><td colspan="5">Loading staff accounts…</td></tr>';
  const {data,error}=await supabase.from('profiles').select('id,full_name,role,active,created_at').eq('role','seller').order('created_at',{ascending:false});
  if(error){rows.innerHTML='<tr><td colspan="5">Staff accounts could not be loaded.</td></tr>';msg.textContent='Try refreshing the staff list.';return []}
  const sellers=data||[];
  rows.innerHTML=sellers.map(item=>`<tr><td><strong>${esc(item.full_name||'Seller')}</strong></td><td class="muted">${esc(item.id.slice(0,8))}…</td><td><span class="status ${item.active?'status-ok':'status-off'}">${item.active?'Active':'Inactive'}</span></td><td>${esc(new Date(item.created_at).toLocaleDateString())}</td><td><button type="button" class="btn secondary action" data-id="${esc(item.id)}" data-active="${item.active}">${item.active?'Disable':'Activate'}</button></td></tr>`).join('')||'<tr><td colspan="5">No seller accounts found.</td></tr>';
  return sellers;
}

async function loadPermissions(userId){
  const {data,error}=await supabase.from('seller_permissions').select('*').eq('user_id',userId).maybeSingle();
  if(error){permMsg.textContent='Seller permissions could not be loaded.';return}
  const permission=data||{};
  $('#maxDiscount').value=permission.max_discount_percent??0;
  $('#maxTxn').value=permission.max_transaction_amount??'';
  for(const [id,key] of [['canSell','can_sell'],['canRx','can_process_prescriptions'],['canRefund','can_request_refund'],['canCancel','can_request_cancellation'],['canAdjust','can_request_stock_adjustment'],['canReports','can_view_own_reports']])$(`#${id}`).checked=permission[key]!==false;
}

async function loadPermissionSellers(){
  const {data,error}=await supabase.from('profiles').select('id,full_name').eq('role','seller').order('full_name');
  if(error){permMsg.textContent='Seller list is unavailable.';return}
  permSeller.innerHTML=(data||[]).map(item=>`<option value="${esc(item.id)}">${esc(item.full_name||item.id.slice(0,8))}</option>`).join('');
  if(data?.length)await loadPermissions(data[0].id);
}

rows.addEventListener('click',async event=>{
  const button=event.target.closest('.action');
  if(!button||button.disabled)return;
  button.disabled=true;
  const {error}=await supabase.rpc('set_seller_active',{p_user_id:button.dataset.id,p_active:button.dataset.active!=='true'});
  if(error){msg.textContent='Seller status could not be changed.';button.disabled=false;return}
  msg.textContent=`Seller ${button.dataset.active==='true'?'disabled':'activated'} successfully.`;
  await loadSellers();
});
$('#refresh').addEventListener('click',loadSellers);

$('#createForm').addEventListener('submit',async event=>{
  event.preventDefault();
  const submit=event.submitter||event.currentTarget.querySelector('button[type="submit"]');
  const fullName=$('#fullName').value.trim(),email=$('#email').value.trim().toLowerCase(),password=$('#password').value;
  if(!isStrongPassword(password)){createMsg.textContent=PASSWORD_POLICY_MESSAGE;return}
  submit.disabled=true;submit.setAttribute('aria-busy','true');createMsg.textContent='Creating seller account…';
  try{
    const {error}=await supabase.functions.invoke('admin-create-user',{body:{full_name:fullName,email,password}});
    if(error){createMsg.textContent='Could not create seller with those details.';return}
    createMsg.textContent='Seller account created and activated.';event.currentTarget.reset();await loadSellers();await loadPermissionSellers();
  }catch{createMsg.textContent='Account creation is temporarily unavailable.'}
  finally{submit.disabled=false;submit.removeAttribute('aria-busy')}
});

$('#permSeller').addEventListener('change',()=>loadPermissions(permSeller.value));
$('#permForm').addEventListener('submit',async event=>{
  event.preventDefault();
  const submit=event.submitter||event.currentTarget.querySelector('button[type="submit"]');
  submit.disabled=true;permMsg.textContent='Saving permissions…';
  const asNumber=value=>value===''?null:Number(value);
  const {error}=await supabase.rpc('admin_set_seller_permissions',{
    p_user_id:permSeller.value,p_can_sell:$('#canSell').checked,p_can_process_prescriptions:$('#canRx').checked,
    p_can_request_refund:$('#canRefund').checked,p_can_request_cancellation:$('#canCancel').checked,
    p_can_request_stock_adjustment:$('#canAdjust').checked,p_can_view_own_reports:$('#canReports').checked,
    p_max_discount_percent:Number($('#maxDiscount').value||0),p_max_transaction_amount:asNumber($('#maxTxn').value),
  });
  permMsg.textContent=error?'Seller permissions could not be saved.':'Seller permissions saved.';
  submit.disabled=false;
});

await loadSellers();
await loadPermissionSellers();
