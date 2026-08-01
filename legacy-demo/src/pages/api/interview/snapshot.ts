import type { APIRoute } from 'astro';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { insertSnapshot } from '../../../lib/db';

export const prerender = false;

const SNAPSHOTS_DIR = process.env.SNAPSHOTS_PATH
  ? resolve(process.env.SNAPSHOTS_PATH)
  : resolve(process.cwd(), 'data', 'snapshots');

export const POST: APIRoute = async ({ request }) => {
  const body = (await request.json().catch(() => null)) as
    | { sessionId?: unknown; image?: unknown; ts?: unknown; trigger?: unknown }
    | null;

  const sessionId = Number(body?.sessionId);
  if (!Number.isInteger(sessionId)) return json(400, { error: 'Invalid sessionId.' });

  const image = typeof body?.image === 'string' ? body.image : null;
  if (!image || !image.startsWith('data:image/jpeg;base64,')) return json(400, { error: 'Invalid image.' });

  const ts = typeof body?.ts === 'string' ? body.ts : new Date().toISOString();
  const trigger = typeof body?.trigger === 'string' ? body.trigger : null;

  // Include trigger slug in filename so event-triggered snapshots are identifiable on disk.
  const safeName = ts.replace(/[:.]/g, '-') + (trigger ? `_${trigger}` : '') + '.jpg';
  const dir = resolve(SNAPSHOTS_DIR, String(sessionId));
  const filePath = resolve(dir, safeName);
  const relativePath = `snapshots/${sessionId}/${safeName}`;

  try {
    mkdirSync(dir, { recursive: true });
    const base64Data = image.slice('data:image/jpeg;base64,'.length);
    writeFileSync(filePath, Buffer.from(base64Data, 'base64'));
    insertSnapshot(sessionId, relativePath, ts, trigger);
  } catch {
    return json(500, { error: 'Failed to save snapshot.' });
  }

  return json(200, { ok: true, path: relativePath });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
