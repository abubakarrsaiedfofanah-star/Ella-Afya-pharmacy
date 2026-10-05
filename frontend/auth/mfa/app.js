import {supabase} from '../../shared/js/supabase.js';

const msg=document.querySelector('#msg'),enroll=document.querySelector('#enroll'),challenge=document.querySelector('#challenge');
const say=(message,ok=false)=>{msg.textContent=message;msg.style.color=ok?'#17785f':'#b83b45'};
const {data:{user}}=await supabase.auth.getUser();
if(!user){location.href='/auth/admin/';throw new Error('No session')}
const {data:profile,error:profileError}=await supabase.from('profiles').select('role,active').eq('id',user.id).single();
if(profileError||profile?.role!=='admin'||!profile.active){await supabase.auth.signOut();location.href='/auth/admin/';throw new Error('Admin access required')}

const {data:assurance,error:assuranceError}=await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
if(assuranceError){say('Administrator verification could not be checked. Try again.');throw assuranceError}
const {data:factors,error:factorError}=await supabase.auth.mfa.listFactors();
if(factorError){say('Authenticator settings could not be loaded. Try again.');throw factorError}
const verified=(factors?.totp||[]).find(factor=>factor.status==='verified');
if(assurance?.currentLevel==='aal2')location.href='/admin/';
else if(verified){
  challenge.hidden=false;
  document.querySelector('#verifyChallenge').onclick=async event=>{
    const button=event.currentTarget,code=document.querySelector('#challengeCode').value.trim();
    if(!/^\d{6}$/.test(code)){say('Enter the six-digit authenticator code.');return}
    button.disabled=true;
    const {data:challengeData,error:challengeError}=await supabase.auth.mfa.challenge({factorId:verified.id});
    if(challengeError){button.disabled=false;say('A verification challenge could not be created. Try again.');return}
    const {error}=await supabase.auth.mfa.verify({factorId:verified.id,challengeId:challengeData.id,code});
    if(error){button.disabled=false;say('That code could not be verified. Check the code and try again.');return}
    location.href='/admin/';
  };
}else{
  enroll.hidden=false;
  const {data,error}=await supabase.auth.mfa.enroll({factorType:'totp',friendlyName:'Ella Afya Admin'});
  if(error){say('Authenticator setup could not be started. Try again.');throw error}
  const qr=document.querySelector('#qr'),image=document.createElement('img'),manual=document.createElement('p'),label=document.createElement('strong'),secret=document.createElement('code');
  image.alt='Authenticator QR code';image.src=data.totp.qr_code;image.style.cssText='max-width:240px;background:#fff;padding:12px;border-radius:12px';
  label.textContent='Manual setup key: ';secret.textContent=data.totp.secret;manual.append(label,secret);qr.replaceChildren(image,manual);
  document.querySelector('#verifyEnroll').onclick=async event=>{
    const button=event.currentTarget,code=document.querySelector('#enrollCode').value.trim();
    if(!/^\d{6}$/.test(code)){say('Enter the six-digit authenticator code.');return}
    button.disabled=true;
    const {data:challengeData,error:challengeError}=await supabase.auth.mfa.challenge({factorId:data.id});
    if(challengeError){button.disabled=false;say('A verification challenge could not be created. Try again.');return}
    const {error:verifyError}=await supabase.auth.mfa.verify({factorId:data.id,challengeId:challengeData.id,code});
    if(verifyError){button.disabled=false;say('That code could not be verified. Check the code and try again.');return}
    location.href='/admin/';
  };
}
