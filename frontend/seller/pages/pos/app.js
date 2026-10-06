import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';

await requireUser(['seller']);
let medicines=[];
let batches=[];
let cart=[];
let activeSaleId=null;
let outstanding=0;
let lastCashTendered=0;
let lastCashChange=0;
let configuredPaybillNumber='';
let configuredPaybillAccountNumber='';
let receiptSignatureConfigured=false;
const $=selector=>document.querySelector(selector);
const list=$('#medicines');
const cartElement=$('#cart');
const totalElement=$('#total');
const message=$('#msg');
const prescription=$('#prescription');
const money=value=>`KSh ${Number(value||0).toLocaleString(undefined,{minimumFractionDigits:0,maximumFractionDigits:2})}`;
const toCents=value=>Math.round(Number(value||0)*100),fromCents=value=>value/100;
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
    supabase.from('pharmacy_settings').select('paybill_number,paybill_account_number,till_number,receipt_signature_path,receipt_signature_name').maybeSingle()
  ]);
  if(medicineError){message.textContent=medicineError.message;return}
  medicines=medicineData||[];batches=batchData||[];if(!activeSaleId)cart=cart.map(line=>{const current=medicines.find(medicine=>medicine.id===line.id);return current?{...line,price:Number(current.selling_price)}:line});configuredPaybillNumber=String(settings?.paybill_number||settings?.till_number||'').trim();configuredPaybillAccountNumber=String(settings?.paybill_account_number||'').trim();receiptSignatureConfigured=Boolean(settings?.receipt_signature_path&&settings?.receipt_signature_name);$('#tillNumber').textContent=configuredPaybillNumber||'Ask the admin to configure the PayBill number';
  prescription.innerHTML='<option value="">No prescription</option>'+(prescriptionData||[]).map(item=>`<option value="${escapeHtml(item.id)}">${escapeHtml(item.prescription_number)} — ${escapeHtml(item.patient_name)}</option>`).join('');
  const preset=new URLSearchParams(location.search).get('prescription');if(preset)prescription.value=preset;
  renderMedicines();renderCart();
}

let catalogRefreshInProgress=false;
async function refreshCatalog(){
  if(catalogRefreshInProgress||document.visibilityState!=='visible')return;
  catalogRefreshInProgress=true;
  try{
    const [{data:medicineData,error:medicineError},{data:batchData}]=await Promise.all([
      supabase.from('medicines').select('id,name,generic_name,brand,barcode,strength,selling_price,min_stock,prescription_required,controlled_medicine,inventory(quantity)').eq('active',true).order('name'),
      supabase.from('batches').select('id,medicine_id,batch_number,expiry_date,quantity').gte('expiry_date',new Date().toISOString().slice(0,10)).gt('quantity',0).order('expiry_date')
    ]);
    if(medicineError)return;
    medicines=medicineData||[];batches=batchData||[];
    if(!activeSaleId)cart=cart.filter(line=>medicines.some(medicine=>medicine.id===line.id)).map(line=>{const current=medicines.find(medicine=>medicine.id===line.id);return {...line,name:current.name,price:Number(current.selling_price)}});
    renderMedicines();renderCart();
  }finally{catalogRefreshInProgress=false}
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
  const allMatches=medicines.filter(item=>`${item.name} ${item.generic_name||''} ${item.brand||''} ${item.barcode||''} ${item.strength||''}`.toLowerCase().includes(term));
  const matches=allMatches.slice(0,80);
  $('#medicineResultsMeta').textContent=allMatches.length>80?`Showing 80 of ${allMatches.length} matching medicines. Refine your search to find a specific item.`:`${allMatches.length} medicine${allMatches.length===1?'':'s'} found`;
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
  const total=fromCents(cart.reduce((sum,item)=>sum+toCents(item.price)*item.quantity,0));
  totalElement.textContent=money(total);
  $('#tillAmount').textContent=money(total);
  $('#outstanding').textContent=`Outstanding: ${money(outstanding||total)}`;
  const itemCount=cart.reduce((sum,item)=>sum+item.quantity,0),countText=`${itemCount} item${itemCount===1?'':'s'}`;
  $('#cartCount').textContent=countText;
  $('#mobileCartCount').textContent=countText;
  $('#mobileCartTotal').textContent=money(total);
  $('#mobileCartSummary').hidden=itemCount===0;
  $('#paymentAmount').value=Number(outstanding||total).toFixed(2);
}

