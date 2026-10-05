import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';

await requireUser(['seller']);
let medicines=[];
let batches=[];
let cart=[];
let activeSaleId=null;
let outstanding=0;
let paymentWatcher=null;
let configuredTillNumber='';
const $=selector=>document.querySelector(selector);
const list=$('#medicines');
const cartElement=$('#cart');
const totalElement=$('#total');
const message=$('#msg');
const prescription=$('#prescription');
const money=value=>`KSh ${Number(value||0).toLocaleString(undefined,{minimumFractionDigits:0,maximumFractionDigits:2})}`;
const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const medicineStock=medicine=>Number(Array.isArray(medicine.inventory)?medicine.inventory[0]?.quantity:medicine.inventory?.quantity)||0;
const stockLimit=medicine=>medicine.min_stock==null?5:Number(medicine.min_stock);
const daysToExpiry=date=>Math.ceil((new Date(`${date}T00:00:00`).getTime()-new Date(`${new Date().toISOString().slice(0,10)}T00:00:00`).getTime())/86400000);

async function load(){
  message.textContent='';
  const [{data:medicineData,error:medicineError},{data:batchData},{data:prescriptionData},{data:settings}]=await Promise.all([
    supabase.from('medicines').select('id,name,generic_name,brand,barcode,strength,selling_price,min_stock,prescription_required,controlled_medicine,inventory(quantity)').eq('active',true).order('name'),
    supabase.from('batches').select('id,medicine_id,batch_number,expiry_date,quantity').gte('expiry_date',new Date().toISOString().slice(0,10)).gt('quantity',0).order('expiry_date'),
    supabase.from('prescriptions').select('id,prescription_number,patient_name,status').in('status',['verified','dispensing','dispensed']).order('created_at',{ascending:false}).limit(30),
    supabase.from('pharmacy_settings').select('till_number').maybeSingle()
  ]);
  if(medicineError){message.textContent=medicineError.message;return}
  medicines=medicineData||[];batches=batchData||[];configuredTillNumber=String(settings?.till_number||'').trim();$('#tillNumber').textContent=configuredTillNumber||'Ask the admin to configure the Till number';
  prescription.innerHTML='<option value="">No prescription</option>'+(prescriptionData||[]).map(item=>`<option value="${escapeHtml(item.id)}">${escapeHtml(item.prescription_number)} — ${escapeHtml(item.patient_name)}</option>`).join('');
  const preset=new URLSearchParams(location.search).get('prescription');if(preset)prescription.value=preset;
  renderMedicines();renderCart();
}

function addMedicine(id){
  const medicine=medicines.find(item=>item.id===id);if(!medicine)return;
  if(medicineStock(medicine)<=0){message.textContent='This medicine is out of stock.';return}
  const line=cart.find(item=>item.id===medicine.id);
  if(line){
    const selected=line.batch_id&&batches.find(batch=>batch.id===line.batch_id);
    const available=selected?Math.min(medicineStock(medicine),Number(selected.quantity)||0):medicineStock(medicine);
    if(line.quantity>=available){message.textContent='Quantity cannot exceed available stock in the selected batch.';return}
    line.quantity+=1;
  }
  else cart.push({id:medicine.id,name:medicine.name,price:Number(medicine.selling_price),quantity:1,batch_id:null});
  message.textContent='';renderCart();
}

function renderMedicines(){
  const term=$('#search').value.trim().toLowerCase();
  const matches=medicines.filter(item=>`${item.name} ${item.generic_name||''} ${item.brand||''} ${item.barcode||''} ${item.strength||''}`.toLowerCase().includes(term)).slice(0,80);
  list.innerHTML=matches.map(item=>{
    const stock=medicineStock(item),flags=[item.prescription_required?'Prescription required':'',item.controlled_medicine?'Controlled medicine':''].filter(Boolean).join(' · '),low=stock>0&&stock<=stockLimit(item);
    const nearExpiry=batches.some(batch=>batch.medicine_id===item.id&&daysToExpiry(batch.expiry_date)<=90);
    const warnings=[low?'Low stock':null,nearExpiry?'Batch expires within 90 days':null].filter(Boolean).join(' · ');
    return `<article class="medicine ${low?'low-stock':''}"><span><strong>${escapeHtml(item.name)} ${escapeHtml(item.strength||'')}</strong><br><small>${money(item.selling_price)} · Stock ${stock}${warnings?` · <span class="stock-warning">${escapeHtml(warnings)}</span>`:''}${flags?` · ${escapeHtml(flags)}`:''}</small></span><button class="btn secondary" type="button" data-add="${escapeHtml(item.id)}" ${stock<=0?'disabled':''} aria-label="Add ${escapeHtml(item.name)} to sale">Add</button></article>`;
  }).join('')||'<p class="muted empty-results">No matching medicines.</p>';
  list.querySelectorAll('[data-add]').forEach(button=>button.addEventListener('click',()=>addMedicine(button.dataset.add)));
}

