import type { APIRoute } from 'astro';
import { insertUtterance, type Role } from '../../../lib/db';

export const prerender = false;

// One normalized utterance (mine or the avatar's) → one row. Called live during the
// conversation by the client for both providers.
export const POST: APIRoute = async ({ request }) => {
  const body = (await request.json().catch(() => null)) as
    | { sessionId?: unknown; role?: unknown; text?: unknown; ts?: unknown; seq?: unknown }
    | null;

  const sessionId = Number(body?.sessionId);
  const role = body?.role;
  const text = typeof body?.text === 'string' ? body.text.trim() : '';

  if (!Number.isInteger(sessionId) || (role !== 'user' && role !== 'avatar') || !text) {
    return json(400, { error: 'Invalid utterance payload.' });
  }

  const seq = Number.isFinite(Number(body?.seq)) ? Number(body?.seq) : null;
  const createdAt = Number.isFinite(Number(body?.ts))
    ? new Date(Number(body?.ts)).toISOString()
    : undefined;

  try {
    insertUtterance(sessionId, { role: role as Role, text, seq, createdAt });
  } catch (err) {
    return json(500, { error: err instanceof Error ? err.message : String(err) });
  }
  return json(200, { ok: true });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
}
