import {supabase} from '../../shared/js/supabase.js';
import {requireUser,signOut} from '../../shared/js/auth.js';
import {downloadCsv,dateRange} from '../../shared/js/csv.js';
const session=await requireUser(['admin']); if(!session) throw new Error('Unauthorized');
const $=s=>document.querySelector(s), money=v=>'KSh '+Number(v||0).toLocaleString(undefined,{maximumFractionDigits:2});
const safeRpc=name=>supabase.rpc(name).catch(error=>({data:null,error}));
function animateMetric(selector,formatted){const element=$(selector);if(!element)return;const targetText=String(formatted),target=Number(targetText.replace(/[^\d.-]/g,'')),current=Number(element.textContent.replace(/[^\d.-]/g,''));if(!Number.isFinite(target)||!Number.isFinite(current)||current===target||matchMedia('(prefers-reduced-motion: reduce)').matches){element.textContent=targetText;return}const prefix=targetText.match(/^[^\d-]*/)?.[0]||'',suffix=targetText.match(/[^\d.]*$/)?.[0]||'',started=performance.now(),duration=460,token=String(Number(element.dataset.countToken||0)+1);element.dataset.countToken=token;const step=now=>{if(element.dataset.countToken!==token)return;const progress=Math.min(1,(now-started)/duration),eased=1-Math.pow(1-progress,3),value=current+(target-current)*eased;element.textContent=prefix+value.toLocaleString(undefined,{maximumFractionDigits:2})+suffix;if(progress<1)requestAnimationFrame(step);else element.textContent=targetText};requestAnimationFrame(step)}
$('#logout').onclick=e=>{e.preventDefault();signOut()};
const today=new Date().toISOString().slice(0,10);$('#fromDate').value=today;$('#toDate').value=today;

