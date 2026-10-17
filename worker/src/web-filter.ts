/**
 * Query parameters <-> the shared Filter (DESIGN.md §4, §7a). The filter bar
 * is a plain GET form whose fields carry the same names as the URL, so every
 * view is a shareable URL and submitting the form reproduces it.
 */
import {
  KINDS, PRIORITIES, STATUSES,
  type Filter, type Kind, type Node, type Priority, type SortBy, type Status,
} from "@property-tasks/shared";
import { html, raw, type Html } from "./html.js";

const SORTS: readonly SortBy[] = ["priority", "created", "lastActivity", "due", "tree"];
const HAS = ["photos", "documents", "due", "children"] as const;
const DUE = ["overdue", "week", "month"] as const;
const WHO_ROLES = ["touched", "created", "assigned"] as const;
type WhoRole = (typeof WHO_ROLES)[number];

export interface ParsedQuery {
  filter: Filter;
  sort: SortBy;
  /** Raw field values, kept so the form can mirror the URL exactly. */
  fields: {
    status: Status[]; anyStatus: boolean; priority: Priority[]; priorityMin: Priority | "";
    kind: Kind[]; label: string; under: string[]; ageMax: string; stale: string;
    who: string; whoRole: WhoRole; has: Array<(typeof HAS)[number]>; due: (typeof DUE)[number] | "";
    text: string; archived: boolean;
  };
  /** True when any narrowing parameter is present. */
  active: boolean;
}

function oneOf<T extends string>(list: readonly T[], v: string | null): v is T {
  return v !== null && (list as readonly string[]).includes(v);
}
function allOf<T extends string>(list: readonly T[], vs: string[]): T[] {
  return vs.filter((v): v is T => oneOf(list, v));
}
/** Repeated params and comma-separated values both work: ?label=a&label=b or ?label=a,b. */
function multi(params: URLSearchParams, name: string): string[] {
  return params.getAll(name).flatMap((v) => v.split(",")).map((v) => v.trim()).filter(Boolean);
}
function days(v: string | null): number | undefined {
  if (v === null || v.trim() === "") return undefined;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : undefined;
}

export function parseQuery(params: URLSearchParams): ParsedQuery {
  const statusRaw = multi(params, "status");
  const anyStatus = statusRaw.includes("any");
  const status = allOf(STATUSES, statusRaw);
  const priority = allOf(PRIORITIES, multi(params, "priority"));
  const pMin = params.get("priorityMin");
  const priorityMin: Priority | "" = oneOf(PRIORITIES, pMin) && pMin !== "none" ? pMin : "";
  const kind = allOf(KINDS, multi(params, "kind"));
  const labels = multi(params, "label");
  const under = multi(params, "under");
  const ageMax = days(params.get("ageMax"));
  const stale = days(params.get("stale"));
  const who = (params.get("who") ?? "").trim();
  const roleRaw = params.get("whoRole");
  const whoRole: WhoRole = oneOf(WHO_ROLES, roleRaw) ? roleRaw : "touched";
  const has = allOf(HAS, multi(params, "has"));
  const dueRaw = params.get("due");
  const due = oneOf(DUE, dueRaw) ? dueRaw : "";
  const text = (params.get("text") ?? "").trim();
  const archived = params.get("archived") === "1";
  const sortRaw = params.get("sort");
  const sort: SortBy = oneOf(SORTS, sortRaw) ? sortRaw : "priority";

  const filter: Filter = {};
  if (anyStatus) filter.status = [];
  else if (status.length > 0) filter.status = status;
  if (priority.length > 0) filter.priority = priority;
  if (priorityMin) filter.priorityMin = priorityMin;
  if (kind.length > 0) filter.kind = kind;
  if (labels.length > 0) filter.labels = labels;
  if (under.length > 0) filter.under = under;
  if (ageMax !== undefined) filter.ageMaxDays = ageMax;
  if (stale !== undefined) filter.staleDays = stale;
  if (who) {
    if (whoRole === "created") filter.createdBy = who;
    else if (whoRole === "assigned") filter.assigneeId = who;
    else filter.lastTouchedBy = who;
  }
  if (has.length > 0) filter.has = has;
  if (due) filter.due = due;
  if (text) filter.text = text;
  if (archived) filter.includeArchived = true;

  const active = Object.keys(filter).length > 0;
  return {
    filter, sort, active,
    fields: {
      status, anyStatus, priority, priorityMin, kind, label: labels.join(", "), under,
      ageMax: ageMax === undefined ? "" : String(ageMax), stale: stale === undefined ? "" : String(stale),
      who, whoRole, has, due, text, archived,
    },
  };
}