function renderCart(){
  cartElement.innerHTML=cart.map((item,index)=>{
    const available=batches.filter(batch=>batch.medicine_id===item.id);
    const medicine=medicines.find(m=>m.id===item.id),stock=medicine?medicineStock(medicine):0;
    return `<div class="cart-line"><div><strong>${escapeHtml(item.name)}</strong><small>${money(item.price)} each · ${stock} available</small></div><div class="quantity-control"><button type="button" data-quantity="-1" data-index="${index}" aria-label="Decrease ${escapeHtml(item.name)} quantity">−</button><output>${item.quantity}</output><button type="button" data-quantity="1" data-index="${index}" aria-label="Increase ${escapeHtml(item.name)} quantity" ${item.quantity>=stock?'disabled':''}>+</button><button type="button" class="remove-line" data-remove="${index}" aria-label="Remove ${escapeHtml(item.name)} from cart">Remove</button></div><select data-batch="${index}" aria-label="Select batch for ${escapeHtml(item.name)}"><option value="">Auto FEFO</option>${available.map(batch=>`<option value="${escapeHtml(batch.id)}" ${item.batch_id===batch.id?'selected':''}>${escapeHtml(batch.batch_number)} · exp ${escapeHtml(batch.expiry_date)} · ${batch.quantity} left</option>`).join('')}</select><strong class="line-total">${money(item.price*item.quantity)}</strong></div>`;
  }).join('')||'<p class="muted empty-cart">Cart is empty. Search or scan to add a medicine.</p>';
  const cartAvailable=(item)=>{
    const selected=item.batch_id&&batches.find(batch=>batch.id===item.batch_id);
    return selected?Math.min(medicineStock(medicines.find(m=>m.id===item.id)||{}),Number(selected.quantity)||0):medicineStock(medicines.find(m=>m.id===item.id)||{});
  };
  cartElement.querySelectorAll('[data-quantity]').forEach(button=>button.addEventListener('click',()=>{
    const index=Number(button.dataset.index),next=cart[index].quantity+Number(button.dataset.quantity);
    if(next>0&&next>cartAvailable(cart[index])){message.textContent='Quantity cannot exceed available stock in the selected batch.';return}
    if(next<=0)cart.splice(index,1);else cart[index].quantity=next;
    renderCart();
  }));
  cartElement.querySelectorAll('[data-remove]').forEach(button=>button.addEventListener('click',()=>{cart.splice(Number(button.dataset.remove),1);renderCart()}));
  cartElement.querySelectorAll('[data-batch]').forEach(select=>select.addEventListener('change',()=>{
    const index=Number(select.dataset.batch),item=cart[index];item.batch_id=select.value||null;
    if(item.quantity>cartAvailable(item)){item.quantity=Math.max(1,cartAvailable(item));message.textContent='Quantity adjusted to the available selected batch.'}
    renderCart();
  }));
  const total=cart.reduce((sum,item)=>sum+item.price*item.quantity,0);
  totalElement.textContent=money(total);
  $('#outstanding').textContent=`Outstanding: ${money(outstanding||total)}`;
  $('#cartCount').textContent=`${cart.reduce((sum,item)=>sum+item.quantity,0)} item${cart.reduce((sum,item)=>sum+item.quantity,0)===1?'':'s'}`;
  $('#paymentAmount').value=Number(outstanding||total).toFixed(2);
}

$('#search').addEventListener('input',renderMedicines);
$('#search').addEventListener('keydown',event=>{
  if(event.key!=='Enter')return;
  const barcode=event.currentTarget.value.trim().toLowerCase();
  const match=medicines.find(item=>(item.barcode||'').toLowerCase()===barcode);
  if(match){event.preventDefault();addMedicine(match.id);event.currentTarget.value='';renderMedicines()}
});

function updatePaymentFields(){
  const isMpesa=$('#method').value==='mpesa';
  $('#tillInstructions').hidden=!isMpesa;
  $('#phone').hidden=!isMpesa;$('#reference').hidden=isMpesa;$('#paymentAmount').hidden=isMpesa;$('#amountLabel').hidden=isMpesa;
  $('#phone').placeholder='Optional: customer phone for an STK prompt';
  $('#checkout').textContent=isMpesa?($('#phone').value.trim()?'Send STK prompt':'Show Till payment details'):activeSaleId?'Record payment':'Continue to payment';
}
$('#method').addEventListener('change',updatePaymentFields);
$('#phone').addEventListener('input',updatePaymentFields);

