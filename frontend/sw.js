const CACHE_NAME='ella-afya-static-v1';
const PRECACHE=['/manifest.webmanifest','/shared/assets/pwa-192.png','/shared/assets/pwa-512.png'];

self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(PRECACHE)).then(()=>self.skipWaiting()));
});

self.addEventListener('activate',event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('ella-afya-static-')&&key!==CACHE_NAME).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));
});

self.addEventListener('fetch',event=>{
  const request=event.request;
  if(request.method!=='GET')return;
  const url=new URL(request.url);
  if(url.origin!==self.location.origin||url.pathname==='/shared/js/config.js')return;
  if(!/^\/(?:(?:shared|auth|admin|seller|verify)\/|landing\.(?:css|js)$)/.test(url.pathname)||!(/\.(?:css|js|png|jpe?g|svg|webp|woff2?)$/i.test(url.pathname)))return;

  event.respondWith((async()=>{
    const cache=await caches.open(CACHE_NAME);
    try{
      const response=await fetch(request,{cache:'no-cache'});
      if(response.ok&&response.type==='basic')await cache.put(request,response.clone());
      return response;
    }catch{
      return (await cache.match(request))||new Response('This app asset is not available offline.',{status:503,headers:{'Content-Type':'text/plain;charset=UTF-8'}});
    }
  })());
});
