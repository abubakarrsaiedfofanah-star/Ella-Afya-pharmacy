import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const supabaseUrl=String(process.env.SUPABASE_URL||'').trim();
const anonKey=String(process.env.SUPABASE_ANON_KEY||'').trim();

const missing=[];
if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(supabaseUrl)) missing.push('SUPABASE_URL');
if(!anonKey||/YOUR_PUBLIC_ANON_KEY|YOUR-PROJECT/i.test(anonKey)) missing.push('SUPABASE_ANON_KEY');
if(missing.length){
  throw new Error(`Missing valid deployment environment variable(s): ${missing.join(', ')}. Add the Supabase Project URL and public anon/publishable key in Vercel → Project Settings → Environment Variables, then redeploy. Do not use a service-role key.`);
}

const frontend=path.join(root,'frontend');
const output=path.join(root,'dist','frontend');
await fs.rm(path.join(root,'dist'),{recursive:true,force:true});
await fs.cp(frontend,output,{recursive:true});
const config={SUPABASE_URL:supabaseUrl,SUPABASE_ANON_KEY:anonKey,MPESA_FUNCTION_NAME:'mpesa-stk'};
await fs.writeFile(path.join(output,'shared','js','config.js'),`window.APP_CONFIG = ${JSON.stringify(config,null,2)};\n`,'utf8');
console.log('Static pharmacy site built into dist/.');