function showReceipt(saleId,saleNumber=saleId){
  const body=$('#receiptBody');
  const customerName=$('#customerName').value.trim(),customerPhone=$('#customerPhone').value.trim()||$('#phone').value.trim();
  body.innerHTML=`<p><span>Receipt number</span><strong>${escapeHtml(saleNumber)}</strong></p>${customerName?`<p><span>Buyer</span><strong>${escapeHtml(customerName)}</strong></p>`:''}${customerPhone?`<p><span>Buyer phone</span><strong>${escapeHtml(customerPhone)}</strong></p>`:''}<p><span>Completed</span><strong>${new Date().toLocaleString()}</strong></p>${cart.map(item=>`<p><span>${escapeHtml(item.name)} × ${item.quantity}</span><strong>${money(item.price*item.quantity)}</strong></p>`).join('')}<p class="receipt-grand-total"><span>Total paid</span><strong>${money(cart.reduce((sum,item)=>sum+item.price*item.quantity,0))}</strong></p><small>Official receipt details are available in Receipts.</small>`;
  $('#receiptPreview').hidden=false;
  $('#receiptPreview').scrollIntoView({behavior:'smooth',block:'nearest'});
}
async function loadReceiptReference(saleId){const {data}=await supabase.from('sales').select('sale_number,total_amount,status,created_at').eq('id',saleId).single();return data?.status==='paid'?data:null}
function watchMpesaPayment(saleId){
  if(paymentWatcher)clearInterval(paymentWatcher);
  const started=Date.now();
  const channel=supabase.channel(`sale-payment-${saleId}`).on('postgres_changes',{event:'UPDATE',schema:'public',table:'sales',filter:`id=eq.${saleId}`},payload=>{
    if(payload.new?.status==='paid'&&activeSaleId===saleId){clearInterval(paymentWatcher);paymentWatcher=null;channel.unsubscribe();void completeMpesaSale(saleId)}
  }).subscribe();
  paymentWatcher=setInterval(async()=>{
    if(activeSaleId!==saleId||Date.now()-started>120000){clearInterval(paymentWatcher);paymentWatcher=null;channel.unsubscribe();return}
    const sale=await loadReceiptReference(saleId);if(!sale)return;
    clearInterval(paymentWatcher);paymentWatcher=null;channel.unsubscribe();await completeMpesaSale(saleId,sale.sale_number);
  },2000);
}
async function completeMpesaSale(saleId,knownNumber){
  const saleNumber=knownNumber||(await loadReceiptReference(saleId))?.sale_number;
  if(activeSaleId!==saleId||!saleNumber)return;
  activeSaleId=null;
  message.textContent='M-Pesa payment confirmed. Stock update completed by the server.';showReceipt(saleId,saleNumber);
  outstanding=0;cart=[];prescription.value='';$('#customerName').value='';$('#customerPhone').value='';$('#phone').value='';renderCart();updatePaymentFields();await load();
}
$('#printReceipt').addEventListener('click',()=>window.print());

