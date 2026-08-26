// Service worker disabled: Cloudflare / Worker-specific caching removed per request.
// Keeping a no-op service worker file in place so existing registrations do not error.

self.addEventListener('install', (e) => { console.log('Service worker present but disabled.'); self.skipWaiting(); });
self.addEventListener('activate', (e) => { console.log('Service worker activation (no-op).'); });
self.addEventListener('fetch', (e) => { /* intentionally no fetch interception */ });