const pretty = (s: string): string => s.replace(/_/g, " ");

function checks(name: string, options: readonly string[], chosen: readonly string[]): Html {
  return html`${options.map((o) => html`<label><input type="checkbox" name="${name}" value="${o}"${chosen.includes(o) ? raw(" checked") : ""}> ${pretty(o)}</label>`)}`;
}
function select(name: string, id: string, options: readonly string[], chosen: string, blank: string | null): Html {
  return html`<select name="${name}" id="${id}">${blank === null ? "" : html`<option value="">${blank}</option>`}${options.map((o) =>
    html`<option value="${o}"${o === chosen ? raw(" selected") : ""}>${pretty(o)}</option>`)}</select>`;
}

/**
 * The filter bar. `containers` feeds the "under" picker and `labels` the
 * label datalist; both come from the Space being viewed.
 */
export function filterBar(
  action: string, q: ParsedQuery, containers: Array<{ node: Node; path: string }>, labels: string[], showSort: boolean,
): Html {
  const f = q.fields;
  const n = Object.keys(q.filter).filter((k) => k !== "includeArchived").length;
  return html`<details class="filters"${q.active ? raw(" open") : ""}>
<summary>Filters${n > 0 ? html` <span class="badge">${n}</span>` : ""}</summary>
<form method="get" action="${action}">
<p><label for="f-text">Search</label> <input type="search" name="text" id="f-text" value="${f.text}"></p>
<fieldset><legend>Status</legend>${checks("status", STATUSES, f.status)}<label><input type="checkbox" name="status" value="any"${f.anyStatus ? raw(" checked") : ""}> any</label></fieldset>
<fieldset><legend>Priority</legend><label for="f-pmin">at least</label> ${select("priorityMin", "f-pmin", PRIORITIES.filter((p) => p !== "none"), f.priorityMin, "any")} <span class="muted">or exactly</span> ${checks("priority", PRIORITIES, f.priority)}</fieldset>
<fieldset><legend>Kind</legend>${checks("kind", KINDS, f.kind)}</fieldset>
<p><label for="f-label">Labels</label> <input name="label" id="f-label" list="labels" value="${f.label}" placeholder="Repair, Inspection">
<datalist id="labels">${labels.map((l) => html`<option value="${l}">`)}</datalist>
<label for="f-under">Under</label> <select name="under" id="f-under"><option value="">anywhere</option>${containers.map((c) =>
    html`<option value="${c.node.id}"${f.under[0] === c.node.id ? raw(" selected") : ""}>${c.path}</option>`)}</select>${f.under.slice(1).map((u) => html`<input type="hidden" name="under" value="${u}">`)}</p>
<p><label for="f-age">Created in last</label> <input type="number" name="ageMax" id="f-age" min="0" value="${f.ageMax}" size="4"> days
<label for="f-stale">Stale for</label> <input type="number" name="stale" id="f-stale" min="0" value="${f.stale}" size="4"> days</p>
<p><label for="f-who">Who</label> <input name="who" id="f-who" value="${f.who}" placeholder="user id"> ${select("whoRole", "f-whorole", WHO_ROLES, f.whoRole, null)}
<label for="f-due">Due</label> ${select("due", "f-due", DUE, f.due, "any time")}</p>
<fieldset><legend>Has</legend>${checks("has", HAS, f.has)}</fieldset>
<p><label><input type="checkbox" name="archived" value="1"${f.archived ? raw(" checked") : ""}> include archived</label>
${showSort ? html`<label for="f-sort">Sort</label> ${select("sort", "f-sort", SORTS, q.sort, null)}` : ""}</p>
<p><button type="submit">Apply</button> <a href="${action}">Clear</a></p>
</form>
</details>`;
}
