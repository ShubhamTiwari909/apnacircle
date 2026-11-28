/* global atob, fetch, document, navigator, window */
const panel = document.querySelector('[data-member-push]');
if (panel) {
  const enable = panel.querySelector('[data-push-enable]');
  const disable = panel.querySelector('[data-push-disable]');
  const status = panel.querySelector('[data-push-status]');
  const unavailable = () => { status.textContent = panel.dataset.pushUnavailable; };
  const update = (subscription) => {
    enable.hidden = Boolean(subscription);
    disable.hidden = !subscription;
  };
  async function send(method, body) {
    const result = await fetch('/me/notifications/subscription', {
      method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    if (!result.ok) throw new Error('Push subscription update failed');
  }
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) unavailable();
  else {
    const existingRegistration = navigator.serviceWorker.getRegistration('/');
    void existingRegistration.then(async (registration) => update(await registration?.pushManager.getSubscription())).catch(unavailable);
    enable.addEventListener('click', async () => {
      enable.disabled = true;
      try {
        const registration = await navigator.serviceWorker.register('/push-worker.js');
        const ready = registration.active ? registration : await navigator.serviceWorker.ready;
        const publicKey = panel.dataset.memberPush.replace(/-/g, '+').replace(/_/g, '/');
        const subscription = await ready.pushManager.getSubscription() ?? await ready.pushManager.subscribe({
          userVisibleOnly: true, applicationServerKey: Uint8Array.from(atob(publicKey), (char) => char.charCodeAt(0)),
        });
        const { endpoint, keys } = subscription.toJSON();
        try {
          await send('POST', { endpoint, p256dh: keys.p256dh, auth: keys.auth });
        } catch (error) {
          await subscription.unsubscribe();
          throw error;
        }
        update(subscription);
        status.textContent = panel.dataset.pushEnabled;
      } catch { unavailable(); }
      finally { enable.disabled = false; }
    });
    disable.addEventListener('click', async () => {
      disable.disabled = true;
      try {
        const registration = await navigator.serviceWorker.getRegistration('/');
        const subscription = await registration?.pushManager.getSubscription();
        if (subscription) {
          await send('DELETE', { endpoint: subscription.endpoint });
          await subscription.unsubscribe();
        }
        update(null);
        status.textContent = panel.dataset.pushDisabled;
      } catch { unavailable(); }
      finally { disable.disabled = false; }
    });
  }
}
