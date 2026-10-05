(() => {
  const canUseServiceWorker = 'serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost');
  if (canUseServiceWorker) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(error => {
        console.warn('App install support could not start.', error.message);
      });
    }, { once: true });
  }

  let installPrompt = null;
  const existingButton = document.querySelector('[data-pwa-install]');
  const button = existingButton || document.createElement('button');
  button.type = 'button';
  if (!existingButton) {
    button.className = document.querySelector('.auth-panel-inner') ? 'secondary-btn pwa-install-btn' : 'btn secondary pwa-install-btn';
    button.textContent = 'Install app';
  }
  button.hidden = true;
  button.addEventListener('click', async () => {
    if (!installPrompt) return;
    await installPrompt.prompt();
    const choice = await installPrompt.userChoice;
    if (choice?.outcome === 'accepted') button.hidden = true;
    installPrompt = null;
  });

  const host = document.querySelector('.page-head .portal-tools');
  const authHeading = document.querySelector('.auth-panel-inner .form-heading');
  if (!button.isConnected && host) host.prepend(button);
  else if (!button.isConnected && authHeading) authHeading.insertAdjacentElement('afterend', button);

  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault();
    installPrompt = event;
    button.hidden = false;
  });
  window.addEventListener('appinstalled', () => {
    button.hidden = true;
    installPrompt = null;
  });
})();
