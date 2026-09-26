/* Southie's HQ — background push notifications (Firebase Cloud Messaging). */
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "AIzaSyD16FWU6m3bTat7qvoj5EO80zsqY9twPJI",
  authDomain: "southies-hq.firebaseapp.com",
  projectId: "southies-hq",
  storageBucket: "southies-hq.firebasestorage.app",
  messagingSenderId: "690963842889",
  appId: "1:690963842889:web:e0f0aad7598b4b5b4b3c98"
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage(payload => {
  const n = payload.notification || {};
  const data = payload.data || {};
  self.registration.showNotification(n.title || "Southie's HQ", {
    body: n.body || '',
    icon: '/hq/icon-192.png',
    badge: '/hq/icon-192.png',
    data: {url: data.url || '/hq/'}
  });
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/hq/';
  event.waitUntil(
    clients.matchAll({type: 'window', includeUncontrolled: true}).then(list => {
      for (const c of list) { if ('focus' in c) { c.navigate(url); return c.focus(); } }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});
