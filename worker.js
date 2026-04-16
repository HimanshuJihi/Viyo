const CACHE_NAME = 'Viyou-v6'; // Cache version updated
const urlsToCache = [
  '/',
  '/index.html',
  '/profile.html',
  '/write-blog.html',
  '/privacy.html',
  '/terms.html',
  '/about-us.html',
  '/studio.html',
  '/story-editor.html',
  '/manifest.json',
  '/logo.png', // Main App Logo & PWA Icon
  '/favicon.ico' // Favicon
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => {
        console.log('Opened cache');
        return cache.addAll(urlsToCache);
      })
  );
});

self.addEventListener('fetch', event => {
  event.respondWith(
    caches.match(event.request)
      .then(response => {
        // Cache hit - return response
        if (response) {
          return response;
        }

        const fetchRequest = event.request.clone();

        return fetch(fetchRequest).then(
          response => {
            // Check if we received a valid response
            if (!response || response.status !== 200 || response.type !== 'basic') {
              return response;
            }

            const responseToCache = response.clone();

            caches.open(CACHE_NAME)
              .then(cache => {
                // Only cache GET requests and non-Firebase/non-Adsense data
                // Firebase और Adsense API को कैश करने से बचना चाहिए
                if (event.request.method === 'GET' && 
                    !event.request.url.includes('firebase') &&
                    !event.request.url.includes('googlesyndication')) {
                    cache.put(event.request, responseToCache);
                }
              });

            return response;
          }
        ).catch(error => {
          console.error('Fetch failed (offline or blocked URL):', error);
        });
      })
    );
});

self.addEventListener('activate', event => {
  const cacheWhitelist = [CACHE_NAME];
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(
        cacheNames.map(cacheName => {
          if (cacheWhitelist.indexOf(cacheName) === -1) {
            return caches.delete(cacheName);
          }
        })
      );
    })
  );
});
