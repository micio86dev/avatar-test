import type { APIRoute } from 'astro';
import { randomInt } from 'node:crypto';
import { createCandidate, seedProgress } from '../../../lib/db';
import { questions } from '../../../lib/prompt';

export const prerender = false;

// Crockford base32 (no I, L, O, U — unambiguous when read aloud or typed).
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const CODE_LEN = 6;

function makeCode(): string {
  let out = '';
  for (let i = 0; i < CODE_LEN; i++) out += ALPHABET[randomInt(0, ALPHABET.length)];
  return out;
}

function isUniqueViolation(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err != null &&
    'code' in err &&
    String((err as { code: unknown }).code).includes('SQLITE_CONSTRAINT')
  );
}

// Create a candidate + a short resume code, and seed one 'pending' progress row per
// question. The code lets the candidate stop between questions and resume later.
export const POST: APIRoute = async ({ request }) => {
  const body = (await request.json().catch(() => null)) as { displayName?: unknown } | null;
  const displayName =
    typeof body?.displayName === 'string' && body.displayName.trim()
      ? body.displayName.trim().slice(0, 120)
      : null;

  let candidateId: number | null = null;
  let resumeCode = '';
  for (let attempt = 0; attempt < 8 && candidateId == null; attempt++) {
    resumeCode = makeCode();
    try {
      candidateId = createCandidate(displayName, resumeCode);
    } catch (err) {
      if (isUniqueViolation(err)) continue; // rare code collision → try another
      return json(500, { error: 'Could not create candidate.' });
    }
  }
  if (candidateId == null) return json(500, { error: 'Could not allocate a resume code.' });

  seedProgress(candidateId, questions.questions);

  return json(200, {
    candidateId,
    resumeCode,
    total: questions.questions.length,
    nextQuestionIndex: 0,
  });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
