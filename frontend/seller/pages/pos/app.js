import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';

const session=await requireUser(['seller']);
let medicines=[];
let cart=[];
let activeSaleId=null;
let activeSaleNumber='';
const pendingClaimKey='pharmacy-pending-mpesa-claims';
let awaitingApprovalSaleIds=(()=>{try{return JSON.parse(sessionStorage.getItem(pendingClaimKey)||'[]').filter(id=>typeof id==='string')}catch{return []}})();
let outstanding=0;
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
// Inventory quantity remains the checkout authority while legacy stock is
// being reconciled into batches. Sellers use inventory counts only; payment
// allocation and expiry details remain server-side for Admin reporting.
const sellableStock=medicine=>medicineStock(medicine);
const stockLimit=medicine=>medicine.min_stock==null?5:Number(medicine.min_stock);

async function load(){
  message.textContent='';
  const [{data:medicineData,error:medicineError},{data:prescriptionData},{data:settings}]=await Promise.all([
    supabase.from('medicines').select('id,name,generic_name,brand,barcode,strength,selling_price,min_stock,prescription_required,controlled_medicine,inventory(quantity)').eq('active',true).order('name'),
    supabase.from('prescriptions').select('id,prescription_number,patient_name,status').in('status',['verified','dispensing','dispensed']).order('created_at',{ascending:false}).limit(30),
    supabase.from('pharmacy_settings').select('paybill_number,paybill_account_number,till_number,receipt_signature_path,receipt_signature_name').maybeSingle()
  ]);
  if(medicineError)message.textContent=medicineError.message;
  medicines=medicineData||[];if(!activeSaleId)cart=cart.map(line=>{const current=medicines.find(medicine=>medicine.id===line.id);return current?{...line,price:Number(current.selling_price)}:line});configuredPaybillNumber=String(settings?.paybill_number||settings?.till_number||'').trim();configuredPaybillAccountNumber=String(settings?.paybill_account_number||'').trim();receiptSignatureConfigured=Boolean(settings?.receipt_signature_path&&settings?.receipt_signature_name);$('#tillNumber').textContent=configuredPaybillNumber||'Ask the admin to configure the PayBill number';$('#tillReference').textContent=configuredPaybillAccountNumber||'Ask the admin to configure the PayBill account';
  prescription.innerHTML='<option value="">No prescription</option>'+(prescriptionData||[]).map(item=>`<option value="${escapeHtml(item.id)}">${escapeHtml(item.prescription_number)} — ${escapeHtml(item.patient_name)}</option>`).join('');
  const params=new URLSearchParams(location.search),preset=params.get('prescription');if(preset)prescription.value=preset;
  const resumeId=params.get('resume');
  if(resumeId&&!activeSaleId){
    $('#checkout').disabled=true;message.textContent='Loading the saved sale and its outstanding balance…';
    const [pendingSaleResult,saleLinesResult,paidPaymentResult]=await Promise.all([
      supabase.from('sales').select('id,sale_number,total_amount,status,customer_name,customer_phone').eq('id',resumeId).eq('seller_id',session.user.id).maybeSingle(),
      supabase.from('sale_items').select('medicine_id,quantity,unit_price,medicines(name)').eq('sale_id',resumeId),
      supabase.from('payments').select('amount').eq('sale_id',resumeId).eq('status','paid')
    ]);
    const pendingSale=pendingSaleResult.data,saleLines=saleLinesResult.data,paidPayments=paidPaymentResult.data;
    if(pendingSaleResult.error||saleLinesResult.error||paidPaymentResult.error){message.textContent='Could not restore this saved sale. No new sale was started and recorded payments remain unchanged. Retry from Receipts.'}
    else if(pendingSale?.status==='pending_payment'&&saleLines?.length){
      activeSaleId=pendingSale.id;activeSaleNumber=pendingSale.sale_number||'';outstanding=Math.max(0,Math.round((Number(pendingSale.total_amount)-(paidPayments||[]).reduce((sum,payment)=>sum+Number(payment.amount||0),0))*100)/100);cart=saleLines.map(item=>({id:item.medicine_id,name:item.medicines?.name||'Medicine',price:Number(item.unit_price),quantity:Number(item.quantity)}));
      $('#customerName').value=pendingSale.customer_name||'';$('#customerPhone').value=pendingSale.customer_phone||'';$('#method').disabled=false;
      $('#tillOrderNumber').textContent=pendingSale.sale_number;$('#tillAmount').textContent=money(pendingSale.total_amount);updatePaymentFields();
      if(outstanding>0){message.textContent=`Resumed ${pendingSale.sale_number}. ${money(outstanding)} remains. Continue here to record payment against this same sale.`;$('#checkout').disabled=false}
      else{message.textContent=`${pendingSale.sale_number} has no balance remaining. Refresh My Receipts to confirm its final status.`;$('#checkout').disabled=true}
    }else if(pendingSale?.status==='pending_payment')message.textContent='This saved sale has no readable items, so payment is blocked to prevent creating a different sale.';
    else message.textContent=pendingSale?'This sale is no longer pending payment. Refresh Receipts for its current status.':'This pending sale could not be found for your account.';
    if(pendingSale?.status!=='pending_payment'||!pendingSale||pendingSaleResult.error||saleLinesResult.error||paidPaymentResult.error)$('#checkout').disabled=true;
    history.replaceState({},'',location.pathname);
  }
  renderMedicines();renderCart();
}

