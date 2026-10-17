-- Identity: global lookups that belong to no single Space. See DESIGN.md §6, §11.
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
-- WebAuthn credentials (passkeys). TODO: populated once passkey registration exists.
CREATE TABLE IF NOT EXISTS credentials (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  public_key BLOB NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
-- Opaque session tokens, stored hashed. TODO: issued by the passkey / Sign in with Apple / magic-link flows.
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
-- Index of which Spaces a user belongs to. The SpaceDO's members table is authoritative; this is for listing.
CREATE TABLE IF NOT EXISTS memberships (
  user_id TEXT NOT NULL,
  space_id TEXT NOT NULL,
  role TEXT NOT NULL,
  title TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, space_id)
);
