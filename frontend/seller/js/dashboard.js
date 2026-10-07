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

function renderRecentSales(sales){
  const host=$('#recentSales');host.replaceChildren();
  if(!sales.length){const empty=document.createElement('p');empty.className='muted seller-empty';empty.textContent='No sales recorded today. Start a sale when you are ready.';host.append(empty);return}
  for(const sale of sales.slice(0,7)){
    const row=document.createElement('div');row.className='seller-activity-row';
    const details=document.createElement('span');details.className='seller-activity-main';
    const number=document.createElement('strong');number.textContent=sale.sale_number||'Sale';
    const time=document.createElement('small');time.textContent=new Date(sale.created_at).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
    details.append(number,time);
    if(sale.status==='pending_payment'){
      const resume=document.createElement('a');resume.href=`/seller/pages/pos/?resume=${encodeURIComponent(sale.id)}`;resume.textContent='Continue payment';resume.className='seller-resume-payment';details.append(resume);
    }
    const state=document.createElement(sale.status==='pending_payment'?'a':'span');state.className=`sale-state sale-state-${String(sale.status||'').replace(/[^a-z_]/g,'')}`;state.textContent=String(sale.status||'unknown').replaceAll('_',' ');
    if(sale.status==='pending_payment')state.href=`/seller/pages/pos/?resume=${encodeURIComponent(sale.id)}`;
    const amount=document.createElement('strong');amount.className='seller-activity-amount';amount.textContent=money(sale.total_amount);
    row.append(details,state,amount);host.append(row);
  }
}

let loading=false;
let refreshTimer=0,reloadQueued=false;
async function load(){
  if(document.visibilityState!=='visible')return;
  if(loading){reloadQueued=true;return}
  loading=true;$('#refreshBtn').disabled=true;$('#msg').textContent='';
  try{
    const range=localDayRange();
    $('#todayLabel').textContent=`${new Date(`${range.date}T12:00:00`).toLocaleDateString(undefined,{weekday:'long',month:'long',day:'numeric'})}.`;
    const [{data:shift,error:shiftError},{data:summary,error:summaryError},{data:recentSales,error:salesError}]=await Promise.all([
      supabase.from('shift_sessions').select('status,opened_at').eq('seller_id',session.user.id).eq('status','open').order('opened_at',{ascending:false}).limit(1).maybeSingle(),
      supabase.rpc('seller_daily_summary'),
      supabase.from('sales').select('id,sale_number,total_amount,status,created_at').eq('seller_id',session.user.id).gte('created_at',range.start).lt('created_at',range.end).order('created_at',{ascending:false}).order('id',{ascending:false}).limit(7)
    ]);
    if(shiftError)$('#shiftDetail').textContent='Shift status could not be loaded';
    else if(shift?.status==='open'){
      $('#shift').textContent='OPEN';$('#shift').dataset.state='open';
      $('#shiftDetail').textContent=`Opened ${new Date(shift.opened_at).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}`;
    }else{$('#shift').textContent='CLOSED';$('#shift').dataset.state='closed';$('#shiftDetail').textContent='Open a shift before serving customers'}

    if(salesError||summaryError){$('#todaySales').textContent='—';$('#todaySalesDetail').textContent='Sales could not be loaded';$('#pendingAmount').textContent='—';$('#pendingCount').textContent='Pending sales unavailable';$('#recentSales').textContent='Your sales could not be loaded.'}
    else{
      const s=summary||{};$('#todaySales').textContent=Number(s.sales_count||0).toLocaleString();$('#todaySalesDetail').textContent=`${money(s.sales_total)} sale value before refunds`;
      $('#pendingAmount').textContent=money(s.pending_amount);$('#pendingCount').textContent=`${Number(s.pending_count||0)} pending sale${Number(s.pending_count)===1?'':'s'}`;
      renderRecentSales(recentSales||[]);
    }
    if(summaryError){$('#todayCollections').textContent='Unavailable';$('#todayCollectionsDetail').textContent='Payments could not be loaded'}
    else{$('#todayCollections').textContent=money(summary?.payments_total);$('#todayCollectionsDetail').textContent=`${money(summary?.refunded_total)} refunded`}
    if(shiftError||salesError||summaryError)$('#msg').textContent='Some workspace figures could not be refreshed. Check your connection and try again.';
  }catch(error){$('#msg').textContent='Workspace figures could not be refreshed. Check your connection and try again.';console.error('Sales dashboard refresh failed',error)}
  finally{loading=false;$('#refreshBtn').disabled=false;if(reloadQueued){reloadQueued=false;window.setTimeout(()=>void load(),0)}}
}

$('#refreshBtn').addEventListener('click',load);
load();
const dashboardRealtime=supabase.channel('seller-home-live-updates')
  .on('postgres_changes',{event:'*',schema:'public',table:'sales',filter:`seller_id=eq.${session.user.id}`},()=>{window.clearTimeout(refreshTimer);refreshTimer=window.setTimeout(()=>void load(),400)})
  .on('postgres_changes',{event:'*',schema:'public',table:'payments'},()=>{window.clearTimeout(refreshTimer);refreshTimer=window.setTimeout(()=>void load(),400)})
  .subscribe();
const dashboardPoll=window.setInterval(()=>{if(document.visibilityState==='visible')void load()},60000);
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')void load()});
window.addEventListener('pagehide',()=>{window.clearInterval(dashboardPoll);window.clearTimeout(refreshTimer);void supabase.removeChannel(dashboardRealtime)},{once:true});
