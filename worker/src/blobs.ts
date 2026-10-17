import type { User } from "./auth.js";

const SHA_RE = /^[0-9a-f]{64}$/;
const VARIANTS = new Set(["thumb", "phone"]);

export function blobKey(spaceId: string, sha256: string, variant: string | null): string {
  return variant ? `spaces/${spaceId}/${sha256}/${variant}` : `spaces/${spaceId}/${sha256}`;
}

export function validBlobPath(sha256: string, variant: string | null): boolean {
  return SHA_RE.test(sha256) && (variant === null || VARIANTS.has(variant));
}

/**
 * Upload through the Worker. The original is verified by R2 against the
 * sha256 in the path; derivatives (thumb, phone) are produced on the client
 * from the original and are not independently verified. See DESIGN.md §11.
 */
export async function putBlob(request: Request, env: Env, spaceId: string, sha256: string, variant: string | null, user: User): Promise<Response> {
  if (!request.body) return Response.json({ error: "empty body" }, { status: 400 });
  const key = blobKey(spaceId, sha256, variant);
  const contentType = request.headers.get("content-type") ?? "application/octet-stream";
  try {
    const obj = await env.BLOBS.put(key, request.body, {
      ...(variant === null ? { sha256 } : {}),
      httpMetadata: { contentType },
      customMetadata: { uploadedBy: user.id },
    });
    if (!obj) return Response.json({ error: "upload failed" }, { status: 500 });
    return Response.json({ key, size: obj.size }, { status: 201 });
  } catch (e) {
    const msg = String(e);
    if (/sha256|checksum|integrity/i.test(msg)) return Response.json({ error: "sha256 mismatch" }, { status: 400 });
    throw e;
  }
}

export async function getBlob(env: Env, spaceId: string, sha256: string, variant: string | null): Promise<Response> {
  const obj = await env.BLOBS.get(blobKey(spaceId, sha256, variant));
  if (!obj) return Response.json({ error: "not found" }, { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("content-length", String(obj.size));
  // Content-addressed: the bytes behind this URL never change.
  headers.set("cache-control", "private, max-age=31536000, immutable");
  return new Response(obj.body, { headers });
}
