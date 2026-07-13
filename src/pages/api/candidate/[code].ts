import type { APIRoute } from 'astro';
import { getCandidateByCode, getProgress, getNextQuestionIndex } from '../../../lib/db';
import { questions } from '../../../lib/prompt';

export const prerender = false;

// Lenient Crockford normalization: uppercase, and fold the ambiguous glyphs a human
// might type back to their canonical digits (O→0, I/L→1). Codes are generated from the
// unambiguous alphabet, so this only ever helps typos.
function normalize(code: string): string {
  return code
    .trim()
    .toUpperCase()
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1');
}

// Load a candidate by resume code with their per-question progress and the next question
// to run (first not-completed; null when the interview is finished).
export const GET: APIRoute = async ({ params }) => {
  const code = normalize(String(params.code ?? ''));
  if (!code) return json(400, { error: 'Missing resume code.' });

  const candidate = getCandidateByCode(code);
  if (!candidate) return json(404, { error: 'Codice non valido.' });

  const progress = getProgress(candidate.id);
  const nextQuestionIndex = getNextQuestionIndex(candidate.id);

  return json(200, {
    candidate: {
      id: candidate.id,
      displayName: candidate.display_name,
      resumeCode: candidate.resume_code,
    },
    progress: progress.map((p) => ({
      questionIndex: p.question_index,
      questionId: p.question_id,
      status: p.status,
      answerSummary: p.answer_summary,
    })),
    nextQuestionIndex,
    total: questions.questions.length,
    done: nextQuestionIndex == null,
  });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
