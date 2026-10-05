import {supabase} from '../../shared/js/supabase.js';
import {requireUser,signOut} from '../../shared/js/auth.js';

const session=await requireUser(['seller']);
if(!session)throw new Error('Unauthorized');
const $=selector=>document.querySelector(selector);
const money=value=>`KSh ${Number(value||0).toLocaleString(undefined,{maximumFractionDigits:2})}`;
const dateKey=date=>`${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
$('#logout').onclick=event=>{event.preventDefault();signOut()};

function localDayRange(){
  const now=new Date(),start=new Date(now.getFullYear(),now.getMonth(),now.getDate()),end=new Date(now.getFullYear(),now.getMonth(),now.getDate()+1);
  return {start:start.toISOString(),end:end.toISOString(),date:dateKey(now)};
}

async function readTodayRows(table,columns,range){
  const pageSize=500,rows=[];
  for(let offset=0;;offset+=pageSize){
    const result=await supabase.from(table).select(columns).gte('created_at',range.start).lt('created_at',range.end).order('created_at',{ascending:false}).order('id',{ascending:false}).range(offset,offset+pageSize-1);
    if(result.error)return {data:null,error:result.error};
    rows.push(...(result.data||[]));
    if((result.data||[]).length<pageSize)return {data:rows,error:null};
  }
}

function renderRecentSales(sales){
  const host=$('#recentSales');host.replaceChildren();
  if(!sales.length){const empty=document.createElement('p');empty.className='muted seller-empty';empty.textContent='No sales recorded today. Start a sale when you are ready.';host.append(empty);return}
  for(const sale of sales.slice(0,7)){
    const row=document.createElement('div');row.className='seller-activity-row';
    const details=document.createElement('span');details.className='seller-activity-main';
    const number=document.createElement('strong');number.textContent=sale.sale_number||'Sale';
    const time=document.createElement('small');time.textContent=new Date(sale.created_at).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
    details.append(number,time);
    const state=document.createElement('span');state.className=`sale-state sale-state-${String(sale.status||'').replace(/[^a-z_]/g,'')}`;state.textContent=String(sale.status||'unknown').replaceAll('_',' ');
    const amount=document.createElement('strong');amount.className='seller-activity-amount';amount.textContent=money(sale.total_amount);
    row.append(details,state,amount);host.append(row);
  }
}

let loading=false;
async function load(){
  if(loading)return;
  loading=true;$('#refreshBtn').disabled=true;$('#msg').textContent='';
  try{
    const range=localDayRange();
    $('#todayLabel').textContent=`Your shift, sales and payments for ${new Date(`${range.date}T12:00:00`).toLocaleDateString(undefined,{weekday:'long',month:'long',day:'numeric'})}.`;
    const [{data:shift,error:shiftError},{data:sales,error:salesError},{data:payments,error:paymentsError}]=await Promise.all([
      supabase.from('shift_sessions').select('status,opened_at').eq('seller_id',session.user.id).eq('status','open').order('opened_at',{ascending:false}).limit(1).maybeSingle(),
      readTodayRows('sales','id,sale_number,total_amount,status,created_at',range),
      readTodayRows('payments','id,amount,status,created_at',range)
    ]);
    if(shiftError)$('#shiftDetail').textContent='Shift status could not be loaded';
    else if(shift?.status==='open'){
      $('#shift').textContent='OPEN';$('#shift').dataset.state='open';
      $('#shiftDetail').textContent=`Opened ${new Date(shift.opened_at).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}`;
    }else{$('#shift').textContent='CLOSED';$('#shift').dataset.state='closed';$('#shiftDetail').textContent='Open a shift before serving customers'}

    if(salesError){$('#todaySales').textContent='—';$('#todaySalesDetail').textContent='Sales could not be loaded';$('#pendingAmount').textContent='—';$('#pendingCount').textContent='Pending sales unavailable';$('#recentSales').textContent='Your sales could not be loaded.'}
    else{
      const rows=sales||[],settled=rows.filter(sale=>['paid','refund_requested','refunded'].includes(sale.status)),pending=rows.filter(sale=>sale.status==='pending_payment');
      $('#todaySales').textContent=settled.length.toLocaleString();$('#todaySalesDetail').textContent=`${money(settled.reduce((total,sale)=>total+Number(sale.total_amount||0),0))} sale value before refunds`;
      $('#pendingAmount').textContent=money(pending.reduce((total,sale)=>total+Number(sale.total_amount||0),0));$('#pendingCount').textContent=`${pending.length} pending sale${pending.length===1?'':'s'}`;
      renderRecentSales(rows);
    }
    if(paymentsError){$('#todayCollections').textContent='Unavailable';$('#todayCollectionsDetail').textContent='Payments could not be loaded'}
    else{
      const rows=payments||[],paid=rows.filter(payment=>payment.status==='paid').reduce((total,payment)=>total+Number(payment.amount||0),0),refunded=rows.filter(payment=>payment.status==='refunded').reduce((total,payment)=>total+Number(payment.amount||0),0);
      $('#todayCollections').textContent=money(paid);$('#todayCollectionsDetail').textContent=`${money(refunded)} refunded`;
    }
    if(shiftError||salesError||paymentsError)$('#msg').textContent='Some workspace figures could not be refreshed. Check your connection and try again.';
  }catch(error){$('#msg').textContent='Workspace figures could not be refreshed. Check your connection and try again.';console.error('Sales dashboard refresh failed',error)}
  finally{loading=false;$('#refreshBtn').disabled=false}
}

window.addEventListener('session-warning',()=>$('#sessionWarning').hidden=false);
$('#stayBtn')?.addEventListener('click',()=>$('#sessionWarning').hidden=true);
$('#refreshBtn').addEventListener('click',load);
load();
setInterval(load,60000);
