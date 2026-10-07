import {supabase} from './supabase.js';

const DEVICE_KEY='pharmacy_device_session';
const loginPath=()=>location.pathname.startsWith('/admin/')||location.pathname.startsWith('/auth/mfa/')?'/auth/admin/':'/auth/';
let heartbeatTimer=null;
let started=false;

export async function ensureDeviceSession(){
  const existingKey=sessionStorage.getItem(DEVICE_KEY);
  if(existingKey){
    for(let attempt=0;attempt<2;attempt++){
      const {data,error}=await supabase.rpc('touch_device_session',{p_session_key:existingKey});
      if(!error&&data===true)return existingKey;
      if(!error&&data===false){sessionStorage.removeItem(DEVICE_KEY);break;}
      if(attempt===0)await new Promise(resolve=>setTimeout(resolve,350));
    }
    if(sessionStorage.getItem(DEVICE_KEY)===existingKey){
      console.warn('Device-session check is temporarily unavailable; keeping the saved sign-in.');
      return existingKey;
    }
  }
  const key=sessionStorage.getItem(DEVICE_KEY)||crypto.randomUUID();
  sessionStorage.setItem(DEVICE_KEY,key);
  const label=`${navigator.platform||'Device'} - ${/Mobi|Android/i.test(navigator.userAgent)?'Mobile':'Desktop'}`;
  let lastError=null;
  for(let attempt=0;attempt<3;attempt++){
    const {error}=await supabase.rpc('register_device_session',{p_session_key:key,p_device_label:label,p_user_agent:navigator.userAgent});
    if(!error)return key;
    lastError=error;
    const reason=String(error.message||'').toLowerCase();
    if(/revoked|invalid device session|device session unavailable/.test(reason)){
      sessionStorage.removeItem(DEVICE_KEY);await supabase.auth.signOut();location.href=loginPath();return null;
    }
    if(attempt<2)await new Promise(resolve=>setTimeout(resolve,350*(attempt+1)));
  }
  if(existingKey){console.warn('Device-session check could not reach the server; keeping the signed-in session and retrying later.',lastError?.message);return existingKey;}
  console.warn('Device session could not be registered. Sign-in can be retried when the connection is available.',lastError?.message);
  return null;
}

export async function touchDeviceSession(){
  const key=sessionStorage.getItem(DEVICE_KEY);
  if(!key)return false;
  const {data,error}=await supabase.rpc('touch_device_session',{p_session_key:key});
  if(error){console.warn('Device-session check failed; it will retry on the next heartbeat.',error.message);return false;}
  if(data===false){await supabase.auth.signOut();sessionStorage.removeItem(DEVICE_KEY);location.href=loginPath();return false;}
  if(data!==true){console.warn('Device-session check returned no confirmation; it will retry on the next heartbeat.');return false;}
  return true;
}

export function startSecurityControls(){
  if(started)return;
  started=true;
  const activity=()=>{
    if(!activity.lastTouch||Date.now()-activity.lastTouch>60_000){
      activity.lastTouch=Date.now();
      void touchDeviceSession();
    }
  };
  ['pointerdown','keydown','touchstart','scroll'].forEach(type=>window.addEventListener(type,activity,{passive:true}));
  document.addEventListener('visibilitychange',()=>{
    if(!document.hidden){activity();void touchDeviceSession();}
  });
  heartbeatTimer=setInterval(()=>void touchDeviceSession(),5*60*1000);
}

export async function requireAdminMFA(){
  const {data:{session},error:sessionError}=await supabase.auth.getSession();
  if(sessionError)throw sessionError;
  if(!session?.user)return false;
  const {data:aal,error}=await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if(error)throw error;
  if(aal?.currentLevel!=='aal2'){location.href='/auth/mfa/';return false;}
  return true;
}
