import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { createAuthStorage } from './session-storage.js';
if(!window.APP_CONFIG) throw new Error('Missing APP_CONFIG. Create frontend/shared/js/config.js from config.example.js');
const authStorage=createAuthStorage(window.localStorage,window.sessionStorage);
export const supabase = createClient(window.APP_CONFIG.SUPABASE_URL, window.APP_CONFIG.SUPABASE_ANON_KEY,{
  auth:{storage:authStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}
});
export const setSessionPersistence=remember=>authStorage.setPersistence(remember);
