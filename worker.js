const CACHE_NAME = 'Viyou-v5'; // Cache version ko update kiya gaya hai
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
  // पुराना लोगो 'game-logo.png' हटा दिया गया है।
  // कृपया सुनिश्चित करें कि नीचे दिए गए पाथ आपके नए लोगो और आइकॉन से मेल खाते हैं।
  '/logo.png', // <-- अपना मुख्य लोगो यहां डालें
  '/favicon.ico', // <-- अपना favicon यहां डालें
  '/icons/icon-192x192.png', // <-- PWA के लिए आइकॉन
  '/icons/icon-512x512.png'  // <-- PWA के लिए आइकॉन
  // अगर और भी आइकॉन हैं, तो उन्हें भी यहां जोड़ें, जैसे: '/icons/icon-144x144.png'
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
