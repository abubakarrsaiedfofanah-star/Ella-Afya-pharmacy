import {supabase} from '../../shared/js/supabase.js';
import {isStrongPassword,PASSWORD_POLICY_MESSAGE} from '../../shared/js/password-policy.js';

const request=document.querySelector('#requestForm');
const update=document.querySelector('#updateForm');
const msg=document.querySelector('#msg');
const title=document.querySelector('#title');
const subtitle=document.querySelector('#subtitle');
const portal=new URLSearchParams(location.search).get('portal')==='admin'?'admin':'sales';
const loginPath=portal==='admin'?'/auth/admin/':'/auth/';
const resetButton=request.querySelector('button[type="submit"]');
const updateButton=update.querySelector('button[type="submit"]');
document.querySelector('.register-card a')?.setAttribute('href',loginPath);

function setMessage(text,kind='error'){
  msg.textContent=text;
  msg.style.color=kind==='success'?'#17785f':'#b83b45';
}

function showUpdate(){
  request.style.display='none';
  update.style.display='grid';
  title.textContent='Choose a new password';
  subtitle.textContent='Create a strong password for your account.';
  setMessage('');
}

function getRecoveryError(){
  const params=new URLSearchParams(location.search);
  const hashParams=new URLSearchParams(location.hash.replace(/^#/,'').replace(/^\?/,'').split('&').filter(part=>part.startsWith('error=')||part.startsWith('error_code=')||part.startsWith('error_description=')).join('&'));
  const code=params.get('error_code')||hashParams.get('error_code')||params.get('error')||hashParams.get('error');
  if(!code)return null;
  const description=params.get('error_description')||hashParams.get('error_description')||'';
  const expired=/expired|otp_expired|invalid.*link|invalid.*token/i.test(`${code} ${description}`);
  history.replaceState(null,document.title,location.pathname+(portal==='admin'?'?portal=admin':''));
  return expired
    ?'That recovery link is invalid or has expired. Request a new password reset email.'
    :'The recovery link could not be verified. Request a new password reset email.';
}

const recoveryError=getRecoveryError();
let recoverySession=false;
supabase.auth.onAuthStateChange(event=>{
  if(event==='PASSWORD_RECOVERY'){
    recoverySession=true;
    showUpdate();
  }
});

try{
  const {data,error}=await supabase.auth.getSession();
  if(error)throw error;
  if(data.session){
    recoverySession=true;
    showUpdate();
  }else if(recoveryError){
    setMessage(recoveryError);
  }
}catch{
  if(recoveryError)setMessage(recoveryError);
  else setMessage('We could not verify the recovery link. Request a new password reset email.');
}

request.addEventListener('submit',async event=>{
  event.preventDefault();
  resetButton.disabled=true;
  resetButton.setAttribute('aria-busy','true');
  setMessage('Sending recovery email…','success');
  try{
    const email=document.querySelector('#email').value.trim().toLowerCase();
    const {error}=await supabase.auth.resetPasswordForEmail(email,{
      redirectTo:`${location.origin}/auth/reset/?portal=${portal}`,
    });
    if(error)throw error;
    setMessage('If that account exists, a secure recovery link has been sent. Check your inbox and spam folder.','success');
  }catch{
    setMessage('The recovery email could not be sent right now. Check your connection and try again.');
  }finally{
    resetButton.disabled=false;
    resetButton.removeAttribute('aria-busy');
  }
});

update.addEventListener('submit',async event=>{
  event.preventDefault();
  const password=document.querySelector('#newPassword').value;
  if(!isStrongPassword(password)){
    setMessage(PASSWORD_POLICY_MESSAGE);
    return;
  }
  updateButton.disabled=true;
  updateButton.setAttribute('aria-busy','true');
  setMessage('Updating your password…','success');
  try{
    if(!recoverySession){
      const {data,error}=await supabase.auth.getSession();
      if(error||!data.session)throw new Error('Recovery session expired');
    }
    const {error}=await supabase.auth.updateUser({password});
    if(error)throw error;
    setMessage('Password updated successfully. Returning to sign in…','success');
    setTimeout(()=>location.href=loginPath,900);
  }catch(error){
    const expired=/expired|session/i.test(error?.message||'');
    setMessage(expired
      ?'Your recovery session has expired. Request a new password reset email.'
      :'The password could not be updated. Check your connection and try again.');
  }finally{
    updateButton.disabled=false;
    updateButton.removeAttribute('aria-busy');
  }
});

document.querySelector('#togglePassword')?.addEventListener('click',event=>{
  const button=event.currentTarget;
  const password=document.querySelector('#newPassword');
  const show=password.type==='password';
  password.type=show?'text':'password';
  button.setAttribute('aria-label',show?'Hide password':'Show password');
});
