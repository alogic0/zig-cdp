self.addEventListener('install',e=>e.waitUntil(self.skipWaiting()));
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('message',e=>e.waitUntil((async()=>{await fetch('/api/save',{method:'POST'}).then(r=>r.text());console.log('service evidence '+e.data);e.source.postMessage(e.data);})()));
