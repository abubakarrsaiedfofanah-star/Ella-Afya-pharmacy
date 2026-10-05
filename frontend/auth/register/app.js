import {supabase} from '../../shared/js/supabase.js';
import {isStrongPassword,passwordStrengthScore,PASSWORD_POLICY_MESSAGE} from '../../shared/js/password-policy.js';
const form=document.querySelector('#registerForm'),msg=document.querySelector('#registerMessage'),btn=document.querySelector('#registerBtn'),pw=document.querySelector('#password'),strength=document.querySelector('#strength'),toggle=document.querySelector('#togglePassword'),key=document.querySelector('#key'),toggleKey=document.querySelector('#toggleKey');
strength.setAttribute('role','status');strength.setAttribute('aria-live','polite');
function updateStrength(){const score=passwordStrengthScore(pw.value),level=score===5?'strong':score>=3?'good':pw.value?'weak':'idle';strength.dataset.level=level;strength.style.setProperty('--strength-progress',`${score*20}%`);strength.textContent=!pw.value?PASSWORD_POLICY_MESSAGE:score<3?'Weak password — add length, uppercase, number and symbol.':score<5?'Good password — add one more character type.':'Strong password.'}
pw.addEventListener('input',updateStrength);
updateStrength();
toggle.addEventListener('click',()=>{const show=pw.type==='password';pw.type=show?'text':'password';toggle.textContent=show?'◉':'○';toggle.setAttribute('aria-label',show?'Hide password':'Show password')});
toggleKey.addEventListener('click',()=>{const show=key.type==='password';key.type=show?'text':'password';toggleKey.textContent=show?'◉':'○';toggleKey.setAttribute('aria-label',show?'Hide registration key':'Show registration key')});
form.addEventListener('submit',async e=>{e.preventDefault();msg.textContent='';if(!isStrongPassword(pw.value)){msg.textContent=PASSWORD_POLICY_MESSAGE;return}btn.disabled=true;btn.setAttribute('aria-busy','true');btn.querySelector('span').textContent='Creating account…';
 try{const {error}=await supabase.functions.invoke('admin-create-user',{body:{full_name:document.querySelector('#fullName').value.trim(),email:document.querySelector('#email').value.trim().toLowerCase(),password:pw.value,registration_key:document.querySelector('#key').value}});if(error){msg.textContent='Registration could not be completed. Check the details and try again.';return}
 location.replace('/auth/?registered=1');
 }catch{msg.textContent='Registration is temporarily unavailable. Please try again.'}
 finally{btn.disabled=false;btn.removeAttribute('aria-busy');btn.querySelector('span').textContent='Create Sales account'}
});
