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
  const {data:callerProfile}=caller?await admin.from('profiles').select('role,active').eq('id',caller.id).maybeSingle():{data:null};
  // This endpoint is configured without gateway JWT enforcement because it
  // also supports public registration. Verify admin tokens and MFA here.
  const isAdmin=callerProfile?.role==='admin'&&callerProfile.active&&hasVerifiedAal2(token);

  if(body.action==='list_sellers'){
    if(!isAdmin)return json({error:'An MFA-verified Admin session is required.'},403);
    const {data:profiles,error:profilesError}=await admin.from('profiles').select('id,full_name,active,created_at').eq('role','seller').order('created_at',{ascending:false});
    if(profilesError)return json({error:'Seller accounts could not be loaded.'},500);
    const sellers=await Promise.all((profiles||[]).map(async profile=>{
      const {data,error}=await admin.auth.admin.getUserById(profile.id);
      if(error)console.error('Could not retrieve seller email',profile.id,error);
      return {...profile,email:error?null:data.user?.email||null};
    }));
    return json({sellers});
  }

  if(body.action==='delete_seller'){
    if(!isAdmin)return json({error:'An MFA-verified Admin session is required.'},403);
    const userId=typeof body.user_id==='string'?body.user_id:'';
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId))return json({error:'Invalid seller account.'},400);
    const {data:target,error:targetError}=await admin.from('profiles').select('id,role').eq('id',userId).maybeSingle();
    if(targetError||!target||target.role!=='seller')return json({error:'Seller account not found.'},404);
    const {count,error:salesError}=await admin.from('sales').select('id',{count:'exact',head:true}).eq('seller_id',userId);
    if(salesError)return json({error:'Could not check the seller sales history. No account was deleted.'},500);
    if((count||0)>0)return json({error:'This seller has sales history. Disable the account to preserve pharmacy records.'},409);
    const {error:auditError}=await admin.from('audit_logs').insert({actor_id:caller!.id,action:'seller_account_deletion_authorized',entity_type:'profiles',entity_id:userId,details:{seller_id:userId}});
    if(auditError)return json({error:'Deletion could not be audited, so no account was deleted.'},500);
    const {error:deleteError}=await admin.auth.admin.deleteUser(userId);
    if(deleteError){
      await admin.from('audit_logs').insert({actor_id:caller!.id,action:'seller_account_deletion_failed',entity_type:'profiles',entity_id:userId,details:{reason:'auth_delete_failed'}});
      console.error('Seller account deletion failed',userId,deleteError);
      return json({error:'The account has linked records and could not be deleted. Disable it to block sign-in while preserving records.'},409);
    }
    return json({ok:true,user_id:userId,deleted:true});
  }

  if(body.action==='set_seller_active'){
    if(!isAdmin)return json({error:'An MFA-verified Admin session is required.'},403);
    const userId=typeof body.user_id==='string'?body.user_id:'';
    const active=body.active;
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)||typeof active!=='boolean')return json({error:'Invalid seller activation request.'},400);
    const {data:target,error:targetError}=await admin.from('profiles').select('id,role,active').eq('id',userId).maybeSingle();
    if(targetError||!target||target.role!=='seller')return json({error:'Seller account not found.'},404);
    if(active){
      const {error:confirmError}=await admin.auth.admin.updateUserById(userId,{email_confirm:true});
      if(confirmError){console.error('Could not confirm approved seller email',confirmError);return json({error:'Seller email could not be confirmed. Try again or check the account in Supabase Auth.'},400)}
    }
    const {error:updateError}=await admin.from('profiles').update({active}).eq('id',userId).eq('role','seller');
    if(updateError)return json({error:'Seller access status could not be updated.'},500);
    const {error:auditError}=await admin.from('audit_logs').insert({actor_id:caller!.id,action:active?'seller_activated':'seller_disabled',entity_type:'profiles',entity_id:userId,details:{active,email_confirmed_on_activation:active}});
    if(auditError){
      await admin.from('profiles').update({active:target.active}).eq('id',userId).eq('role','seller');
      console.error('Seller status audit failed',auditError);
      return json({error:'The status change could not be audited; the previous access status was restored.'},500);
    }
    return json({ok:true,user_id:userId,active,email_confirmed:active});
  }

  const fullName=typeof body.full_name==='string'?body.full_name.trim():'';
  const email=typeof body.email==='string'?body.email.trim().toLowerCase():'';
  const password=typeof body.password==='string'?body.password:'';
  const registrationKey=typeof body.registration_key==='string'?body.registration_key:'';
  if(fullName.length<2||fullName.length>120||!email||email.length>254||!/^\S+@\S+\.\S+$/.test(email)||!password)return json({error:'Enter a valid name, email and password.'},400);
  if(!strongPassword(password))return json({error:'Use 12–128 characters with uppercase, lowercase, a number and a symbol.'},400);
  // getUser(token) above verifies the JWT signature; only its verified aal2
  // claim may authorize immediate Admin-created account activation.
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
