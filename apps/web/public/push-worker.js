/* global self, URL */

self.addEventListener('push', (event) => {
  const payload = event.data?.json();
  if (!payload || typeof payload.title !== 'string' || typeof payload.body !== 'string') return;
  event.waitUntil(self.registration.showNotification(payload.title, {
    body: payload.body, icon: '/apnacircle-icon-192.png',
    data: typeof payload.url === 'string' ? payload.url : '/me/notifications',
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL(typeof event.notification.data === 'string' ? event.notification.data : '/', self.location.origin);
  const target = url.origin === self.location.origin ? url.href : self.location.origin + '/me/notifications';
  event.waitUntil(self.clients.openWindow(target));
});
