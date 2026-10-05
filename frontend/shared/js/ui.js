/* Shared responsive navigation, theme, accessibility, and feedback controls. */
(() => {
  const body = document.body;
  const sidebar = document.querySelector('.sidebar');
  const main = document.querySelector('.content');
  const isAdmin = location.pathname.startsWith('/admin/');
  const currentPath = location.pathname.replace(/\/+$/, '') || '/';

  document.querySelectorAll('#msg,#csvMsg,#createMsg,#permMsg,#passwordMsg').forEach(message => {
    if (!message.hasAttribute('role')) message.setAttribute('role', 'status');
    if (!message.hasAttribute('aria-live')) message.setAttribute('aria-live', 'polite');
  });

  const adminGroups = [
    ['Overview', [['HM', 'Dashboard', '/admin/']]],
    ['Stock & supply', [['IN', 'Inventory', '/admin/pages/inventory/'], ['RC', 'Receiving', '/admin/pages/receiving/'], ['PO', 'Purchasing', '/admin/pages/purchasing/'], ['SU', 'Suppliers', '/admin/pages/suppliers/'], ['AD', 'Adjustments', '/admin/pages/adjustments/']]],
    ['Sales & money', [['SL', 'Sales', '/admin/pages/sales/'], ['PY', 'Payments', '/admin/pages/payments/'], ['RX', 'Prescriptions', '/admin/pages/prescriptions/'], ['EX', 'Expenses', '/admin/pages/expenses/'], ['RP', 'Reports', '/admin/pages/reports/'], ['ED', 'Reconciliation', '/admin/pages/reconciliation/']]],
    ['People & operations', [['ST', 'Staff', '/admin/pages/users/'], ['OK', 'Approvals', '/admin/pages/approvals/'], ['!', 'Alerts', '/admin/pages/alerts/'], ['AI', 'Intelligence', '/admin/pages/intelligence/'], ['OP', 'Operations', '/admin/pages/operations/']]],
    ['Security & settings', [['SC', 'Security', '/admin/pages/security/'], ['DV', 'Sessions', '/admin/pages/sessions/'], ['SE', 'Settings', '/admin/pages/settings/']]],
    ['Account', [['->', 'Sign out', '#', true]]],
  ];
  const sellerGroups = [
    ['Workspace', [['HM', 'Workspace', '/seller/'], ['POS', 'Point of sale', '/seller/pages/pos/']]],
    ['My work', [['RX', 'Prescriptions', '/seller/pages/prescriptions/'], ['RC', 'Receipts', '/seller/pages/receipts/'], ['SH', 'My shift', '/seller/pages/shift/']]],
    ['Account', [['->', 'Sign out', '#', true]]],
  ];

  if (sidebar && !sidebar.id) sidebar.id = 'sidebar';
  if (sidebar) {
    let nav = sidebar.querySelector('.nav');
    if (!nav) { nav = document.createElement('nav'); nav.className = 'nav'; sidebar.append(nav); }
    const groups = isAdmin ? adminGroups : location.pathname.startsWith('/seller/') ? sellerGroups : null;
    if (groups) {
      nav.setAttribute('aria-label', isAdmin ? 'Admin navigation' : 'Sales navigation');
      nav.replaceChildren(...groups.map(([title, items]) => {
        const collapsible = isAdmin && title !== 'Overview' && title !== 'Account';
        const section = document.createElement(collapsible ? 'details' : 'div');
        section.className = collapsible ? 'nav-group nav-disclosure' : 'nav-group';
        if (title === 'Account') section.classList.add('nav-account');
        section.setAttribute('aria-label', title);
        const activeGroup = items.some(([, , href]) => href !== '#' && (new URL(href, location.origin).pathname.replace(/\/+$/, '') || '/') === currentPath);
        const storedOpen = (() => { try { return localStorage.getItem(`pharmacy-admin-nav-${title}`) === 'open'; } catch { return false; } })();
        if (collapsible) section.open = activeGroup || storedOpen;
        const heading = document.createElement(collapsible ? 'summary' : 'span');
        heading.className = 'nav-group-title'; heading.textContent = title; section.append(heading);
        if (collapsible) section.addEventListener('toggle', () => {
          try { localStorage.setItem(`pharmacy-admin-nav-${title}`, section.open ? 'open' : 'closed'); } catch {}
        });
        for (const [icon, label, href, signOut] of items) {
          const link = document.createElement('a'); link.href = href;
          if (signOut) link.id = 'logout';
          const symbol = document.createElement('span');
          symbol.className = 'nav-icon'; symbol.setAttribute('aria-hidden', 'true'); symbol.textContent = icon;
          const text = document.createElement('span'); text.className = 'nav-label'; text.textContent = label;
          link.append(symbol, text); section.append(link);
        }
        return section;
      }));
    }
  }

  if (sidebar && main && !main.querySelector('.mobile-top')) {
    const top = document.createElement('div'); top.className = 'mobile-top';
    const heading = document.createElement('strong');
    heading.textContent = sidebar.querySelector('.brand h2')?.textContent?.trim() || 'Pharmacy Workspace';
    top.append(heading); main.prepend(top);
  }

  const mobileTop = main?.querySelector('.mobile-top');
  if (mobileTop) {
    let actions = mobileTop.querySelector('.mobile-top-actions');
    if (!actions) { actions = document.createElement('div'); actions.className = 'mobile-top-actions'; mobileTop.append(actions); }
    const existingMenu = mobileTop.querySelector('#menuBtn');
    if (sidebar && existingMenu && !actions.contains(existingMenu)) actions.prepend(existingMenu);
    if (sidebar && !actions.querySelector('#menuBtn')) {
      const menu = document.createElement('button');
      menu.type = 'button'; menu.className = 'mobile-menu'; menu.id = 'menuBtn'; menu.textContent = 'Menu';
      menu.setAttribute('aria-label', 'Open navigation'); menu.setAttribute('aria-expanded', 'false');
      actions.prepend(menu);
    }
    const existingTheme = mobileTop.querySelector('.mobile-theme');
    if (existingTheme && !actions.contains(existingTheme)) actions.append(existingTheme);
    if (!actions.querySelector('.mobile-theme')) {
      const theme = document.createElement('button');
      theme.type = 'button'; theme.className = 'mobile-theme'; theme.id = 'themeBtn'; theme.textContent = '◐';
      theme.setAttribute('aria-label', 'Toggle theme'); actions.append(theme);
    }
  }

  let savedTheme = 'light';
  try { savedTheme = localStorage.getItem('pharmacy-theme') || 'light'; } catch {}
  const setTheme = dark => {
    body.classList.toggle('dark', dark);
    try { localStorage.setItem('pharmacy-theme', dark ? 'dark' : 'light'); } catch {}
    document.querySelectorAll('#themeBtn,.mobile-theme').forEach(button => {
      button.setAttribute('aria-label', dark ? 'Switch to light mode' : 'Switch to dark mode');
      button.textContent = dark ? '☀' : '◐';
    });
  };
  document.querySelectorAll('#themeBtn,.mobile-theme').forEach(button => {
    button.addEventListener('click', () => setTheme(!body.classList.contains('dark')));
  });
  setTheme(savedTheme === 'dark');

  const menuButton = document.querySelector('#menuBtn');
  const mobileQuery = window.matchMedia('(max-width: 900px)');
  const isMobile = () => mobileQuery.matches;
  const closeNav = (restoreFocus = false) => {
    sidebar?.classList.remove('open');
    if (sidebar && isMobile()) sidebar.inert = true;
    menuButton?.setAttribute('aria-expanded', 'false');
    body.classList.remove('nav-open');
    if (restoreFocus) menuButton?.focus();
  };
  const openNav = () => {
    if (sidebar) { sidebar.inert = false; sidebar.classList.add('open'); }
    menuButton?.setAttribute('aria-expanded', 'true');
    body.classList.add('nav-open');
    sidebar?.querySelector('.nav a[href]:not([href="#"])')?.focus();
  };
  if (menuButton && sidebar) {
    menuButton.setAttribute('aria-controls', sidebar.id);
    menuButton.addEventListener('click', () => sidebar.classList.contains('open') ? closeNav() : openNav());
  }
  sidebar?.querySelectorAll('.nav a').forEach(link => link.addEventListener('click', () => closeNav()));
  const syncNavViewport = () => {
    if (!sidebar) return;
    if (!isMobile()) { sidebar.classList.remove('open'); body.classList.remove('nav-open'); }
    sidebar.inert = isMobile() && !sidebar.classList.contains('open');
    menuButton?.setAttribute('aria-expanded', String(sidebar.classList.contains('open')));
  };
  syncNavViewport();
  window.addEventListener('resize', syncNavViewport, { passive: true });
  mobileQuery.addEventListener('change', syncNavViewport);

  if (sidebar) {
    let backdrop = document.querySelector('.nav-backdrop');
    if (!backdrop) { backdrop = document.createElement('div'); backdrop.className = 'nav-backdrop'; body.append(backdrop); }
    backdrop.setAttribute('aria-hidden', 'true');
    backdrop.addEventListener('click', () => closeNav(true));
  }

  document.querySelectorAll('.nav a[href]').forEach(link => {
    const href = link.getAttribute('href');
    if (!href || href === '#') return;
    const target = new URL(href, location.origin).pathname.replace(/\/+$/, '') || '/';
    const active = target === currentPath;
    link.classList.toggle('active', active);
    if (active) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current');
  });

  if (sidebar && !document.querySelector('.mobile-bottom-nav')) {
    const hrefs = isAdmin ? ['/admin/', '/admin/pages/inventory/', '/admin/pages/sales/']
      : ['/seller/', '/seller/pages/pos/', '/seller/pages/receipts/'];
    const nav = document.createElement('nav'); nav.className = 'mobile-bottom-nav';
    nav.setAttribute('aria-label', 'Primary navigation');
    let activeShortcut = false;
    for (const href of hrefs) {
      const source = sidebar.querySelector(`.nav a[href="${href}"]`);
      if (!source) continue;
      const link = document.createElement('a'); link.href = href;
      link.textContent = source.querySelector('.nav-label')?.textContent?.trim() || source.textContent.trim();
      if ((new URL(href, location.origin).pathname.replace(/\/+$/, '') || '/') === currentPath) {
        link.classList.add('active'); link.setAttribute('aria-current', 'page'); activeShortcut = true;
      }
      nav.append(link);
    }
    const more = document.createElement('button'); more.type = 'button'; more.textContent = 'More';
    more.setAttribute('aria-label', 'Open all navigation');
    if (!activeShortcut) { more.classList.add('active'); more.setAttribute('aria-current', 'page'); }
    more.addEventListener('click', openNav); nav.append(more); body.append(nav);
  }

  document.addEventListener('keydown', event => {
    if (sidebar?.classList.contains('open') && isMobile()) {
      if (event.key === 'Escape') { event.preventDefault(); closeNav(true); return; }
      if (event.key === 'Tab') {
        const focusable = [...sidebar.querySelectorAll('a[href]:not([href="#"]),button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex]:not([tabindex="-1"])')]
          .filter(element => !element.hidden && element.getClientRects().length);
        const first = focusable[0], last = focusable.at(-1);
        if (event.shiftKey && (document.activeElement === first || !sidebar.contains(document.activeElement))) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && (document.activeElement === last || !sidebar.contains(document.activeElement))) { event.preventDefault(); first?.focus(); }
      }
    }
    if (event.key !== '/' || /input|textarea|select|button/i.test(document.activeElement?.tagName || '')) return;
    const search = document.querySelector('input[type="search"], input[placeholder*="Search" i], input[placeholder*="scan" i]');
    if (search) { event.preventDefault(); search.focus(); }
  });

  // Leave asynchronous forms in charge of their own loading and error states.
  document.addEventListener('submit', event => {
    if (event.defaultPrevented) return;
    const button = event.submitter || event.target.querySelector('button[type="submit"]');
    if (!button || button.hasAttribute('data-no-busy')) return;
    button.disabled = true; button.setAttribute('aria-busy', 'true');
    const spinner = document.createElement('span'); spinner.className = 'spinner'; spinner.setAttribute('aria-hidden', 'true');
    button.replaceChildren(spinner, document.createTextNode(' Processing…'));
  });

  document.addEventListener('click', event => {
    const logout = event.target instanceof Element ? event.target.closest('#logout') : null;
    if (logout && !event.defaultPrevented) {
      event.preventDefault();
      if (typeof window.pharmacyAuth?.signOut === 'function') window.pharmacyAuth.signOut();
      else location.href = location.pathname.startsWith('/admin/') ? '/auth/admin/' : '/auth/';
      return;
    }
    const button = event.target instanceof Element ? event.target.closest('[data-prevent-double]') : null;
    if (!button || button.disabled) return;
    button.disabled = true;
    window.setTimeout(() => { button.disabled = false; }, 3000);
  });

  document.querySelectorAll('#stayBtn').forEach(button => button.addEventListener('click', () => window.dispatchEvent(new CustomEvent('session-stay'))));
  window.addEventListener('session-warning-clear', () => document.querySelectorAll('.session-warning').forEach(element => { element.hidden = true; }));

  if (sidebar && !sidebar.querySelector('.brand')) {
    const heading = sidebar.querySelector(':scope > h2');
    const brand = document.createElement('div'); brand.className = 'brand';
    const logo = document.createElement('img'); logo.className = 'brand-mark'; logo.src = '/shared/assets/ella-afya-mark.png'; logo.alt = 'Ella Afya Pharmacy';
    const copy = document.createElement('div'), name = document.createElement('h2'), subtitle = document.createElement('small');
    name.textContent = heading?.textContent?.trim() || 'Ella Afya'; subtitle.textContent = 'Pharmacy Workspace'; copy.append(name, subtitle); brand.append(logo, copy);
    heading?.remove(); sidebar.prepend(brand);
  }

  document.querySelectorAll('.table-wrap').forEach(wrap => {
    const check = () => wrap.classList.toggle('is-scrollable', wrap.scrollWidth > wrap.clientWidth + 4);
    check(); window.addEventListener('resize', check, { passive: true });
  });

  const setNetworkState = () => {
    let indicator = document.querySelector('.network-state');
    if (!indicator) { indicator = document.createElement('div'); indicator.className = 'network-state'; indicator.setAttribute('role', 'status'); indicator.setAttribute('aria-live', 'polite'); body.append(indicator); }
    indicator.hidden = navigator.onLine;
    if (!navigator.onLine) indicator.textContent = 'Offline — changes will not be sent until your connection returns.';
  };
  window.addEventListener('online', setNetworkState); window.addEventListener('offline', setNetworkState); setNetworkState();

  window.pharmacyUI = {
    toast(message, type = 'info') {
      let host = document.querySelector('.toast-host');
      if (!host) { host = document.createElement('div'); host.className = 'toast-host'; host.setAttribute('aria-live', 'polite'); body.append(host); }
      const item = document.createElement('div');
      const allowedTypes = new Set(['info', 'success', 'warning', 'error']);
      item.className = `toast toast-${allowedTypes.has(type) ? type : 'info'}`;
      item.setAttribute('role', type === 'error' ? 'alert' : 'status');
      const text = document.createElement('span'); text.textContent = String(message ?? '');
      const dismiss = document.createElement('button'); dismiss.type = 'button'; dismiss.setAttribute('aria-label', 'Dismiss notification'); dismiss.textContent = '×';
      item.append(text, dismiss); host.append(item);
      dismiss.addEventListener('click', () => item.remove());
      window.setTimeout(() => item.remove(), 5000);
    },
    escapeHtml(value) {
      return String(value ?? '').replace(/[&<>"']/g, character => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
      })[character]);
    },
    setTheme, closeNav, openNav,
  };
})();
