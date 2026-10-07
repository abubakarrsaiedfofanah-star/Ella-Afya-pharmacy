import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);

const rows=document.querySelector('#rows'),msg=document.querySelector('#msg'),claimRows=document.querySelector('#claimRows'),claimMsg=document.querySelector('#claimMsg'),statementFile=document.querySelector('#statementFile'),statementMsg=document.querySelector('#statementMsg'),statementPreview=document.querySelector('#statementPreview'),importStatementButton=document.querySelector('#importStatement'),esc=window.pharmacyUI.escapeHtml;
const money=value=>`KSh ${Number(value||0).toLocaleString(undefined,{minimumFractionDigits:0,maximumFractionDigits:2})}`;
let loading=false,reloadQueued=false;
let statementRows=[];

function parseCsv(text){
  const rows=[];let row=[],cell='',quoted=false;
  for(let i=0;i<text.length;i++){
    const char=text[i];
    if(quoted){if(char==='"'&&text[i+1]==='"'){cell+='"';i++}else if(char==='"')quoted=false;else cell+=char;continue}
    if(char==='"'){quoted=true;continue}
    if(char===','){row.push(cell);cell='';continue}
    if(char==='\n'||char==='\r'){if(char==='\r'&&text[i+1]==='\n')i++;row.push(cell);if(row.some(value=>value.trim()))rows.push(row);row=[];cell='';continue}
    cell+=char;
  }
  if(quoted)throw new Error('The CSV has an unfinished quoted field.');
  row.push(cell);if(row.some(value=>value.trim()))rows.push(row);
  if(rows.length<2)throw new Error('The CSV needs a header row and at least one transaction.');
  const key=value=>value.toLowerCase().replace(/[^a-z0-9]/g,'');
  const headerRowIndex=rows.slice(0,10).findIndex(candidate=>{const normalized=candidate.map(key);return normalized.some(value=>['transactioncode','transcode','transid','transactionid','receiptno','receiptnumber','receipt','mpesacode','mpesareceipt','mpesareceiptnumber','receiptcode'].includes(value))&&normalized.some(value=>['paidin','paidinkes','credit','creditedamount','amount','amountkes','transactionamount','paidamount'].includes(value))});
  if(headerRowIndex<0)throw new Error('Could not find transaction code and paid-in amount columns. Use headers such as Receipt No. and Paid In.');
  const headers=rows[headerRowIndex].map(key);
  const codeIndex=headers.findIndex(value=>['transactioncode','transcode','transid','transactionid','receiptno','receiptnumber','receipt','mpesacode','mpesareceipt','mpesareceiptnumber','receiptcode'].includes(value));
  const paidInIndex=headers.findIndex(value=>['paidin','paidinkes','credit','creditedamount','paidamount'].includes(value));
  const amountIndex=paidInIndex>=0?paidInIndex:headers.findIndex(value=>['amount','amountkes','transactionamount'].includes(value));
  const statusIndex=headers.findIndex(value=>['status','transactionstatus'].includes(value));
  if(codeIndex<0||amountIndex<0)throw new Error('Could not find transaction code and paid-in amount columns. Use headers such as Receipt No. and Paid In.');
  const valid=[],skipped=[];
  for(let i=headerRowIndex+1;i<rows.length;i++){
    const cells=rows[i],code=(cells[codeIndex]||'').trim().toUpperCase(),status=statusIndex>=0?(cells[statusIndex]||'').trim().toLowerCase():'';
    if(status&&/(pending|failed|revers|cancel|declin)/.test(status)){skipped.push(i+1);continue}
    const amountText=(cells[amountIndex]||'').replace(/[\s,]/g,'').replace(/^(KES|KSH)/i,'');
    const amount=Number(amountText);
    if(!/^[A-Z0-9]{6,64}$/.test(code)||!Number.isFinite(amount)||amount<=0){skipped.push(i+1);continue}
    valid.push({transaction_code:code,amount});
  }
  if(!valid.length)throw new Error('No valid paid-in transactions were found in this CSV.');
  return {valid,skipped};
}