async function exportData(){const range=dateRange($('#fromDate'),$('#toDate'));const {data,error}=await supabase.rpc('admin_csv_export',range);if(error){$('#msg').textContent=error.message;return null}return data||{}}
$('#exportSales').onclick=async()=>downloadCsv(`pharmacy-sales-${$('#fromDate').value}-${$('#toDate').value}.csv`,(await exportData())?.sales);
$('#exportPayments').onclick=async()=>downloadCsv(`pharmacy-payments-${$('#fromDate').value}-${$('#toDate').value}.csv`,(await exportData())?.payments);
$('#exportInventory').onclick=async()=>downloadCsv(`pharmacy-inventory-${today}.csv`,(await exportData())?.inventory);
$('#exportExpenses').onclick=async()=>downloadCsv(`pharmacy-expenses-${$('#fromDate').value}-${$('#toDate').value}.csv`,(await exportData())?.expenses);
async function load(){ $('#msg').textContent=''; const [overviewResult,lifetimeResult,opsResult,summaryResult,analyticsResult,valuationResult]=await Promise.all(['admin_financial_overview','admin_lifetime_dashboard','admin_operations_snapshot','dashboard_summary','admin_dashboard_analytics','admin_inventory_valuation'].map(safeRpc)); const {data,error}=overviewResult; if(error){$('#msg').textContent=error.message;return} const x=data||{},t=x.today||{},week=x.week||[],sellers=x.sellers||[];
  const {data:lifetimeData,error:lifetimeError}=lifetimeResult;
  if(lifetimeError||!lifetimeData?.lifetime){$('#profitabilityStatus').textContent='Report setup needed';$('#lifetimeNote').textContent='Run supabase/migrations/028_admin_lifetime_dashboard.sql in Supabase SQL Editor to enable all-time figures.';$('#topMedicines').innerHTML='<div class="muted">Run migration 028 to load all-time best sellers.</div>'}
  else{const life=lifetimeData.lifetime,profit=Number(life.net_profit||0),soldCount=Number(life.sales_count||0),missingCosts=Number(life.medicines_without_cost||0);animateMetric('#lifetimeCollections',money(life.net_collections));animateMetric('#lifetimeSales',money(life.gross_sales));$('#lifetimeSalesCount').textContent=soldCount.toLocaleString()+' settled sale(s)';animateMetric('#lifetimeRefunds',money(life.refunds));animateMetric('#lifetimeProfit',money(profit));$('#lifetimeProfitCosts').textContent=`Stock cost ${money(life.cogs)} · expenses ${money(life.expenses)}`;const status=$('#profitabilityStatus');status.dataset.state=soldCount===0?'empty':profit>0?'profit':profit<0?'loss':'break-even';status.textContent=soldCount===0?'No settled sales yet':profit>0?'Estimated profitable':profit<0?'Estimated loss':'Estimated break-even';$('#lifetimeNote').textContent=missingCosts?`Estimate uses current purchase prices and recorded expenses. ${missingCosts} sold medicine(s) have no purchase cost, so profit may be overstated.`:'Estimate uses current purchase prices and expenses recorded in the system; it is not an audited profit figure.';const lifetimeTop=lifetimeData.top_medicines||[];$('#topMedicines').innerHTML=lifetimeTop.length?lifetimeTop.map((m,i)=>`<div class="seller-row"><span><strong>${i+1}. ${escapeHtml(m.name)}</strong><br><small>${Number(m.qty||0).toLocaleString()} units sold</small></span><strong>${money(m.revenue)}</strong></div>`).join(''):'<div class="muted">No paid medicine sales recorded yet.</div>'}
  if(!lifetimeError&&lifetimeData?.lifetime){const life=lifetimeData.lifetime,estimatedLines=Number(life.estimated_cost_lines||0);$('#lifetimeProfitCosts').textContent=`Stock cost ${money(life.cogs)} · expenses ${money(life.expenses)} · payroll ${money(life.payroll)}`;$('#lifetimeNote').textContent=estimatedLines?`New sales use buying costs saved at sale time. ${estimatedLines} older sale line(s) use current buying prices as estimates.`:'Net profit includes sale-time buying costs, recorded expenses and payroll; it is an estimate, not an audited report.'}
  animateMetric('#todayPaid',money(t.paid));animateMetric('#todayMpesa',money(t.mpesa));animateMetric('#todayCash',money(t.cash));animateMetric('#todayNet',money(t.net));animateMetric('#todaySales',Number(t.sales_count||0).toLocaleString());animateMetric('#todaySalesValue',money(t.sales_total)+' gross');animateMetric('#todayExpenses',money(t.expenses));const share=t.paid?Math.round(Number(t.mpesa||0)/Number(t.paid)*100):0;$('#mpesaShare').textContent=share+'% of paid money';
  $('#mixMpesa').textContent=money(t.mpesa);$('#mixCash').textContent=money(t.cash);$('#mixOther').textContent=money(t.other);$('#mixPaid').textContent=money(t.paid);$('#mixRefunded').textContent=money(t.refunded);$('#paidProgress').style.width=(t.paid?Math.min(100,(Number(t.paid)-Number(t.refunded||0))/Math.max(Number(t.paid),1)*100):0)+'%';
  const max=Math.max(...week.map(d=>Number(d.payments||0)),1);$('#weekChart').innerHTML=week.map(d=>`<div class="bar-col"><strong>${money(d.payments).replace('KSh ','')}</strong><div class="bar" title="${money(d.payments)} paid; ${money(d.expenses)} expenses" style="height:${Math.max(4,Number(d.payments)/max*145)}px"></div><small>${new Date(d.date+'T00:00:00').toLocaleDateString(undefined,{weekday:'short'})}</small></div>`).join('');
  $('#sellerList').innerHTML=sellers.length?sellers.map(s=>`<div><div class="seller-row"><span><strong>${escapeHtml(s.seller_name)}</strong><br><small>${s.sales_count} paid sale(s)</small></span><strong>${money(s.sales_total)}</strong></div><div class="progress" style="margin-top:7px"><span style="width:${Math.min(100,Number(s.sales_total)/Math.max(...sellers.map(z=>Number(z.sales_total)),1)*100)}%"></span></div></div>`).join(''):'<div class="muted">No paid seller sales recorded today.</div>';
  const {data:ops}=opsResult; const o=ops||{}, ot=o.today||{}, ex=o.expiry||{}, sec=o.security||{};
  animateMetric('#grossProfit',money(ot.gross_profit)); $('#cogsText').textContent='Cost of goods: '+money(ot.cogs); animateMetric('#avgSale',money(ot.avg_sale)); animateMetric('#pendingPayments',money(ot.pending_payments)); animateMetric('#expiryValue',money(ex.retail_value)); $('#expiryBatches').textContent=Number(ex.batches||0)+' batches within 30 days'; animateMetric('#inactiveSellers',Number(sec.inactive_sellers||0)); animateMetric('#audit24',Number(sec.audit_24h||0));
  const securityItems=[]; if(sec.inactive_sellers) securityItems.push(`${sec.inactive_sellers} seller account(s) are inactive.`); if(sec.pending_approvals) securityItems.push(`${sec.pending_approvals} refund/cancellation approval(s) pending.`); if(sec.pending_adjustments) securityItems.push(`${sec.pending_adjustments} stock adjustment(s) pending.`); $('#securitySummary').innerHTML=securityItems.length?securityItems.map(x=>`<div class="alert">${x}</div>`).join(''):'<div class="ok">✓ No pending security or approval actions.</div>';
  const {data:summary}=summaryResult;const q=summary||{};const alerts=[];if(q.out_of_stock)alerts.push(`${q.out_of_stock} medicine(s) are out of stock.`);if(q.expired_stock)alerts.push(`${q.expired_stock} expired batch(es) still contain stock.`);if(q.expiring_30_days)alerts.push(`${q.expiring_30_days} batch(es) expire within 30 days.`);if(q.pending_prescriptions)alerts.push(`${q.pending_prescriptions} prescription(s) await review.`);if(q.pending_approvals)alerts.push(`${q.pending_approvals} approval/adjustment request(s) need attention.`);$('#alerts').innerHTML=alerts.length?alerts.map(a=>`<div class="alert">${a}</div>`).join(''):'<div class="ok">✓ No urgent operational alerts.</div>';
  loadDashboardAnalytics(week,q,analyticsResult); loadInventoryValuation(valuationResult); void loadNotifications();
}
function escapeHtml(v){return String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]))}
function initializeCommandCenter(){
  const tools=document.createElement('div');tools.className='portal-tools command-tools';
  tools.innerHTML='<button class="btn secondary" type="button" id="commandOpen" aria-label="Open command search">⌕ <span>Search</span><kbd>Ctrl K</kbd></button><button class="btn secondary notification-trigger" type="button" id="notificationOpen" aria-label="Open notifications">♧ <span>Alerts</span><b id="notificationCount" hidden></b></button><button class="btn secondary" type="button" id="themeBtn" aria-label="Toggle theme">◐ Theme</button>';
  $('.page-head')?.append(tools);
  $('#themeBtn').addEventListener('click',()=>document.querySelector('.mobile-theme')?.click());
  const dialog=document.createElement('section');dialog.className='command-dialog';dialog.hidden=true;dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-labelledby','commandTitle');
  dialog.innerHTML='<div class="command-box"><div class="command-heading"><strong id="commandTitle">Command search</strong><button type="button" class="icon-button" aria-label="Close search" data-close>×</button></div><input id="commandInput" type="search" placeholder="Search pages and actions" autocomplete="off"><div id="commandResults" role="listbox" aria-label="Search results"></div></div>';
  document.body.append(dialog);
  const notification=document.createElement('section');notification.className='notification-panel';notification.hidden=true;notification.setAttribute('aria-labelledby','notificationTitle');
  notification.innerHTML='<div class="command-heading"><strong id="notificationTitle">Notifications</strong><button type="button" class="icon-button" aria-label="Close notifications" data-close>×</button></div><div id="notificationItems" aria-live="polite"><div class="skeleton notification-skeleton"></div></div><a href="/admin/pages/alerts/" class="notification-footer">Open alert center</a>';
  document.body.append(notification);
  const input=$('#commandInput'),results=$('#commandResults');
  const entries=[...document.querySelectorAll('.nav a[href]:not([href="#"]),.quick a[href]')].map(link=>({label:link.textContent.trim().replace(/\s+/g,' '),href:link.getAttribute('href')}));
  const close=()=>{dialog.hidden=true;$('#commandOpen').focus()};
  const render=()=>{const term=input.value.trim().toLowerCase(),matches=entries.filter(item=>item.label.toLowerCase().includes(term)).slice(0,10);results.replaceChildren();if(!matches.length){const empty=document.createElement('p');empty.className='muted command-empty';empty.textContent='No matching pages or actions.';results.append(empty);return}for(const item of matches){const link=document.createElement('a');link.className='command-result';link.href=item.href;link.setAttribute('role','option');link.textContent=item.label;results.append(link)}};
  $('#commandOpen').addEventListener('click',()=>{dialog.hidden=false;render();input.value='';render();input.focus()});input.addEventListener('input',render);
  dialog.addEventListener('click',event=>{if(event.target===dialog||event.target.closest('[data-close]'))close()});
  $('#notificationOpen').addEventListener('click',()=>{notification.hidden=!notification.hidden;if(!notification.hidden)loadNotifications()});
  notification.addEventListener('click',event=>{if(event.target.closest('[data-close]'))notification.hidden=true});
  document.addEventListener('keydown',event=>{if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){event.preventDefault();$('#commandOpen').click()}if(event.key==='Escape'){dialog.hidden=true;notification.hidden=true}});
  const chart=$('#weekChart'),chartCard=chart?.closest('.card');
  if(chartCard){const modes=document.createElement('div');modes.id='chartModes';modes.className='chart-modes';modes.setAttribute('role','group');modes.setAttribute('aria-label','Dashboard chart view');modes.innerHTML='<button type="button" data-chart="sales" aria-pressed="true">Sales</button><button type="button" data-chart="profit" aria-pressed="false">Gross profit</button><button type="button" data-chart="stock" aria-pressed="false">Stock risk</button>';chart.before(modes);const status=document.createElement('small');status.id='chartStatus';status.className='muted chart-status';chart.after(status)}
}
function renderChart(name,data){
  const chart=$('#weekChart');if(!chart)return;
  chart.setAttribute('role','img');chart.setAttribute('aria-label',`${name} trend over the last seven days`);
  if(name==='stock'){
    const stock=data.stock||{},items=[['Low stock',stock.low_stock||0],['Out of stock',stock.out_of_stock||0],['Expiring batches',stock.expiring_batches||0],['Expired batches',stock.expired_batches||0]],max=Math.max(...items.map(([,value])=>Number(value)),1);
    chart.classList.add('risk-chart');chart.innerHTML=items.map(([label,value])=>`<div class="risk-row"><span>${label}</span><div class="risk-track"><i style="width:${Math.max(value?4:0,Number(value)/max*100)}%"></i></div><strong>${Number(value).toLocaleString()}</strong></div>`).join('');return;
  }
  chart.classList.remove('risk-chart');const rows=data.week?.length?data.week:(data.fallbackWeek||[]),key=name==='profit'?'gross_profit':'sales',max=Math.max(...rows.map(day=>Math.abs(Number(day[key]||0))),1);
  chart.innerHTML=rows.map(day=>{const value=Number(day[key]||0),height=Math.max(value?5:0,Math.abs(value)/max*145),label=new Date(day.date+'T00:00:00').toLocaleDateString(undefined,{weekday:'short'});return `<div class="bar-col"><strong>${money(value).replace('KSh ','')}</strong><div class="bar ${name==='profit'?'profit-bar':''}" title="${label}: ${money(value)}" style="height:${height}px"></div><small>${label}</small></div>`}).join('');
}
function loadDashboardAnalytics(fallbackWeek,summary,result){
  const {data,error}=result;const controls=$('#chartModes');if(!controls)return;
  const analytics=error?{}:(data||{});analytics.week ||= (fallbackWeek||[]).map(day=>({...day,gross_profit:0}));analytics.stock ||= {low_stock:summary.low_stock||0,out_of_stock:summary.out_of_stock||0,expiring_batches:summary.expiring_30_days||0,expired_batches:summary.expired_stock||0};
  if(error)$('#chartStatus').textContent='Profit history unavailable until analytics migration is applied.';else $('#chartStatus').textContent='Updated from secured admin analytics.';
  controls.querySelectorAll('button').forEach(button=>button.onclick=()=>{controls.querySelectorAll('button').forEach(item=>{item.setAttribute('aria-pressed',String(item===button))});renderChart(button.dataset.chart,analytics)});
  renderChart('sales',analytics);
}
function loadInventoryValuation(result){
  const {data,error}=result;
  const buying=$('#inventoryBuyingValue'),selling=$('#inventorySellingValue'),margin=$('#inventoryGrossMargin'),units=$('#inventoryStockUnits'),message=$('#inventoryValuationMessage');
  if(error||!data){buying.textContent=selling.textContent=margin.textContent='Unavailable';units.textContent='';message.textContent='Stock values could not be loaded.';return}
  animateMetric('#inventoryBuyingValue',money(data.buying_value));
  animateMetric('#inventorySellingValue',money(data.selling_value));
  animateMetric('#inventoryGrossMargin',money(data.potential_margin));
  units.textContent=Number(data.stock_units||0).toLocaleString()+' units';
  message.textContent='';
}
async function loadNotifications(){
  const host=$('#notificationItems');if(!host)return;
  const [{data:summary,error:snapshotError},{data:items,error:listError}]=await Promise.all([supabase.rpc('admin_notification_snapshot'),supabase.from('operational_notifications').select('id,severity,title,message,created_at,read_at').is('resolved_at',null).order('created_at',{ascending:false}).limit(8)]);
  if(snapshotError||listError){host.textContent=(snapshotError||listError).message;return}
  const count=Number(summary?.unread_notifications||0),badge=$('#notificationCount');badge.hidden=count===0;badge.textContent=count>99?'99+':String(count);badge.setAttribute('aria-label',`${count} unread notifications`);
  host.innerHTML=items?.length?items.map(item=>`<button type="button" class="notification-item ${item.read_at?'':'is-unread'}" data-notification="${escapeHtml(item.id)}"><span class="notification-severity ${escapeHtml(item.severity)}"></span><span><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.message)}</small><time>${new Date(item.created_at).toLocaleString()}</time></span></button>`).join(''):'<p class="muted command-empty">You are all caught up.</p>';
  host.querySelectorAll('[data-notification]').forEach(button=>button.onclick=async()=>{await supabase.from('operational_notifications').update({read_at:new Date().toISOString()}).eq('id',button.dataset.notification);await loadNotifications()});
}
let dashboardRefreshInProgress=false,dashboardHasLoaded=false;
function refreshDashboard(){if(dashboardRefreshInProgress)return;dashboardRefreshInProgress=true;const values=document.querySelectorAll('.metric h2,.advanced-kpis h2');if(!dashboardHasLoaded)values.forEach(value=>{value.classList.add('skeleton');value.setAttribute('aria-busy','true')});return load().finally(()=>{dashboardHasLoaded=true;dashboardRefreshInProgress=false;values.forEach(value=>{value.classList.remove('skeleton');value.removeAttribute('aria-busy')})})}
$('#refreshBtn').onclick=refreshDashboard; initializeCommandCenter(); refreshDashboard();const dashboardPoll=window.setInterval(()=>{if(document.visibilityState==='visible')void refreshDashboard()},120000);
let dashboardRealtimeTimer=0;
const dashboardRealtime=supabase.channel('admin-dashboard-live-updates')
  .on('postgres_changes',{event:'*',schema:'public',table:'sales'},()=>{window.clearTimeout(dashboardRealtimeTimer);dashboardRealtimeTimer=window.setTimeout(()=>void refreshDashboard(),700)})
  .on('postgres_changes',{event:'*',schema:'public',table:'inventory'},()=>{window.clearTimeout(dashboardRealtimeTimer);dashboardRealtimeTimer=window.setTimeout(()=>void refreshDashboard(),700)})
  .subscribe();
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')void refreshDashboard()});
window.addEventListener('pagehide',()=>{window.clearInterval(dashboardPoll);window.clearTimeout(dashboardRealtimeTimer);void supabase.removeChannel(dashboardRealtime)},{once:true});
