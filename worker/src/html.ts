/**
 * The smallest HTML layer that is safe: a tagged template that escapes every
 * interpolated value unless it is already a rendered fragment. No framework,
 * no bundler; pages are template literals (DESIGN.md §7a).
 */

export class Html {
  constructor(readonly text: string) {}
  toString(): string {
    return this.text;
  }
}

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escape for text and for double-quoted attribute values. */
export function escape(value: unknown): string {
  return String(value).replace(/[&<>"']/g, (c) => ESCAPES[c]!);
}

/** Mark a string as already-safe HTML. Only for literals you wrote yourself. */
export const raw = (text: string): Html => new Html(text);

function render(value: unknown): string {
  if (value instanceof Html) return value.text;
  if (Array.isArray(value)) return value.map(render).join("");
  if (value === null || value === undefined || value === false) return "";
  return escape(value);
}

/** html`<p>${userText}</p>`: strings are escaped, Html fragments and arrays of them pass through. */
export function html(strings: TemplateStringsArray, ...values: unknown[]): Html {
  let out = strings[0] ?? "";
  for (let i = 0; i < values.length; i++) out += render(values[i]) + (strings[i + 1] ?? "");
  return new Html(out);
}

export interface Crumb {
  href: string;
  label: string;
}

export interface LayoutOptions {
  title: string;
  /** Links shown in the header after the site name; the last one is the current page. */
  crumbs?: Crumb[];
  user?: { displayName: string } | null;
}

/**
 * Shared shell: manifest, theme colours, the house stylesheet, landmarks, and
 * the service-worker registration behind a feature check. Every page uses it.
 */
export function layout(opts: LayoutOptions, body: Html): string {
  const crumbs = (opts.crumbs ?? []).map((c, i, all) =>
    i === all.length - 1
      ? html`<span aria-current="page">${c.label}</span>`
      : html`<a href="${c.href}">${c.label}</a>`);
  return `<!doctype html>\n` + html`<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${opts.title} · Property Tasks</title>
<link rel="manifest" href="/manifest.webmanifest">
<meta name="theme-color" content="#0b0d10" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#e2e8f0" media="(prefers-color-scheme: light)">
<link rel="stylesheet" href="/app.css">
</head>
<body>
<header>
<nav aria-label="Breadcrumb" class="crumbs"><a href="/">Property Tasks</a>${crumbs.map((c) => html` › ${c}`)}</nav>
</header>
<main>
${body}
</main>
<footer class="muted">${opts.user ? html`Signed in as ${opts.user.displayName}` : "Not signed in"}</footer>
<script>if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js");</script>
</body>
</html>
`.text;
}

export function page(opts: LayoutOptions, body: Html, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(layout(opts, body), {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "private, no-cache", ...headers },
  });
}

export function redirect(location: string): Response {
  return new Response(null, { status: 303, headers: { location } });
}

const MINUTE = 60_000, HOUR = 3_600_000, DAY = 86_400_000;

/** "3h ago" style, with the exact instant in the datetime attribute and title. */
export function relativeTime(at: number, now: number): Html {
  const d = now - at;
  const text = d < MINUTE ? "just now"
    : d < HOUR ? `${Math.floor(d / MINUTE)}m ago`
    : d < DAY ? `${Math.floor(d / HOUR)}h ago`
    : d < 30 * DAY ? `${Math.floor(d / DAY)}d ago`
    : d < 365 * DAY ? `${Math.floor(d / (30 * DAY))}mo ago`
    : `${Math.floor(d / (365 * DAY))}y ago`;
  const iso = new Date(at).toISOString();
  return html`<time datetime="${iso}" title="${iso.slice(0, 16).replace("T", " ")}Z">${text}</time>`;
}
