const CACHE = 'nte-v1';
const SHELL = ['/index.html', '/logo.png', '/manifest.json'];

self.addEventListener('install', function(e){
  e.waitUntil(
    caches.open(CACHE).then(function(c){ return c.addAll(SHELL); }).catch(function(){})
  );
  self.skipWaiting();
});

self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.filter(function(k){ return k!==CACHE; }).map(function(k){ return caches.delete(k); }));
    })
  );
  self.clients.claim();
});

self.addEventListener('fetch', function(e){
  if(e.request.method!=='GET') return;
  if(e.request.url.includes('supabase.co')) return;  // never cache API
  if(e.request.url.includes('cdn.jsdelivr') || e.request.url.includes('cdnjs.cloudflare')) return;
  e.respondWith(
    caches.match(e.request).then(function(hit){
      return hit || fetch(e.request).then(function(res){
        if(res.ok){
          var clone=res.clone();
          caches.open(CACHE).then(function(c){ c.put(e.request,clone); });
        }
        return res;
      });
    }).catch(function(){
      return caches.match('/index.html');
    })
  );
});