statementFile.addEventListener('change',async()=>{
    statementRows=[];importStatementButton.disabled=true;statementMsg.textContent='';statementPreview.hidden=true;statementPreview.replaceChildren();
  const file=statementFile.files?.[0];if(!file)return;
  if(file.size>10*1024*1024){statementMsg.textContent='Statement file is too large. Maximum size is 10 MB.';return}
  try{
    const parsed=parseCsv(await file.text());statementRows=parsed.valid;importStatementButton.disabled=false;
    statementPreview.innerHTML=`<table class="table"><thead><tr><th>Receipt code</th><th>Paid in</th></tr></thead><tbody>${parsed.valid.slice(0,8).map(item=>`<tr><td>${esc(item.transaction_code)}</td><td>${money(item.amount)}</td></tr>`).join('')}</tbody></table>${parsed.valid.length>8?`<small>Showing 8 of ${parsed.valid.length} valid transactions.</small>`:''}`;statementPreview.hidden=false;
    statementMsg.textContent=`Ready to import ${parsed.valid.length} paid-in transaction(s). ${parsed.skipped.length?`${parsed.skipped.length} empty, invalid or non-success row(s) will be skipped.`:''} Confirm this file came from the pharmacy PayBill account.`;
  }catch(error){statementMsg.textContent=error.message}
});

importStatementButton.addEventListener('click',async()=>{
  const file=statementFile.files?.[0];if(!file||!statementRows.length)return;
  if(!window.confirm(`Import ${statementRows.length} transactions from "${file.name}" as trusted PayBill data? Matching sales will be completed and stock deducted.`))return;
  importStatementButton.disabled=true;statementMsg.textContent='Importing statement and matching seller claims…';
  const {data,error}=await supabase.rpc('admin_import_mpesa_statement',{p_transactions:statementRows,p_source_name:file.name});
  if(error){statementMsg.textContent=`Import failed: ${error.message}`;importStatementButton.disabled=false;return}
  statementMsg.textContent=`Import complete: ${data.new_transactions} new transaction(s), ${data.matched_claims} sale(s) completed, ${data.amount_mismatches} amount mismatch(es) rejected, ${data.unmatched_transactions} transaction(s) waiting for a seller claim.`;
  statementRows=[];statementFile.value='';await Promise.all([load(),loadClaims()]);
});

async function loadClaims(){
  const {data,error}=await supabase.rpc('admin_manual_mpesa_claims');
  if(error){claimMsg.textContent='Manual M-Pesa claims could not be loaded. Apply migrations 039 through 041, then refresh.';return}
  claimRows.innerHTML=(data||[]).map(claim=>`<tr><td>${esc(claim.sale_number)}</td><td>${esc(claim.seller_name)}</td><td>${money(claim.amount)}</td><td><strong>${esc(claim.transaction_code)}</strong></td><td>${esc(new Date(claim.submitted_at).toLocaleString())}</td><td>Awaiting statement</td></tr>`).join('')||'<tr><td colspan="6">No older claims are waiting for a statement match.</td></tr>';
  claimMsg.textContent=(data||[]).length?`${data.length} older claim(s) can be reconciled by importing an official PayBill statement. New sales do not wait for Admin.`:'';
}