let catalogRefreshInProgress=false;
let catalogSignature='';
async function refreshCatalog(){
  if(catalogRefreshInProgress||document.visibilityState!=='visible')return;
  catalogRefreshInProgress=true;
  try{
    const {data:medicineData,error:medicineError}=await supabase.from('medicines').select('id,name,generic_name,brand,barcode,strength,selling_price,min_stock,prescription_required,controlled_medicine,inventory(quantity)').eq('active',true).order('name');
    if(medicineError)return;
    const nextMedicines=medicineData||[];
    const nextSignature=JSON.stringify(nextMedicines);
    if(nextSignature===catalogSignature)return;
    catalogSignature=nextSignature;
    medicines=nextMedicines;
    if(!activeSaleId)cart=cart.filter(line=>medicines.some(medicine=>medicine.id===line.id)).map(line=>{const current=medicines.find(medicine=>medicine.id===line.id);return {...line,name:current.name,price:Number(current.selling_price)}});
    renderMedicines();renderCart();
  }finally{catalogRefreshInProgress=false}
}

function addMedicine(id){
  const medicine=medicines.find(item=>item.id===id);if(!medicine)return;
  if(sellableStock(medicine)<=0){message.textContent='No inventory is available for this medicine.';return}
  const line=cart.find(item=>item.id===medicine.id);
  if(line){
    const available=sellableStock(medicine);
    if(line.quantity>=available){message.textContent='Quantity cannot exceed available stock.';return}
    line.quantity+=1;
  }
  else cart.push({id:medicine.id,name:medicine.name,price:Number(medicine.selling_price),quantity:1});
  message.textContent='';renderCart();
}

function renderMedicines(){
  const term=$('#search').value.trim().toLowerCase();
  const allMatches=medicines.filter(item=>`${item.name} ${item.generic_name||''} ${item.brand||''} ${item.barcode||''} ${item.strength||''}`.toLowerCase().includes(term));
  const availableMatches=allMatches.filter(item=>sellableStock(item)>0);
  const matches=availableMatches.slice(0,60);
  $('#medicineResultsMeta').textContent=allMatches.length===0?'Search by name or scan a barcode.':availableMatches.length===0?'No matching medicines are currently in stock.':availableMatches.length>60?`Showing 60 of ${availableMatches.length} in-stock medicines. Refine your search to find a specific item.`:`${availableMatches.length} in-stock medicine${availableMatches.length===1?'':'s'} found`;
  list.innerHTML=matches.map(item=>{
    const stock=sellableStock(item),flags=[item.prescription_required?'Prescription required':'',item.controlled_medicine?'Controlled medicine':''].filter(Boolean).join(' · '),low=stock>0&&stock<=stockLimit(item);
    const warnings=low?'Low stock':'';
    return `<article class="medicine ${low?'low-stock':''}"><span><strong>${escapeHtml(item.name)} ${escapeHtml(item.strength||'')}</strong><br><small>${money(item.selling_price)} · Stock ${stock}${warnings?` · <span class="stock-warning">${escapeHtml(warnings)}</span>`:''}${flags?` · ${escapeHtml(flags)}`:''}</small></span><button class="btn secondary" type="button" data-add="${escapeHtml(item.id)}" ${stock<=0?'disabled':''} aria-label="Add ${escapeHtml(item.name)} to sale">Add</button></article>`;
  }).join('')||'<p class="muted empty-results">No matching medicines.</p>';
  list.querySelectorAll('[data-add]').forEach(button=>button.addEventListener('click',()=>addMedicine(button.dataset.add)));
}

