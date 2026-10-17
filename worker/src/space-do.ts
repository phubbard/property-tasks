import { DurableObject } from "cloudflare:workers";
import {
  ProjectionError, applyEvent, serialize, uuidv7,
  type Event, type Member, type Serialized, type StampedEvent,
} from "@property-tasks/shared";
import { SCHEMA, SqlStore } from "./sql-store.js";

export type PushResult =
  | { ok: true; seqs: Record<string, number> }
  | { ok: false; error: string; eventId: string | null };

export interface PullResult {
  events: StampedEvent[];
  nextSeq: number;
  hasMore: boolean;
}

export interface Snapshot extends Serialized {
  spaceId: string;
  seq: number;
}

type EventRow = {
  seq: number; id: string; node_id: string | null; actor_id: string; device_id: string;
  at: number; received_at: number; type: string; payload: string;
};

interface SocketState {
  userId: string;
  deviceId: string;
}

const WRITER_ROLES = new Set<Member["role"]>(["owner", "editor"]);

/**
 * One Durable Object per Space: the canonical append-only event log, a
 * SQL projection of it, the member list, and the live sockets. See DESIGN.md §5, §11.
 */
export class SpaceDO extends DurableObject<Env> {
  private readonly store: SqlStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new SqlStore(ctx.storage.sql);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(SCHEMA);
    });
  }

  private meta(key: string): string | null {
    const rows = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray();
    return rows[0]?.value ?? null;
  }

  /** Create the Space with its first member. Idempotent. */
  async init(spaceId: string, owner: { userId: string; displayName: string }, at: number): Promise<{ created: boolean }> {
    if (this.meta("spaceId") !== null) return { created: false };
    this.ctx.storage.sql.exec("INSERT INTO meta (key, value) VALUES ('spaceId', ?)", spaceId);
    const joined: Event = {
      id: uuidv7(at), spaceId, nodeId: null, actorId: owner.userId, deviceId: "server", at,
      type: "member.joined", payload: { userId: owner.userId, role: "owner", displayName: owner.displayName },
    };
    this.commit([joined], at, { skipRoleCheck: true });
    return { created: true };
  }

  async getMember(userId: string): Promise<Member | null> {
    return this.store.getMember(userId) ?? null;
  }

  /**
   * Append a batch. Idempotent on event id. Either every new event applies
   * or none does; a rejection names the offending event.
   */
  async pushEvents(actorId: string, events: Event[]): Promise<PushResult> {
    const spaceId = this.meta("spaceId");
    if (spaceId === null) return { ok: false, error: "space not initialised", eventId: null };
    for (const ev of events) {
      if (ev.actorId !== actorId) return { ok: false, error: "actorId must match the signed-in user", eventId: ev.id };
      if (ev.spaceId !== spaceId) return { ok: false, error: "spaceId mismatch", eventId: ev.id };
    }
    return this.commit(events, Date.now(), { skipRoleCheck: false });
  }

  private commit(events: Event[], receivedAt: number, opts: { skipRoleCheck: boolean }): PushResult {
    const seqs: Record<string, number> = {};
    const fresh: StampedEvent[] = [];
    try {
      this.ctx.storage.transactionSync(() => {
        for (const ev of events) {
          const existing = this.ctx.storage.sql.exec<{ seq: number }>("SELECT seq FROM events WHERE id = ?", ev.id).toArray()[0];
          if (existing) {
            seqs[ev.id] = existing.seq;
            continue;
          }
          if (!opts.skipRoleCheck) {
            const m = this.store.getMember(ev.actorId);
            if (!m || !WRITER_ROLES.has(m.role)) throw new ProjectionError("not a writer in this space", ev.id);
          }
          applyEvent(this.store, ev);
          const row = this.ctx.storage.sql.exec<{ seq: number }>(
            `INSERT INTO events (id, node_id, actor_id, device_id, at, received_at, type, payload)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING seq`,
            ev.id, ev.nodeId, ev.actorId, ev.deviceId, ev.at, receivedAt, ev.type, JSON.stringify(ev.payload),
          ).one();
          seqs[ev.id] = row.seq;
          fresh.push({ ...ev, seq: row.seq, receivedAt });
        }
      });
    } catch (e) {
      if (e instanceof ProjectionError) return { ok: false, error: e.message, eventId: e.eventId };
      throw e;
    }
    if (fresh.length > 0) this.broadcast(fresh);
    return { ok: true, seqs };
  }

  async pullEvents(sinceSeq: number, limit = 500): Promise<PullResult> {
    const rows = this.ctx.storage.sql
      .exec<EventRow>("SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?", sinceSeq, limit + 1)
      .toArray();
    const hasMore = rows.length > limit;
    const spaceId = this.meta("spaceId") ?? "";
    const page = rows.slice(0, limit).map((r) => rowToEvent(r, spaceId));
    const last = page[page.length - 1];
    return { events: page, nextSeq: last ? last.seq : sinceSeq, hasMore };
  }

  async snapshot(): Promise<Snapshot> {
    const seqRow = this.ctx.storage.sql.exec<{ seq: number | null }>("SELECT MAX(seq) AS seq FROM events").one();
    return { spaceId: this.meta("spaceId") ?? "", seq: seqRow.seq ?? 0, ...serialize(this.store) };
  }

  // ---- live updates over hibernating WebSockets ----

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 });
    const userId = request.headers.get("x-user-id");
    const deviceId = request.headers.get("x-device-id") ?? "unknown";
    if (!userId) return new Response("missing user", { status: 400 });
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server, [userId]);
    const state: SocketState = { userId, deviceId };
    server.serializeAttachment(state);
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    let msg: { type?: string; since?: number };
    try {
      msg = JSON.parse(message) as { type?: string; since?: number };
    } catch {
      ws.send(JSON.stringify({ type: "error", error: "bad json" }));
      return;
    }
    if (msg.type === "ping") ws.send(JSON.stringify({ type: "pong" }));
    else if (msg.type === "pull") ws.send(JSON.stringify({ type: "events", ...(await this.pullEvents(msg.since ?? 0)) }));
  }

  override async webSocketClose(): Promise<void> {
    // Nothing to clean up: per-socket state lives in the attachment and dies with the socket.
  }

  private broadcast(events: StampedEvent[]): void {
    const payload = JSON.stringify({ type: "events", events });
    const from = new Set(events.map((e) => e.deviceId));
    for (const ws of this.ctx.getWebSockets()) {
      const state = ws.deserializeAttachment() as SocketState | null;
      if (state && from.has(state.deviceId)) continue; // the author already has these
      try {
        ws.send(payload);
      } catch (e) {
        console.warn(JSON.stringify({ level: "warn", message: "ws send failed", error: String(e) }));
      }
    }
  }
}

function rowToEvent(r: EventRow, spaceId: string): StampedEvent {
  return {
    id: r.id, spaceId, nodeId: r.node_id, actorId: r.actor_id, deviceId: r.device_id, at: r.at,
    type: r.type, payload: JSON.parse(r.payload), seq: r.seq, receivedAt: r.received_at,
  } as StampedEvent;
}
