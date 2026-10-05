import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const origin=Deno.env.get("ALLOWED_ORIGIN")||"*"; const cors={"Access-Control-Allow-Origin":origin,"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type, x-registration-key"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const strongPassword=(value:string)=>value.length>=12&&value.length<=128&&/[A-Z]/.test(value)&&/[a-z]/.test(value)&&/\d/.test(value)&&/[^A-Za-z0-9]/.test(value);
const hasVerifiedAal2=(jwt:string)=>{try{const segment=jwt.split('.')[1];if(!segment)return false;const encoded=segment.replace(/-/g,'+').replace(/_/g,'/');const claims=JSON.parse(atob(encoded+'='.repeat((4-encoded.length%4)%4)));return claims.aal==='aal2'}catch{return false}};
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return json({error:'Method not allowed.'},405);
 try{
  const url=Deno.env.get('SUPABASE_URL')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
  const authHeader=req.headers.get('Authorization')||'';
  const token=authHeader.match(/^Bearer\s+(.+)$/i)?.[1]?.trim()||'';
  let caller=null;
  if(token){const {data,error}=await admin.auth.getUser(token);if(error||!data.user)return json({error:'Authentication is required.'},401);caller=data.user;}
  let rawBody:unknown;
  try{rawBody=await req.json()}catch{return json({error:'Request body must be valid JSON.'},400)}
  if(!rawBody||typeof rawBody!=='object'||Array.isArray(rawBody))return json({error:'Invalid registration details.'},400);
  const body=rawBody as Record<string,unknown>;
  const fullName=typeof body.full_name==='string'?body.full_name.trim():'';
  const email=typeof body.email==='string'?body.email.trim().toLowerCase():'';
  const password=typeof body.password==='string'?body.password:'';
  const registrationKey=typeof body.registration_key==='string'?body.registration_key:'';
  if(fullName.length<2||fullName.length>120||!email||email.length>254||!/^\S+@\S+\.\S+$/.test(email)||!password)return json({error:'Enter a valid name, email and password.'},400);
  if(!strongPassword(password))return json({error:'Use 12–128 characters with uppercase, lowercase, a number and a symbol.'},400);
  const {data:callerProfile}=caller?await admin.from('profiles').select('role,active').eq('id',caller.id).maybeSingle():{data:null};
  // getUser(token) above verifies the JWT signature; only its verified aal2
  // claim may authorize immediate Admin-created account activation.
  const isAdmin=callerProfile?.role==='admin'&&callerProfile.active&&hasVerifiedAal2(token);
  const configuredKey=Deno.env.get('STAFF_REGISTRATION_KEY');
  if(!isAdmin && (!configuredKey || registrationKey!==configuredKey))return json({error:'Invalid staff registration authorization.'},403);
  const {data:created,error}=await admin.auth.admin.createUser({email,password,email_confirm:isAdmin,user_metadata:{full_name:fullName}});
  if(error)return json({error:'Could not create an account with those details.'},400);
    const {data:profile,error:profileError}=await admin.from('profiles').update({full_name:fullName,role:'seller',active:isAdmin}).eq('id',created.user.id).select('id').maybeSingle();
    if(profileError||!profile){
     const {error:cleanupError}=await admin.auth.admin.deleteUser(created.user.id);
     if(cleanupError)console.error('Failed to remove account after profile setup error',cleanupError);
     console.error('Profile setup failed after account creation',profileError);
     return json({error:'Account setup could not be completed.'},500);
    }
    const {error:auditError}=await admin.from('audit_logs').insert({actor_id:caller?.id||null,action:'staff_account_created',entity_type:'profiles',entity_id:created.user.id,details:{email:created.user.email,activated:isAdmin}});
    if(auditError){
     const {error:cleanupError}=await admin.auth.admin.deleteUser(created.user.id);
     if(cleanupError)console.error('Failed to remove account after audit error',cleanupError);
     console.error('Account creation audit failed',auditError);
     return json({error:'Account setup could not be completed.'},500);
    }
  return json({ok:true,user_id:created.user.id,active:isAdmin});
 }catch(e){console.error('admin-create-user failed',e);return json({error:'Unexpected server error.'},500)}
});
