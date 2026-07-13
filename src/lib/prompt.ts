// Loads the interview script (questions.json at the repo root) and composes the Italian
// interviewer context injected into each provider's own LLM. The interview runs as a
// SEQUENCE of single-question sessions, so we compose ONE question at a time (with a
// recap of prior answers for continuity) rather than the whole list.
// Only the avatar's spoken content and the questions are Italian; everything else
// (code, identifiers, comments) stays English.
import raw from '../../questions.json';

export interface Question {
  id: string;
  text: string;
  objective: string;
}

export interface Questions {
  language: string;
  version: string;
  title: string;
  totalQuestions: number;
  intro: string;
  resumeGreeting: string;
  closing: string;
  instructions: string;
  questions: Question[];
}

export const questions = raw as Questions;

// One already-answered prior question, condensed for the recap.
export interface PriorAnswer {
  label: string; // the prior question's text, for context
  text: string; // the (raw-derived) answer summary
}

export interface QuestionPromptParams {
  index: number; // 0-based index of the current question
  isFirst: boolean; // first question of the whole interview? → intro vs resume greeting
  priorAnswers: PriorAnswer[];
  timeLimitSeconds: number;
}

function mmss(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${String(r).padStart(2, '0')}`;
}

// Compose the Italian context for a SINGLE question session. Only the current question
// is ever in scope; prior answers are summarized so the avatar keeps continuity without
// re-asking. Returns the system prompt (injected as the provider context) and the spoken
// greeting (opening line).
export function composeQuestionPrompt(params: QuestionPromptParams): {
  systemPrompt: string;
  greeting: string;
} {
  const { index, isFirst, priorAnswers, timeLimitSeconds } = params;
  const q = questions.questions[index];
  if (!q) throw new Error(`No question at index ${index}.`);

  // The opening line is spoken VERBATIM by the provider (Tavus custom_greeting /
  // HeyGen opening_text), so we bake the actual question into it. This guarantees the
  // avatar ASKS the question immediately instead of greeting and stalling for a
  // readiness cue — the old greeting ended with "Iniziamo?" and the avatar waited.
  const greetingBase = isFirst ? questions.intro : questions.resumeGreeting;
  const greeting = `${greetingBase} ${q.text}`;

  const lines: string[] = [questions.instructions, ''];

  if (priorAnswers.length) {
    lines.push("L'utente ha gia' fornito:");
    for (const a of priorAnswers) lines.push(`- ${a.label}: ${a.text}`);
    lines.push('Non richiedere di nuovo queste informazioni.', '');
  }

  lines.push(
    `Hai gia' posto questa domanda nella frase di apertura: "${q.text}"`,
    "NON ripetere la domanda e NON chiedere se l'utente e' pronto: attendi la sua risposta.",
    `Obiettivo da raccogliere: ${q.objective}`,
    "Fai follow-up mirati finche' non hai raccolto l'obiettivo. Massimo 2-3 follow-up. " +
      'Poi chiudi con una breve frase di conclusione per questa domanda e fermati.',
    '',
    `Hai pochi minuti (${mmss(timeLimitSeconds)}), vai al punto e non divagare.`,
  );

  return { systemPrompt: lines.join('\n'), greeting };
}
