const PERSISTENCE_KEY = 'pharmacy_session_hint';

export function createAuthStorage(localStore, sessionStore) {
  const observedKeys = new Set();
  const isSessionOnly = () => sessionStore.getItem(PERSISTENCE_KEY) === 'session';

  return {
    getItem(key) {
      observedKeys.add(key);
      if (isSessionOnly()) return sessionStore.getItem(key);
      return localStore.getItem(key) ?? sessionStore.getItem(key);
    },
    setItem(key, value) {
      observedKeys.add(key);
      const sessionOnly = isSessionOnly();
      const destination = sessionOnly ? sessionStore : localStore;
      const other = sessionOnly ? localStore : sessionStore;
      other.removeItem(key);
      destination.setItem(key, value);
    },
    removeItem(key) {
      observedKeys.add(key);
      localStore.removeItem(key);
      sessionStore.removeItem(key);
    },
    setPersistence(remember) {
      localStore.removeItem(PERSISTENCE_KEY);
      if (remember) sessionStore.removeItem(PERSISTENCE_KEY);
      else sessionStore.setItem(PERSISTENCE_KEY, 'session');

      const destination = remember ? localStore : sessionStore;
      const other = remember ? sessionStore : localStore;
      for (const key of observedKeys) {
        const value = localStore.getItem(key) ?? sessionStore.getItem(key);
        localStore.removeItem(key);
        sessionStore.removeItem(key);
        if (value !== null) destination.setItem(key, value);
      }
    },
  };
}