$('#search').addEventListener('input',renderMedicines);
$('#mobileCartSummary').addEventListener('click',()=>$('#cartPanel').scrollIntoView({behavior:'smooth',block:'start'}));
$('#search').addEventListener('keydown',event=>{
  if(event.key!=='Enter')return;
  const barcode=event.currentTarget.value.trim().toLowerCase();
  const match=medicines.find(item=>(item.barcode||'').toLowerCase()===barcode);
  if(match){event.preventDefault();addMedicine(match.id);event.currentTarget.value='';renderMedicines()}
});

function updatePaymentFields(){
  const isMpesa=$('#method').value==='mpesa';
  $('#tillInstructions').hidden=!isMpesa;
  $('#mpesaTransactionCode').hidden=!isMpesa||!activeSaleId;$('#transactionCodeLabel').hidden=!isMpesa||!activeSaleId;
  $('#reference').hidden=isMpesa;$('#paymentAmount').hidden=false;$('#amountLabel').hidden=false;
  $('#paymentAmount').readOnly=isMpesa&&!activeSaleId;
  $('#amountLabel').textContent=isMpesa&&activeSaleId?'Amount received':'Sale amount';
  if(!isMpesa)$('#amountLabel').textContent=$('#method').value==='cash'?'Cash tendered':'Payment amount';
  $('#paymentAmount').placeholder=$('#method').value==='cash'?'Enter cash received':'Enter amount received';
  $('#manualPaymentHint').textContent=isMpesa?'Confirm the M-Pesa code and amount before entering them.':$('#method').value==='cash'?'Enter the cash received.':'Enter the amount received.';
  $('#manualPaymentHint').hidden=isMpesa;
  $('#checkout').textContent=isMpesa?(activeSaleId?'Verify M-PESA and complete sale':'Create pending sale'):activeSaleId?'Record payment':'Continue to payment';
}
$('#method').addEventListener('change',updatePaymentFields);