$('#checkout').addEventListener('click',async()=>{
  const button=$('#checkout');if(button.disabled)return;
  const method=$('#method').value;
  const phone=$('#phone').value.trim();
  const amount=Number($('#paymentAmount').value);
  if(method==='mpesa'&&!phone&&!configuredTillNumber){message.textContent='Ask the admin to configure the pharmacy Till number first.';return}
  if(method!=='mpesa'&&(!Number.isFinite(amount)||amount<=0)){ $('#paymentAmount').focus();message.textContent='Enter a valid payment amount.';return}
  if(!activeSaleId){
    if(!cart.length){message.textContent='Cart is empty.';return}
    button.disabled=true;
    const {data:saleId,error}=await supabase.rpc('create_sale',{p_items:cart.map(item=>({medicine_id:item.id,quantity:item.quantity,batch_id:item.batch_id})),p_prescription_id:prescription.value||null});
    button.disabled=false;
    if(error){message.textContent=error.message;return}
    activeSaleId=saleId;outstanding=cart.reduce((sum,item)=>sum+item.price*item.quantity,0);
  }
  button.disabled=true;
  const {error:buyerError}=await supabase.rpc('set_sale_customer_details',{p_sale_id:activeSaleId,p_customer_name:$('#customerName').value.trim()||null,p_customer_phone:$('#customerPhone').value.trim()||$('#phone').value.trim()||null});
  if(buyerError){button.disabled=false;message.textContent='Buyer details could not be saved. The sale remains pending; retry or contact the admin.';return}
  if(method==='mpesa'){
    const sale=(await supabase.from('sales').select('sale_number,total_amount,status').eq('id',activeSaleId).single()).data;
    $('#tillReference').textContent=sale?.sale_number||activeSaleId;
    $('#tillAmount').textContent=money(sale?.total_amount??outstanding);
    if(!phone){
      button.disabled=false;message.textContent=`Till details are ready. Sale ${$('#tillReference').textContent} stays pending until the payment callback verifies the transfer.`;
      watchMpesaPayment(activeSaleId);return;
    }
    const {data,error}=await supabase.functions.invoke('mpesa-stk',{body:{sale_id:activeSaleId,phone}});
    button.disabled=false;message.textContent=error?'Till payment needs the Daraja connection before this sale can be confirmed. Do not mark it paid manually.':data?.customer_message||'STK prompt sent. Wait for payment confirmation.';
    if(!error){button.textContent='Prompt sent · resend if needed';watchMpesaPayment(activeSaleId)}
    return;
  }
  const {data:remaining,error}=await supabase.rpc('add_manual_sale_payment',{p_sale_id:activeSaleId,p_method:method,p_amount:amount,p_reference:$('#reference').value.trim()||null});
  button.disabled=false;
  if(error){message.textContent=error.message;return}
  outstanding=Number(remaining||0);
  if(outstanding>0){message.textContent=`Payment recorded. Remaining ${money(outstanding)}.`;renderCart();updatePaymentFields();return}
  const completedSaleId=activeSaleId;
  message.textContent='Sale fully paid. Stock update confirmed by the server.';
  const confirmedSale=await loadReceiptReference(completedSaleId);
  showReceipt(completedSaleId,confirmedSale?.sale_number||completedSaleId);
  activeSaleId=null;outstanding=0;cart=[];prescription.value='';$('#reference').value='';$('#customerName').value='';$('#customerPhone').value='';$('#phone').value='';
  renderCart();updatePaymentFields();await load();
});

$('#copyTillDetails').addEventListener('click',async()=>{
  const details=`Till: ${configuredTillNumber}\nAmount: ${$('#tillAmount').textContent}\nReference: ${$('#tillReference').textContent}`;
  try{await navigator.clipboard.writeText(details);message.textContent='Till number, amount and sale reference copied.'}
  catch{message.textContent='Copy is unavailable in this browser. Read the payment details to the customer.'}
});

$('#checkTillPayment').addEventListener('click',async event=>{
  const button=event.currentTarget;if(!activeSaleId){message.textContent='Start a Till checkout first.';return}
  button.disabled=true;
  const sale=await loadReceiptReference(activeSaleId);
  button.disabled=false;
  if(!sale){message.textContent='Payment is not confirmed yet. Keep the medicine until confirmation arrives.';return}
  if(paymentWatcher){clearInterval(paymentWatcher);paymentWatcher=null}
  await completeMpesaSale(activeSaleId,sale.sale_number);
});

$('#hold').addEventListener('click',async()=>{
  if(activeSaleId){message.textContent='This sale already has a payment in progress. Complete it before holding another sale.';return}
  if(!cart.length){message.textContent='Cart is empty.';return}
  const reference=$('#holdReference').value.trim();
  if(!reference){$('#holdReference').focus();message.textContent='Add a short reference before holding this sale.';return}
  const {error}=await supabase.rpc('hold_sale',{p_hold_reference:reference,p_cart:cart,p_prescription_id:prescription.value||null,p_notes:null});
  message.textContent=error?.message||`Sale held as ${reference}.`;
  if(!error){cart=[];activeSaleId=null;outstanding=0;$('#holdReference').value='';renderCart();updatePaymentFields()}
});

$('#holds').addEventListener('click',async()=>{
  const {data,error}=await supabase.rpc('my_held_sales');if(error){message.textContent=error.message;return}
  const box=$('#heldList');box.hidden=false;
  box.innerHTML=(data||[]).map(item=>`<div class="seller-row"><span><strong>${escapeHtml(item.hold_reference)}</strong><br><small>${new Date(item.created_at).toLocaleString()}</small></span><button class="btn secondary" type="button" data-resume="${escapeHtml(item.id)}">Resume</button></div>`).join('')||'<p class="muted">No held sales.</p>';
  box.querySelectorAll('[data-resume]').forEach(button=>button.addEventListener('click',async()=>{
    const held=(data||[]).find(item=>item.id===button.dataset.resume);if(!held)return;
    const {error:deleteError}=await supabase.rpc('delete_held_sale',{p_id:held.id});if(deleteError){message.textContent=deleteError.message;return}
    cart=held.cart||[];prescription.value=held.prescription_id||'';activeSaleId=null;outstanding=0;box.hidden=true;renderCart();updatePaymentFields();message.textContent=`Resumed ${held.hold_reference}.`;
  }));
});

updatePaymentFields();load();