function renderCart(){
  cartElement.innerHTML=cart.map((item,index)=>{
    const medicine=medicines.find(m=>m.id===item.id),stock=medicine?sellableStock(medicine):0;
    return `<div class="cart-line"><div><strong>${escapeHtml(item.name)}</strong><small>${money(item.price)} each · ${stock} available</small></div><div class="quantity-control"><button type="button" data-quantity="-1" data-index="${index}" aria-label="Decrease ${escapeHtml(item.name)} quantity">−</button><output>${item.quantity}</output><button type="button" data-quantity="1" data-index="${index}" aria-label="Increase ${escapeHtml(item.name)} quantity" ${item.quantity>=stock?'disabled':''}>+</button><button type="button" class="remove-line" data-remove="${index}" aria-label="Remove ${escapeHtml(item.name)} from cart">Remove</button></div><strong class="line-total">${money(item.price*item.quantity)}</strong></div>`;
  }).join('')||'<p class="muted empty-cart">Cart is empty. Search or scan to add a medicine.</p>';
  const cartAvailable=(item)=>{
    const medicine=medicines.find(m=>m.id===item.id)||{};
    return sellableStock(medicine);
  };
  cartElement.querySelectorAll('[data-quantity]').forEach(button=>button.addEventListener('click',()=>{
    const index=Number(button.dataset.index),next=cart[index].quantity+Number(button.dataset.quantity);
    if(next>0&&next>cartAvailable(cart[index])){message.textContent='Quantity cannot exceed available stock.';return}
    if(next<=0)cart.splice(index,1);else cart[index].quantity=next;
    renderCart();
  }));
  cartElement.querySelectorAll('[data-remove]').forEach(button=>button.addEventListener('click',()=>{cart.splice(Number(button.dataset.remove),1);renderCart()}));
  const total=fromCents(cart.reduce((sum,item)=>sum+toCents(item.price)*item.quantity,0));
  const amountDue=activeSaleId?outstanding:total;
  totalElement.textContent=money(amountDue);
  $('#tillAmount').textContent=money(amountDue);
  $('#outstanding').textContent=`Outstanding: ${money(amountDue)}`;
  const itemCount=cart.reduce((sum,item)=>sum+item.quantity,0),countText=`${itemCount} item${itemCount===1?'':'s'}`;
  $('#cartCount').textContent=countText;
  $('#mobileCartCount').textContent=countText;
  $('#mobileCartTotal').textContent=money(total);
  $('#mobileCartSummary').hidden=itemCount===0;
  $('#paymentAmount').value=Number(amountDue).toFixed(2);
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
  $('#newSaleFromPending').hidden=!activeSaleId;
  const isMpesa=$('#method').value==='mpesa';
  $('#tillInstructions').hidden=!isMpesa;
  $('#copyTillDetails').disabled=!activeSaleId;
  $('#mpesaTransactionCode').hidden=!isMpesa||!activeSaleId;$('#transactionCodeLabel').hidden=!isMpesa||!activeSaleId;
  $('#reference').hidden=isMpesa;$('#paymentAmount').hidden=false;$('#amountLabel').hidden=false;
  $('#paymentAmount').readOnly=isMpesa;
  $('#amountLabel').textContent=isMpesa&&activeSaleId?'Sale amount to verify':'Sale amount';
  if(!isMpesa)$('#amountLabel').textContent=$('#method').value==='cash'?'Cash tendered':'Payment amount';
  $('#paymentAmount').placeholder=$('#method').value==='cash'?'Enter cash received':'Enter amount received';
  $('#manualPaymentHint').textContent=isMpesa?'Enter the receipt code. The seller records this payment immediately; it is marked seller reported, not Safaricom verified.':$('#method').value==='cash'?'Enter the cash received.':'Enter the amount received.';
  $('#manualPaymentHint').hidden=false;
  $('#checkout').textContent=isMpesa?(activeSaleId?'Record M-Pesa payment':'Start M-Pesa sale'):activeSaleId?'Record payment':'Continue to payment';
}
$('#method').addEventListener('change',updatePaymentFields);
$('#newSaleFromPending').addEventListener('click',()=>{
  activeSaleId=null;activeSaleNumber='';outstanding=0;cart=[];prescription.value='';$('#reference').value='';$('#mpesaTransactionCode').value='';$('#customerName').value='';$('#customerPhone').value='';$('#method').disabled=false;$('#receiptPreview').hidden=true;
  renderCart();updatePaymentFields();
  message.textContent='This sale remains saved as pending with all recorded payments intact. Start another sale now, or resume it later from My Receipts.';
});