async function showReceipt(saleId,saleNumber=saleId){
  const body=$('#receiptBody'),printButton=$('#printReceipt');
  const customerName=$('#customerName').value.trim(),customerPhone=$('#customerPhone').value.trim();
  printButton.disabled=true;
  const [{data:sale,error},{data:saleItems,error:itemsError}]=await Promise.all([
    supabase.from('sales').select('created_at,total_amount,authorized_signature_path,authorized_signature_name,signature_applied_at').eq('id',saleId).single(),
    supabase.from('sale_items').select('quantity,unit_price,total,medicines(name,strength)').eq('sale_id',saleId),
  ]);
  if(error||itemsError||!sale?.authorized_signature_path||!sale.authorized_signature_name||!sale.signature_applied_at){body.innerHTML='<p>The signed receipt could not be prepared. Ask the Admin to check the receipt signature settings.</p>';$('#receiptPreview').hidden=false;return}
  const {data:signature,error:signatureError}=await supabase.storage.from('receipt-signatures').createSignedUrl(sale.authorized_signature_path,300);
  if(signatureError||!signature?.signedUrl){body.innerHTML='<p>The receipt signature is unavailable. Ask the Admin to check private signature storage.</p>';$('#receiptPreview').hidden=false;return}
  const verifyUrl=`${location.origin}/verify/?receipt=${encodeURIComponent(saleNumber)}`;
  const itemCount=(saleItems||[]).reduce((sum,item)=>sum+Number(item.quantity||0),0),productCount=(saleItems||[]).length;
  body.innerHTML=`<p><span>Receipt number</span><strong>${escapeHtml(saleNumber)}</strong></p>${customerName?`<p><span>Buyer</span><strong>${escapeHtml(customerName)}</strong></p>`:''}${customerPhone?`<p><span>Buyer phone</span><strong>${escapeHtml(customerPhone)}</strong></p>`:''}<p><span>Completed</span><strong>${escapeHtml(new Date(sale.created_at).toLocaleString())}</strong></p>${(saleItems||[]).map(item=>`<p><span>${escapeHtml(item.medicines?.name||'Medicine')} ${escapeHtml(item.medicines?.strength||'')}<br>${money(item.unit_price)} × ${Number(item.quantity||0)}</span><strong>${money(item.total)}</strong></p>`).join('')}<p><span>Total drugs</span><strong>${itemCount} unit${itemCount===1?'':'s'} across ${productCount} medicine${productCount===1?'':'s'}</strong></p><p class="receipt-grand-total"><span>Total paid</span><strong>${money(sale.total_amount)}</strong></p>${lastCashTendered>0?`<p><span>Cash received</span><strong>${money(lastCashTendered)}</strong></p><p><span>Change</span><strong>${money(lastCashChange)}</strong></p>`:''}<div class="receipt-admin-signature"><img src="${escapeHtml(signature.signedUrl)}" alt="Authorized administrator signature"><div>Authorized by <strong>${escapeHtml(sale.authorized_signature_name)}</strong></div><small>Verify this receipt: <a href="${escapeHtml(verifyUrl)}">${escapeHtml(verifyUrl)}</a></small></div>`;
  printButton.disabled=false;
  $('#receiptPreview').hidden=false;
  $('#receiptPreview').scrollIntoView({behavior:'smooth',block:'nearest'});
  lastCashTendered=0;lastCashChange=0;
}
async function loadReceiptReference(saleId){const {data}=await supabase.from('sales').select('sale_number,total_amount,status,created_at').eq('id',saleId).single();return data?.status==='paid'?data:null}
async function completeMpesaSale(saleId){
  const saleNumber=(await loadReceiptReference(saleId))?.sale_number;
  if(activeSaleId!==saleId||!saleNumber)return;
  activeSaleId=null;
  await showReceipt(saleId,saleNumber);
  outstanding=0;cart=[];prescription.value='';$('#customerName').value='';$('#customerPhone').value='';$('#mpesaTransactionCode').value='';$('#reference').value='';renderCart();updatePaymentFields();await load();
  message.textContent='Payment verified. Stock update completed by the server.';
}
$('#printReceipt').addEventListener('click',async()=>{const signature=$('#receiptBody img[alt="Authorized administrator signature"]');if(signature){try{await signature.decode()}catch{message.textContent='The admin signature did not load. The receipt was not printed.';return}}window.print()});

