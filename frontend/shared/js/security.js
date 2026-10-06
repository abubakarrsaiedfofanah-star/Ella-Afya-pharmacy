import {supabase} from './supabase.js';

const DEVICE_KEY='pharmacy_device_session';
const loginPath=()=>location.pathname.startsWith('/admin/')||location.pathname.startsWith('/auth/mfa/')?'/auth/admin/':'/auth/';
let heartbeatTimer=null;
let started=false;

export async function ensureDeviceSession(){
  const key=sessionStorage.getItem(DEVICE_KEY)||crypto.randomUUID();
  sessionStorage.setItem(DEVICE_KEY,key);
  const label=`${navigator.platform||'Device'} - ${/Mobi|Android/i.test(navigator.userAgent)?'Mobile':'Desktop'}`;
  const {error}=await supabase.rpc('register_device_session',{p_session_key:key,p_device_label:label,p_user_agent:navigator.userAgent});
  if(error){sessionStorage.removeItem(DEVICE_KEY);await supabase.auth.signOut();location.href=loginPath();return null;}
  return key;
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
  const {data:{user}}=await supabase.auth.getUser();
  if(!user)return false;
  const {data:p}=await supabase.from('profiles').select('role,active').eq('id',user.id).single();
  if(p?.role!=='admin')return true;
  const {data:aal}=await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if(aal?.currentLevel!=='aal2'){location.href='/auth/mfa/';return false;}
  return true;
}
