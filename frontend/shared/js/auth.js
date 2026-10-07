import { supabase } from './supabase.js';
import { ensureDeviceSession, requireAdminMFA, startSecurityControls } from './security.js';

const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function retryRequest(run){
  let result;
  for(let attempt=0;attempt<3;attempt++){
    result=await run();
    if(!result.error)return result;
    if(result.error.status===401||result.error.status===403||result.error.code==='PGRST116')return result;
    if(attempt<2)await wait(300*(attempt+1));
  }
  return result;
}
function showConnectionRetry(){
  if(document.querySelector('#authConnectionRetry'))return;
  const panel=document.createElement('section');panel.id='authConnectionRetry';panel.setAttribute('role','alert');
  panel.style.cssText='position:fixed;inset:0;z-index:99999;display:grid;place-content:center;gap:12px;padding:24px;background:#f3f8f6;color:#102a25;text-align:center;font:600 16px system-ui';
  const title=document.createElement('strong');title.textContent='Reconnecting to Ella Afya…';
  const detail=document.createElement('span');detail.textContent='Your sign-in is saved. Check the connection and try again.';
  const button=document.createElement('button');button.type='button';button.textContent='Reconnect';button.style.cssText='justify-self:center;padding:12px 22px;border:0;border-radius:10px;background:#075c4c;color:white;font:inherit';button.onclick=()=>location.reload();
  panel.append(title,detail,button);document.body.append(panel);
  window.addEventListener('online',()=>location.reload(),{once:true});
}

export async function requireUser(roles = []) {
  const adminLogin = roles.includes('admin') || location.pathname.startsWith('/admin/');
  const loginPath = adminLogin ? '/auth/admin/' : '/auth/';
  const {data:{session:storedSession},error:sessionError}=await supabase.auth.getSession();
  if(sessionError){showConnectionRetry();return null}
  if(!storedSession?.user){
    location.href = loginPath;
    throw new Error('Not authenticated');
  }
  const {data:{user:verifiedUser},error:userError}=await retryRequest(()=>supabase.auth.getUser());
  if(userError&&[401,403].includes(userError.status)){
    await supabase.auth.signOut();location.href=loginPath;throw new Error('Sign-in expired');
  }
  const user=verifiedUser||storedSession.user;

  const {data:profile,error}=await retryRequest(()=>supabase
    .from('profiles')
    .select('role,active,full_name')
    .eq('id',user.id)
    .single());

  if(error&&![401,403].includes(error.status)&&error.code!=='PGRST116'){
    showConnectionRetry();return null;
  }
  if (error || !profile?.active || (roles.length && !roles.includes(profile.role))) {
    await supabase.auth.signOut();
    location.href = profile?.role === 'admin' ? '/auth/admin/' : '/auth/';
    throw new Error('Access denied');
  }

  if (profile.role === 'admin') {
    try{
      if(!(await requireAdminMFA()))throw new Error('MFA required');
    }catch(error){
      if(error.message==='MFA required')throw error;
      showConnectionRetry();return null;
    }
  }

  const deviceSession=await ensureDeviceSession();
  if(!deviceSession){showConnectionRetry();return null}

  startSecurityControls();

  return { user, profile };
}

export async function signOut() {
  try {
    sessionStorage.removeItem('pharmacy_device_session');
    await supabase.auth.signOut();
  } finally {
    location.href = location.pathname.startsWith('/admin/') ? '/auth/admin/' : '/auth/';
  }
}

// Shared navigation can sign out pages whose feature module does not wire its own link.
window.pharmacyAuth = Object.freeze({ signOut });

export async function changePassword(password) {
  return supabase.auth.updateUser({ password });
}

export async function getMfaFactors() {
  return supabase.auth.mfa.listFactors();
}

export async function enrollMfa(friendlyName = 'Ella Afya Admin') {
  return supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName });
}

export async function verifyMfa(factorId, code) {
  const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({ factorId });
  if (challengeError) return { data: null, error: challengeError };
  return supabase.auth.mfa.verify({ factorId, challengeId: challenge.id, code });
}
