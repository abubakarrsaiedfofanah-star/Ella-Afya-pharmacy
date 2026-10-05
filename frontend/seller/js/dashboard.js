import {supabase} from '../../shared/js/supabase.js';
import {requireUser,signOut} from '../../shared/js/auth.js';

const session=await requireUser(['seller']);
if(!session) throw new Error('Unauthorized');
const $=selector=>document.querySelector(selector);
$('#logout').onclick=event=>{event.preventDefault();signOut()};

async function loadShiftStatus(){
  const {data,error}=await supabase.from('shift_sessions')
    .select('status,opened_at').eq('seller_id',session.user.id)
    .order('opened_at',{ascending:false}).limit(1).maybeSingle();
  if(error){$('#msg').textContent='Shift status could not be loaded.';return}
  $('#shift').textContent=data?.status==='open'?'OPEN':'CLOSED';
  $('#lastShift').textContent=data?.status?data.status.toUpperCase():'—';
}

window.addEventListener('session-warning',()=>$('#sessionWarning').hidden=false);
$('#stayBtn')?.addEventListener('click',()=>$('#sessionWarning').hidden=true);
loadShiftStatus();
setInterval(loadShiftStatus,60000);
