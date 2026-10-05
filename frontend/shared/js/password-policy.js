export const PASSWORD_MIN_LENGTH = 12;
export const PASSWORD_MAX_LENGTH = 128;
export const PASSWORD_POLICY_MESSAGE = 'Use 12–128 characters with uppercase, lowercase, a number and a symbol.';

export function passwordStrengthScore(value) {
  if (typeof value !== 'string' || value.length > PASSWORD_MAX_LENGTH) return 0;

  return [
    value.length >= PASSWORD_MIN_LENGTH,
    /[A-Z]/.test(value),
    /[a-z]/.test(value),
    /\d/.test(value),
    /[^A-Za-z0-9]/.test(value),
  ].filter(Boolean).length;
}

export function isStrongPassword(value) {
  return passwordStrengthScore(value) === 5;
}