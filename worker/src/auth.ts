/**
 * Authentication. Today: a dev stub so the API can be exercised locally.
 *
 * TODO(auth): replace with real sessions (DESIGN.md §6):
 *   - passkeys (WebAuthn) registered and asserted in the Worker, credentials in D1
 *   - Sign in with Apple for the native app, exchanged for the same session token
 *   - emailed magic link as fallback
 *   - opaque session token stored hashed in D1 `sessions`; cookie on web, bearer on native
 * Until then, when DEV_USER is set every request is that user, and the
 * `X-Dev-User` header can impersonate another user id so membership checks
 * can be exercised. Never set DEV_USER in production.
 */
export interface User {
  id: string;
  displayName: string;
}

export function authenticate(request: Request, env: Env): User | null {
  const dev = env.DEV_USER;
  if (dev) {
    const id = request.headers.get("x-dev-user") ?? dev;
    return { id, displayName: id };
  }
  // TODO(auth): look up `Authorization: Bearer` / session cookie in D1.
  return null;
}
