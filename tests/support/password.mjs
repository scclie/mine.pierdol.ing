import { redact, registerPasswords } from '../../scripts/test-secrets.mjs';

export { registerPasswords };

export async function fillPassword(locator, password, options) {
  registerPasswords([password]);
  try { await locator.fill(password, options); }
  catch (error) {
    const safe = new Error(redact(error.message));
    safe.name = error.name;
    throw safe;
  }
}