async function showReceipt(saleId,saleNumber=saleId){
  const body=$('#receiptBody'),printButton=$('#printReceipt');
  const customerName=$('#customerName').value.trim(),customerPhone=$('#customerPhone').value.trim();
  printButton.disabled=true;
  const [{data:sale,error},{data:saleItems,error:itemsError},{data:payments,error:paymentError}]=await Promise.all([
    supabase.from('sales').select('created_at,total_amount,authorized_signature_path,authorized_signature_name,signature_applied_at').eq('id',saleId).single(),
    supabase.from('sale_items').select('quantity,unit_price,total,medicines(name,strength)').eq('sale_id',saleId),
    supabase.from('payments').select('amount,method,cash_tendered,change_due').eq('sale_id',saleId).eq('status','paid'),
  ]);
  if(error||itemsError||paymentError||!sale?.authorized_signature_path||!sale.authorized_signature_name||!sale.signature_applied_at){body.innerHTML='<p>The signed receipt could not be prepared. Ask the Admin to check the receipt signature settings.</p>';$('#receiptPreview').hidden=false;return}
  const {data:signature,error:signatureError}=await supabase.storage.from('receipt-signatures').createSignedUrl(sale.authorized_signature_path,300);
  if(signatureError||!signature?.signedUrl){body.innerHTML='<p>The receipt signature is unavailable. Ask the Admin to check private signature storage.</p>';$('#receiptPreview').hidden=false;return}
  const verifyUrl=`${location.origin}/verify/?receipt=${encodeURIComponent(saleNumber)}`;
  const itemCount=(saleItems||[]).reduce((sum,item)=>sum+Number(item.quantity||0),0),productCount=(saleItems||[]).length;
  const paymentMethods=[...new Set((payments||[]).map(payment=>payment.method))].join(', '),cashTendered=(payments||[]).reduce((sum,payment)=>sum+Math.round(Number(payment.cash_tendered||0)*100),0)/100,cashChange=(payments||[]).reduce((sum,payment)=>sum+Math.round(Number(payment.change_due||0)*100),0)/100;
  body.innerHTML=`<p><span>Receipt number</span><strong>${escapeHtml(saleNumber)}</strong></p>${customerName?`<p><span>Buyer</span><strong>${escapeHtml(customerName)}</strong></p>`:''}${customerPhone?`<p><span>Buyer phone</span><strong>${escapeHtml(customerPhone)}</strong></p>`:''}<p><span>Completed</span><strong>${escapeHtml(new Date(sale.created_at).toLocaleString())}</strong></p>${(saleItems||[]).map(item=>`<p><span>${escapeHtml(item.medicines?.name||'Medicine')} ${escapeHtml(item.medicines?.strength||'')}<br>${money(item.unit_price)} × ${Number(item.quantity||0)}</span><strong>${money(item.total)}</strong></p>`).join('')}<p><span>Total drugs</span><strong>${itemCount} unit${itemCount===1?'':'s'} across ${productCount} medicine${productCount===1?'':'s'}</strong></p><p><span>Payment</span><strong>${escapeHtml(paymentMethods||'—')}</strong></p><p class="receipt-grand-total"><span>Total paid</span><strong>${money(sale.total_amount)}</strong></p>${cashTendered?`<p><span>Cash received</span><strong>${money(cashTendered)}</strong></p><p><span>Change</span><strong>${money(cashChange)}</strong></p>`:''}<div class="receipt-admin-signature"><img src="${escapeHtml(signature.signedUrl)}" alt="Authorized administrator signature"><div>Authorized by <strong>${escapeHtml(sale.authorized_signature_name)}</strong></div><small>Verify this receipt: <a href="${escapeHtml(verifyUrl)}">${escapeHtml(verifyUrl)}</a></small></div>`;
  printButton.disabled=false;
  $('#receiptPreview').hidden=false;
  $('#receiptPreview').scrollIntoView({behavior:'smooth',block:'nearest'});
}
async function loadReceiptReference(saleId){const {data}=await supabase.from('sales').select('sale_number,total_amount,status,created_at').eq('id',saleId).single();return data?.status==='paid'?data:null}
$('#printReceipt').addEventListener('click',async()=>{const signature=$('#receiptBody img[alt="Authorized administrator signature"]');if(signature){try{await signature.decode()}catch{message.textContent='The admin signature did not load. The receipt was not printed.';return}}window.print()});