async function load(){
  if(document.visibilityState!=='visible')return;
  if(loading){reloadQueued=true;return}
  loading=true;
  const {data:sales,error}=await supabase.from('sales').select('id,sale_number,total_amount,status,created_at,seller_id').order('created_at',{ascending:false}).limit(100);
  if(error){msg.textContent='Sales could not be loaded. Try refreshing the page.';finishLoad();return}
  const ids=(sales||[]).map(sale=>sale.id),sellerIds=[...new Set((sales||[]).map(sale=>sale.seller_id))];
  if(!ids.length){rows.innerHTML='<tr><td colspan="6">No sales recorded.</td></tr>';msg.textContent='';finishLoad();return}
  const [itemsResult,profilesResult,paymentsResult]=await Promise.all([
    supabase.from('sale_items').select('sale_id,quantity,unit_price,total,medicines(name,strength)').in('sale_id',ids),
    supabase.from('profiles').select('id,full_name').in('id',sellerIds),
    supabase.from('payments').select('sale_id,amount,method,status,verification_source,mpesa_receipt').in('sale_id',ids)
  ]);
  if(itemsResult.error||profilesResult.error||paymentsResult.error){msg.textContent='Sale details could not be loaded. Check the Admin data permissions.';finishLoad();return}
  const staff=new Map((profilesResult.data||[]).map(profile=>[profile.id,profile.full_name||'Sales staff']));
  const bySale=new Map();for(const item of itemsResult.data||[]){const bucket=bySale.get(item.sale_id)||[];bucket.push(item);bySale.set(item.sale_id,bucket)}
  const payBySale=new Map();for(const payment of paymentsResult.data||[]){const bucket=payBySale.get(payment.sale_id)||[];bucket.push(payment);payBySale.set(payment.sale_id,bucket)}
  rows.innerHTML=(sales||[]).map(sale=>{
    const lines=bySale.get(sale.id)||[],payments=payBySale.get(sale.id)||[];
    const products=lines.map(item=>`${esc(item.medicines?.name||'Medicine')}${item.medicines?.strength?` ${esc(item.medicines.strength)}`:''} × ${Number(item.quantity)}`).join('<br>')||'No items';
    const paidAmount=payments.filter(payment=>payment.status==='paid').reduce((sum,payment)=>sum+Number(payment.amount||0),0);
    const methods=[...new Set(payments.map(payment=>payment.method))].join(', ')||'Not paid';
    const sellerReported=payments.filter(payment=>payment.method==='mpesa'&&payment.verification_source==='seller_attested'&&payment.status==='paid').map(payment=>esc(payment.mpesa_receipt||'code entered'));
    const manualCodes=payments.filter(payment=>payment.method==='mpesa'&&payment.verification_source==='manual'&&payment.status==='paid').map(payment=>esc(payment.mpesa_receipt||'manual'));
    const verification=[sellerReported.length?`<small class="manual-verification">Seller reported, unverified: ${sellerReported.join(', ')}</small>`:'',manualCodes.length?`<small class="manual-verification">Manually verified M-Pesa: ${manualCodes.join(', ')}</small>`:''].join('');
    const balance=Math.max(0,Number(sale.total_amount)-paidAmount);
    const collection=paidAmount>0?`<small>${money(paidAmount)} received${balance>0?` · ${money(balance)} remaining`:''}</small>`:'';
    return `<tr><td><strong>${esc(sale.sale_number)}</strong><small>${esc(new Date(sale.created_at).toLocaleString())}</small></td><td>${esc(staff.get(sale.seller_id)||'Sales staff')}</td><td>${products}</td><td>${money(sale.total_amount)}</td><td><span class="sale-status sale-${esc(sale.status)}">${esc(sale.status.replaceAll('_',' '))}</span></td><td>${esc(methods)}${collection}${verification}</td></tr>`
  }).join('');
  msg.textContent=`Showing ${sales.length} latest sales. Live updates are enabled.`;
  finishLoad();
}

function finishLoad(){
  loading=false;
  if(reloadQueued){reloadQueued=false;window.setTimeout(()=>void load(),0)}
}

load();loadClaims();
document.querySelector('#refreshSales').addEventListener('click',load);
const salesRealtime=supabase.channel('admin-sales-live-updates')
  .on('postgres_changes',{event:'*',schema:'public',table:'sales'},()=>{if(loading)reloadQueued=true;else void load()})
  .on('postgres_changes',{event:'*',schema:'public',table:'payments'},()=>{if(loading)reloadQueued=true;else void load()})
  .subscribe();
const salesRefreshTimer=window.setInterval(load,60000);
const claimsRefreshTimer=window.setInterval(loadClaims,60000);
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'){void load();void loadClaims()}});
window.addEventListener('pagehide',()=>{window.clearInterval(salesRefreshTimer);window.clearInterval(claimsRefreshTimer);void supabase.removeChannel(salesRealtime)},{once:true});
