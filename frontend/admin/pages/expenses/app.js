import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';
await requireUser(['admin']);
const f=document.querySelector('#form'),rows=document.querySelector('#rows'),msg=document.querySelector('#msg');
const esc=window.pharmacyUI.escapeHtml;
const today=()=>{const now=new Date();return `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`};
f.date.value=today();
async function load(){const {data,error}=await supabase.from('expenses').select('*').order('created_at',{ascending:false}).limit(100);if(error){msg.textContent='Expenses could not be loaded.';return}rows.innerHTML=(data||[]).map(x=>`<tr><td>${esc(x.expense_number)}</td><td>${esc(x.expense_date)}</td><td>${esc(x.category)}</td><td>${esc(x.description)}</td><td>${esc(x.payment_method)}</td><td>KSh ${Number(x.amount).toLocaleString()}</td></tr>`).join('')||'<tr><td colspan="6">No expenses recorded.</td></tr>'}
f.onsubmit=async e=>{e.preventDefault();const d=Object.fromEntries(new FormData(f));const {error}=await supabase.rpc('record_expense',{p_category:d.category,p_description:d.description,p_amount:+d.amount,p_method:d.method,p_reference:d.reference||null,p_date:d.date});msg.textContent=error?.message||'Expense recorded.';if(!error){f.reset();f.date.value=today();await load()}};load();