$('#checkout').addEventListener('click',async()=>{
  const button=$('#checkout');if(button.disabled)return;
  if(!receiptSignatureConfigured){message.textContent='Ask the Admin to save the receipt signature in Pharmacy Settings before completing sales.';return}
  const method=$('#method').value;
  const amount=Number($('#paymentAmount').value);
  let saleJustCreated=false;
  if(method==='mpesa'&&(!configuredPaybillNumber||!configuredPaybillAccountNumber)){message.textContent='Ask the admin to configure the pharmacy PayBill and account numbers first.';return}
  if(method==='mpesa'&&!Number.isInteger(amount)){message.textContent='M-Pesa PayBill requires a whole-shilling total. Use Cash or another method for this sale.';return}
  if(method!=='mpesa'&&(!Number.isFinite(amount)||amount<=0)){ $('#paymentAmount').focus();message.textContent='Enter a valid payment amount.';return}
  if(!activeSaleId){
    if(!cart.length){message.textContent='Cart is empty.';return}
    button.disabled=true;
    const {data:saleId,error}=await supabase.rpc('create_sale',{p_items:cart.map(item=>({medicine_id:item.id,quantity:item.quantity,unit_price:item.price})),p_prescription_id:prescription.value||null});
    button.disabled=false;
    if(error){message.textContent=error.message;return}
    if(!saleId){await load();message.textContent='A medicine price changed or did not match the current catalogue. The sale was blocked and logged for Admin review. Check the updated prices and try again.';return}
    activeSaleId=saleId;
    const {data:savedSale,error:savedSaleError}=await supabase.from('sales').select('sale_number,total_amount').eq('id',saleId).single();
    if(savedSaleError||!savedSale){message.textContent='Sale saved as pending, but its total could not be loaded. Refresh and resume the pending sale before taking payment.';return}
    activeSaleNumber=savedSale.sale_number||'';outstanding=Number(savedSale.total_amount);
    saleJustCreated=true;
  }
  button.disabled=true;
  const {error:buyerError}=await supabase.rpc('set_sale_customer_details',{p_sale_id:activeSaleId,p_customer_name:$('#customerName').value.trim()||null,p_customer_phone:$('#customerPhone').value.trim()||null});
  if(buyerError){button.disabled=false;message.textContent='Buyer details could not be saved. The sale remains pending; retry or contact the admin.';return}
  if(method==='mpesa'&&saleJustCreated){
    const {data:sale,error:saleError}=await supabase.from('sales').select('sale_number,total_amount,status').eq('id',activeSaleId).single();
    if(saleError||!sale){button.disabled=false;message.textContent=saleError?.message||'Sale details could not be loaded.';return}
    $('#tillReference').textContent=configuredPaybillAccountNumber;
    $('#tillOrderNumber').textContent=sale.sale_number;
    $('#tillAmount').textContent=money(sale.total_amount);
    $('#method').disabled=true;
    button.disabled=false;updatePaymentFields();
    message.textContent=`Sale ${sale.sale_number} is ready for ${money(sale.total_amount)}. After receiving payment to PayBill ${configuredPaybillNumber}, account ${configuredPaybillAccountNumber}, enter the customer's receipt code. Recording it completes the sale without Admin approval; the code is marked seller reported.`;
    return;
  }
  if(method==='mpesa'){
    const transactionCode=$('#mpesaTransactionCode').value.trim().toUpperCase();
    if(!transactionCode){button.disabled=false;$('#mpesaTransactionCode').focus();message.textContent='Enter the receipt code from the customer M-Pesa confirmation message.';return}
  }
  const normalizedAmount=fromCents(toCents(amount));
  const amountToRecord=method==='cash'?fromCents(Math.min(toCents(normalizedAmount),toCents(outstanding))):normalizedAmount;
  const changeDue=method==='cash'?fromCents(Math.max(0,toCents(normalizedAmount)-toCents(amountToRecord))):0;
  const paymentReference=method==='mpesa'?$('#mpesaTransactionCode').value.trim().toUpperCase():$('#reference').value.trim()||null;
  const {data:remaining,error}=await supabase.rpc('add_manual_sale_payment',{p_sale_id:activeSaleId,p_method:method,p_amount:method==='mpesa'?outstanding:amountToRecord,p_reference:paymentReference,p_cash_tendered:method==='cash'?normalizedAmount:null});
  button.disabled=false;
  if(error){
    const detail=String(error.message||'');
    message.textContent=/insufficient unexpired batch stock/i.test(detail)
      ?`${detail}. No payment was recorded. Ask the Admin to enter the real batch number and expiry for this stock, then retry.`
      :detail;
    return;
  }
  outstanding=Number(remaining||0);
  if(outstanding>0){
    const remainingBalance=outstanding;
    $('#mpesaTransactionCode').value='';$('#reference').value='';
    renderCart();updatePaymentFields();await load();
    message.textContent=`Payment saved to ${activeSaleNumber||'this sale'}. ${money(remainingBalance)} remains on the same sale. Continue its payment here, or choose Start another sale.`;
    return;
  }
  const completedSaleId=activeSaleId;
  message.textContent=method==='cash'&&changeDue>0?`Sale fully paid. Return ${money(changeDue)} change. Stock update confirmed by the server.`:method==='mpesa'?'Sale fully paid. The M-Pesa code is recorded as seller reported; receipt issued and stock updated.':'Sale fully paid. Stock update confirmed by the server.';
  const confirmedSale=await loadReceiptReference(completedSaleId);
  await showReceipt(completedSaleId,confirmedSale?.sale_number||completedSaleId);
  activeSaleId=null;activeSaleNumber='';outstanding=0;cart=[];prescription.value='';$('#reference').value='';$('#mpesaTransactionCode').value='';$('#customerName').value='';$('#customerPhone').value='';$('#method').disabled=false;
  renderCart();updatePaymentFields();await load();
});

