const CACHE_NAME='ella-afya-static-v2';
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

  const cachePromise=caches.open(CACHE_NAME);
  const update=cachePromise.then(cache=>fetch(request).then(response=>{
    if(response.ok&&response.type==='basic')return cache.put(request,response.clone()).then(()=>response);
    return response;
  }));
  event.waitUntil(update.catch(()=>{}));
  event.respondWith((async()=>{
    const cache=await cachePromise;
    const cached=await cache.match(request);
    if(cached)return cached;
    try{return await update;}
    catch{return new Response('This app asset is not available offline.',{status:503,headers:{'Content-Type':'text/plain;charset=UTF-8'}});}
  })());
});
