import { supabase } from './supabase.js';
import { ensureDeviceSession, requireAdminMFA, startSecurityControls } from './security.js';

export async function requireUser(roles = []) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    location.href = '/auth/';
    throw new Error('Not authenticated');
  }

  const { data: profile, error } = await supabase
    .from('profiles')
    .select('role,active,full_name')
    .eq('id', user.id)
    .single();

  if (error || !profile?.active || (roles.length && !roles.includes(profile.role))) {
    await supabase.auth.signOut();
    location.href = '/auth/';
    throw new Error('Access denied');
  }

  if (!(await ensureDeviceSession())) {
    throw new Error('Device session revoked');
  }

  startSecurityControls();

  if (profile.role === 'admin' && !(await requireAdminMFA())) {
    throw new Error('MFA required');
  }

  return { user, profile };
}

export async function signOut() {
  try {
    sessionStorage.removeItem('pharmacy_device_session');
    await supabase.auth.signOut();
  } finally {
    location.href = '/auth/';
  }
}

// Shared navigation can sign out pages whose feature module does not wire its own link.
window.pharmacyAuth = Object.freeze({ signOut });

export async function changePassword(password) {
  return supabase.auth.updateUser({ password });
}

export async function getMfaFactors() {
  return supabase.auth.mfa.listFactors();
}

export async function enrollMfa(friendlyName = 'Ella Afya Admin') {
  return supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName });
}

export async function verifyMfa(factorId, code) {
  const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({ factorId });
  if (challengeError) return { data: null, error: challengeError };
  return supabase.auth.mfa.verify({ factorId, challengeId: challenge.id, code });
}