$('#copyTillDetails').addEventListener('click',async()=>{
  const details=`PayBill: ${configuredPaybillNumber}\nAmount: ${$('#tillAmount').textContent}\nAccount number: ${$('#tillReference').textContent}\nSale number: ${$('#tillOrderNumber').textContent}`;
  try{await navigator.clipboard.writeText(details);message.textContent='PayBill, amount, account number and sale number copied.'}
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
if(new URLSearchParams(location.search).has('resume')){message.textContent='Loading the saved sale and its outstanding balance…';$('#checkout').disabled=true}
load();
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refreshCatalog()});
window.setInterval(refreshCatalog,60000);
let checkingClaimStatus=false;
async function checkClaimStatuses(){
  if(checkingClaimStatus||!awaitingApprovalSaleIds.length||document.visibilityState!=='visible')return;
  checkingClaimStatus=true;
  try{
    const {data,error}=await supabase.rpc('seller_manual_mpesa_claim_status',{p_sale_ids:awaitingApprovalSaleIds});
    if(error||!data?.length)return;
    const completed=data.filter(item=>item.claim_status==='approved'),rejected=data.filter(item=>item.claim_status==='rejected');
    if(!completed.length&&!rejected.length)return;
    const resolved=new Set([...completed,...rejected].map(item=>item.sale_id));
    awaitingApprovalSaleIds=awaitingApprovalSaleIds.filter(id=>!resolved.has(id));
    try{sessionStorage.setItem(pendingClaimKey,JSON.stringify(awaitingApprovalSaleIds))}catch{}
    if(completed.length)message.textContent=`PayBill statement matched payment for ${completed.map(item=>item.sale_number).join(', ')}. Stock is updated and the receipt is in My Receipts.`;
    else message.textContent=`Admin rejected the M-Pesa code for ${rejected.map(item=>item.sale_number).join(', ')}. Check the customer's payment message and contact Admin.`;
    await refreshCatalog();
  }finally{checkingClaimStatus=false}
}
const posRealtime=supabase.channel('seller-pos-live-updates')
  .on('postgres_changes',{event:'*',schema:'public',table:'medicines'},()=>void refreshCatalog())
  .on('postgres_changes',{event:'*',schema:'public',table:'inventory'},()=>void refreshCatalog())
  .on('postgres_changes',{event:'UPDATE',schema:'public',table:'sales'},()=>void checkClaimStatuses())
  .subscribe();
window.setInterval(checkClaimStatuses,30000);
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')void checkClaimStatuses()});
window.addEventListener('pagehide',()=>{void supabase.removeChannel(posRealtime)},{once:true});
