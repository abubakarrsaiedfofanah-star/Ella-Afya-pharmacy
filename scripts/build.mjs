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
const output=path.join(root,'dist');
await fs.rm(output,{recursive:true,force:true});
await fs.cp(frontend,output,{recursive:true});
const config={SUPABASE_URL:supabaseUrl,SUPABASE_ANON_KEY:anonKey,MPESA_FUNCTION_NAME:'mpesa-stk'};
await fs.writeFile(path.join(output,'shared','js','config.js'),`window.APP_CONFIG = ${JSON.stringify(config,null,2)};\n`,'utf8');

async function addPwaTags(directory){
  for(const entry of await fs.readdir(directory,{withFileTypes:true})){
    const file=path.join(directory,entry.name);
    if(entry.isDirectory()){await addPwaTags(file);continue;}
    if(!entry.isFile()||!entry.name.endsWith('.html'))continue;
    let html=await fs.readFile(file,'utf8');
    const tags=[];
    if(!/<link\b[^>]*\brel=["']manifest["']/i.test(html))tags.push('<link rel="manifest" href="/manifest.webmanifest">');
    if(!/<meta\b[^>]*\bname=["']theme-color["']/i.test(html))tags.push('<meta name="theme-color" content="#0b705d">');
    if(!/<link\b[^>]*\brel=["']apple-touch-icon["']/i.test(html))tags.push('<link rel="apple-touch-icon" href="/shared/assets/pwa-192.png">');
    if(!/<script\b[^>]*\bsrc=["']\/shared\/js\/pwa\.js["']/i.test(html))tags.push('<script src="/shared/js/pwa.js" defer></script>');
    if(tags.length)html=html.replace(/<\/head>/i,`  ${tags.join('\n  ')}\n</head>`);
    await fs.writeFile(file,html,'utf8');
  }
}
await addPwaTags(output);
console.log('Static pharmacy site built into dist/.');
