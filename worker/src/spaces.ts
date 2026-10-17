/** Space creation and the per-user Space index in D1. Shared by the JSON API and the HTML pages. */
import { uuidv7 } from "@property-tasks/shared";
import type { User } from "./auth.js";

export interface SpaceRow {
  id: string;
  role: string;
  title: string;
  joinedAt: number;
}

export async function createSpace(env: Env, user: User, rawTitle: unknown): Promise<{ id: string; title: string } | null> {
  const title = typeof rawTitle === "string" && rawTitle.trim() ? rawTitle.trim() : "Untitled space";
  const spaceId = uuidv7();
  const now = Date.now();
  const stub = env.SPACES.getByName(spaceId);
  const { created } = await stub.init(spaceId, { userId: user.id, displayName: user.displayName }, now);
  if (!created) return null;
  await env.IDENTITY.prepare(
    "INSERT INTO memberships (user_id, space_id, role, title, joined_at) VALUES (?, ?, 'owner', ?, ?)",
  ).bind(user.id, spaceId, title, now).run();
  return { id: spaceId, title };
}

export async function listSpaces(env: Env, user: User): Promise<SpaceRow[]> {
  const { results } = await env.IDENTITY.prepare(
    "SELECT space_id AS id, role, title, joined_at AS joinedAt FROM memberships WHERE user_id = ? ORDER BY joined_at",
  ).bind(user.id).all<SpaceRow>();
  return results;
}

export async function spaceTitle(env: Env, user: User, spaceId: string): Promise<string> {
  const row = await env.IDENTITY.prepare("SELECT title FROM memberships WHERE user_id = ? AND space_id = ?")
    .bind(user.id, spaceId).first<{ title: string }>();
  return row?.title ?? "Space";
}
