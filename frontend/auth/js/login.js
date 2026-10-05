import {supabase,setSessionPersistence} from '../../shared/js/supabase.js';
import {ensureDeviceSession} from '../../shared/js/security.js';
const form=document.querySelector('#loginForm'),msg=document.querySelector('#loginMessage'),btn=document.querySelector('#loginBtn'),email=document.querySelector('#email'),password=document.querySelector('#password'),toggle=document.querySelector('#togglePassword'),remember=document.querySelector('#remember');
const LOCK_KEY='pharmacy-login-lock';
const safeMsg=(text,kind='error')=>{msg.textContent=text;msg.style.color=kind==='ok'?'#17785f':'#b83b45'};
const lockState=()=>{try{return JSON.parse(localStorage.getItem(LOCK_KEY)||'{"fails":0,"until":0}')}catch{return {fails:0,until:0}}};
const saveLock=s=>{try{localStorage.setItem(LOCK_KEY,JSON.stringify(s))}catch{}};
const remaining=()=>Math.max(0,(Number(lockState().until)||0)-Date.now());
const renderLock=()=>{const ms=remaining();if(ms<=0){btn.disabled=false;return false}safeMsg(`Too many unsuccessful attempts. Try again in ${Math.ceil(ms/1000)} seconds.`);btn.disabled=true;setTimeout(renderLock,1000);return true};
const setBusy=busy=>{btn.disabled=busy;btn.toggleAttribute('aria-busy',busy);btn.querySelector('span').textContent=busy?'Authenticating…':'Sign in securely'};
const recordFailure=()=>{const state=lockState();state.fails=Number(state.fails||0)+1;if(state.fails>=5){state.until=Date.now()+60_000;state.fails=0;}saveLock(state)};
renderLock();
if(new URLSearchParams(location.search).get('registered')==='1'){
 safeMsg('Registration received. Sign in after an administrator activates your account.','ok');
 history.replaceState(null,document.title,location.pathname);
}
toggle?.addEventListener('click',()=>{const show=password.type==='password';password.type=show?'text':'password';toggle.textContent=show?'◉':'○';toggle.setAttribute('aria-label',show?'Hide password':'Show password')});
form.addEventListener('submit',async e=>{e.preventDefault();if(renderLock())return;safeMsg('');setBusy(true);
 try{
    setSessionPersistence(remember.checked);
  const cleanEmail=email.value.trim().toLowerCase();
  const {error}=await supabase.auth.signInWithPassword({email:cleanEmail,password:password.value});
  if(error){recordFailure();safeMsg(error.status===429?'Too many sign-in attempts. Try again shortly.':'Unable to sign in with those credentials.');setBusy(false);return}
  saveLock({fails:0,until:0});
  const {data:{user},error:userError}=await supabase.auth.getUser();
  if(userError||!user){await supabase.auth.signOut();safeMsg('Unable to verify this account. Please sign in again.');setBusy(false);return}
  const {data:p,error:profileError}=await supabase.from('profiles').select('role,active,full_name').eq('id',user.id).single();
  if(profileError||!p?.active||!['admin','seller'].includes(p.role)){await supabase.auth.signOut();safeMsg('This account is not authorized to access the workspace.');setBusy(false);return}
  if(!(await ensureDeviceSession()))return;
  if(p.role==='admin'){
   const {data:aal,error:mfaError}=await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
   if(mfaError){await supabase.auth.signOut();safeMsg('Unable to verify administrator security. Please sign in again.');setBusy(false);return}
   if(aal?.currentLevel!=='aal2'){safeMsg('Administrator MFA verification is required. Opening secure verification…','ok');setTimeout(()=>location.href='/auth/mfa/',250);return}
  }
  safeMsg('Access granted. Opening your workspace…','ok');setTimeout(()=>{location.href=p.role==='admin'?'/admin/':'/seller/'},250);
 }catch{safeMsg('Sign-in is temporarily unavailable. Please try again.');setBusy(false)}
});
