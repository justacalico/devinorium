// Devinorium push service worker.
//
// Registered under the app's base path (…/push/) so it never interferes with
// the Flutter service worker that owns the app shell. It only exists to
// receive push events while the app is closed, surface notifications, and
// route clicks back to the right thread.

var APP_BASE = self.registration.scope.replace(/push\/$/, '');
var ICON = APP_BASE + 'icons/Icon-192.png';
var BADGE = APP_BASE + 'icons/Icon-192.png';

self.addEventListener('push', function (event) {
  var data = {};
  if (event.data) {
    try {
      data = event.data.json();
    } catch (e) {
      try {
        data = { title: 'Devinorium', body: event.data.text() };
      } catch (e2) {}
    }
  }
  var title = data.title || 'Devinorium';
  var urgent = data.kind === 'permission' || data.kind === 'ask';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: data.body || '',
      tag: data.tag || 'devinorium',
      // Attention requests replace themselves when the flag flips; the tag
      // the backend sends already encodes kind + thread.
      renotify: urgent,
      requireInteraction: urgent,
      icon: ICON,
      badge: BADGE,
      data: {
        thread_id: data.thread_id || '',
        kind: data.kind || '',
      },
    })
  );
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var threadId =
    (event.notification.data && event.notification.data.thread_id) || '';
  var target = threadId
    ? APP_BASE + '?thread=' + encodeURIComponent(threadId)
    : APP_BASE;
  event.waitUntil(
    clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then(function (list) {
        for (var i = 0; i < list.length; i++) {
          var client = list[i];
          if (
            new URL(client.url).origin === self.location.origin &&
            'focus' in client
          ) {
            client.postMessage({ type: 'open_thread', thread_id: threadId });
            return client.focus();
          }
        }
        if (clients.openWindow) {
          return clients.openWindow(target);
        }
      })
  );
});

// The browser rotated the subscription (key refresh or expiry). The app is
// authenticated with cookies, which are included on same-origin fetches, so
// the worker can re-register the fresh endpoint on its own.
self.addEventListener('pushsubscriptionchange', function (event) {
  event.waitUntil(
    (async function () {
      var keyResp = await fetch(APP_BASE + 'api/push/vapid-key', {
        credentials: 'same-origin',
      });
      if (!keyResp.ok) return;
      var keyJson = await keyResp.json();
      var raw = urlBase64ToUint8Array(keyJson.public_key);
      var sub = await self.registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: raw,
      });
      var json = sub.toJSON();
      await fetch(APP_BASE + 'api/push/subscriptions', {
        method: 'PUT',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          endpoint: json.endpoint,
          keys: json.keys,
          lang: (self.navigator.language || 'en').slice(0, 16),
        }),
      });
    })().catch(function () {})
  );
});

function urlBase64ToUint8Array(base64) {
  var padding = '='.repeat((4 - (base64.length % 4)) % 4);
  var raw = atob((base64 + padding).replace(/-/g, '+').replace(/_/g, '/'));
  var out = new Uint8Array(raw.length);
  for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