$('#checkout').addEventListener('click',async()=>{
  const button=$('#checkout');if(button.disabled)return;
  if(!receiptSignatureConfigured){message.textContent='Ask the Admin to save the receipt signature in Pharmacy Settings before completing sales.';return}
  const method=$('#method').value;
  const amount=Number($('#paymentAmount').value);
  const transactionCode=$('#mpesaTransactionCode').value.trim().toUpperCase();
  let saleJustCreated=false;
  if(method==='mpesa'&&(!configuredPaybillNumber||!configuredPaybillAccountNumber)){message.textContent='Ask the admin to configure the pharmacy PayBill number and account number first.';return}
  if(method==='mpesa'&&activeSaleId&&(!transactionCode||!Number.isFinite(amount)||amount<=0)){message.textContent='Enter the M-PESA transaction code and amount received.';return}
  if(method!=='mpesa'&&(!Number.isFinite(amount)||amount<=0)){ $('#paymentAmount').focus();message.textContent='Enter a valid payment amount.';return}
  if(!activeSaleId){
    if(!cart.length){message.textContent='Cart is empty.';return}
    button.disabled=true;
    const {data:saleId,error}=await supabase.rpc('create_sale',{p_items:cart.map(item=>({medicine_id:item.id,quantity:item.quantity,batch_id:item.batch_id,unit_price:item.price})),p_prescription_id:prescription.value||null});
    button.disabled=false;
    if(error){message.textContent=error.message;return}
    if(!saleId){await load();message.textContent='A medicine price changed or did not match the current catalogue. The sale was blocked and logged for Admin review. Check the updated prices and try again.';return}
    activeSaleId=saleId;
    const {data:savedSale,error:savedSaleError}=await supabase.from('sales').select('total_amount').eq('id',saleId).single();
    if(savedSaleError||!savedSale){message.textContent='Sale saved as pending, but its total could not be loaded. Refresh and resume the pending sale before taking payment.';return}
    outstanding=Number(savedSale.total_amount);
    saleJustCreated=true;
  }
  button.disabled=true;
  const {error:buyerError}=await supabase.rpc('set_sale_customer_details',{p_sale_id:activeSaleId,p_customer_name:$('#customerName').value.trim()||null,p_customer_phone:$('#customerPhone').value.trim()||null});
  if(buyerError){button.disabled=false;message.textContent='Buyer details could not be saved. The sale remains pending; retry or contact the admin.';return}
  if(method==='mpesa'){
    const {data:sale,error:saleError}=await supabase.from('sales').select('sale_number,total_amount,status').eq('id',activeSaleId).single();
    if(saleError||!sale){button.disabled=false;message.textContent=saleError?.message||'Sale details could not be loaded.';return}
    $('#tillReference').textContent=configuredPaybillAccountNumber;
    $('#tillOrderNumber').textContent=sale.sale_number;
    $('#tillAmount').textContent=money(sale.total_amount);
    if(saleJustCreated){
      button.disabled=false;updatePaymentFields();
      message.textContent=`Sale ${sale.sale_number} is pending. Ask the customer to pay ${money(sale.total_amount)}, then enter the receipt code and amount to verify.`;
      return;
    }
    const {data:remaining,error}=await supabase.rpc('verify_manual_mpesa_payment',{p_sale_id:activeSaleId,p_amount:amount,p_transaction_code:transactionCode});
    button.disabled=false;
    if(error){message.textContent=error.message;return}
    outstanding=Number(remaining||0);
    const completedSaleId=activeSaleId;
    await completeMpesaSale(completedSaleId);
    return;
  }
  const normalizedAmount=fromCents(toCents(amount));
  const amountToRecord=method==='cash'?fromCents(Math.min(toCents(normalizedAmount),toCents(outstanding))):normalizedAmount;
  const changeDue=method==='cash'?fromCents(Math.max(0,toCents(normalizedAmount)-toCents(amountToRecord))):0;
  const {data:remaining,error}=await supabase.rpc('add_manual_sale_payment',{p_sale_id:activeSaleId,p_method:method,p_amount:amountToRecord,p_reference:$('#reference').value.trim()||null});
  button.disabled=false;
  if(error){message.textContent=error.message;return}
  outstanding=Number(remaining||0);
  if(outstanding>0){message.textContent=`Payment recorded. Remaining ${money(outstanding)}.`;renderCart();updatePaymentFields();return}
  if(method==='cash'){lastCashTendered=normalizedAmount;lastCashChange=changeDue}
  const completedSaleId=activeSaleId;
  message.textContent=method==='cash'&&changeDue>0?`Sale fully paid. Return ${money(changeDue)} change. Stock update confirmed by the server.`:'Sale fully paid. Stock update confirmed by the server.';
  const confirmedSale=await loadReceiptReference(completedSaleId);
  await showReceipt(completedSaleId,confirmedSale?.sale_number||completedSaleId);
  activeSaleId=null;outstanding=0;cart=[];prescription.value='';$('#reference').value='';$('#customerName').value='';$('#customerPhone').value='';$('#mpesaTransactionCode').value='';
  renderCart();updatePaymentFields();await load();
});

$('#copyTillDetails').addEventListener('click',async()=>{
  const details=`PayBill: ${configuredPaybillNumber}\nAmount: ${$('#tillAmount').textContent}\nAccount number: ${$('#tillReference').textContent}`;
  try{await navigator.clipboard.writeText(details);message.textContent='PayBill number, amount and fixed account number copied.'}
  catch{message.textContent='Copy is unavailable in this browser. Read the payment details to the customer.'}
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

updatePaymentFields();
if(matchMedia('(min-width: 901px)').matches)$('#search').focus({preventScroll:true});
load();
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refreshCatalog()});
window.setInterval(refreshCatalog,30000);
