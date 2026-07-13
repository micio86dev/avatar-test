import type { APIRoute } from 'astro';
import { insertIntegrityEvents } from '../../../lib/db';
import { INTEGRITY_TYPES, type IntegrityEventInput, type IntegrityType } from '../../../lib/proctor-config';

export const prerender = false;

// Cap a single flush so a misbehaving/hostile client can't blow up the table in one call.
const MAX_EVENTS_PER_FLUSH = 500;

// Receives a batch of soft-proctoring integrity events from the client collector. Accepts
// both a normal fetch (JSON) and a navigator.sendBeacon Blob — both arrive as
// application/json, so request.json() covers them. Silently drops unknown event types.
export const POST: APIRoute = async ({ request }) => {
  const body = (await request.json().catch(() => null)) as
    | { sessionId?: unknown; events?: unknown }
    | null;

  const sessionId = Number(body?.sessionId);
  if (!Number.isInteger(sessionId)) return json(400, { error: 'Invalid sessionId.' });

  const raw = Array.isArray(body?.events) ? body!.events : [];
  const events: IntegrityEventInput[] = [];
  for (const item of raw) {
    const e = item as { type?: unknown; ts?: unknown; meta?: unknown };
    if (!INTEGRITY_TYPES.includes(e.type as IntegrityType)) continue;
    events.push({
      type: e.type as IntegrityType,
      ts: typeof e.ts === 'string' ? e.ts : new Date().toISOString(),
      meta: e.meta && typeof e.meta === 'object' ? (e.meta as Record<string, unknown>) : null,
    });
    if (events.length >= MAX_EVENTS_PER_FLUSH) break;
  }

  if (events.length) insertIntegrityEvents(sessionId, events);
  return json(200, { ok: true, stored: events.length });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
