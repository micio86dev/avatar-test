// Provider-agnostic contract. The UI and the persistence layer talk ONLY to this
// interface, so HeyGen and Tavus are interchangeable behind it.

// Every utterance (mine + the avatar's) is normalized to this shape before it is
// emitted on 'transcript' and persisted.
export interface TranscriptEntry {
  role: 'user' | 'avatar';
  text: string;
  ts: number;
  seq?: number;
}

export type ProviderName = 'heygen' | 'tavus';

// UI-facing connection state. Providers map their own lifecycle onto these.
export type ProviderState =
  | 'connecting'
  | 'ready'
  | 'listening'
  | 'speaking'
  | 'stopped'
  // The avatar signalled it is done with the current question (Tavus: via the
  // end_interview tool call). Drives the client's soft auto-advance.
  | 'complete';

export type ProviderEvent = 'transcript' | 'state' | 'error';

// HeyGen FULL mode has no tool-calling, so the avatar signals "question done" by SPEAKING
// a fixed closing phrase: the server appends an instruction to say it verbatim, and the
// client detects it in the avatar transcript to emit 'complete' (Tavus uses the silent
// end_interview tool instead). Shared here so both sides stay in sync.
export const HEYGEN_END_PHRASE = 'Passiamo alla prossima domanda.';

// On the LAST question there is no next question, so the avatar closes with a thank-you
// instead. This is a DISTINCT completion signal for HeyGen (see start.ts): the client must
// recognize it too, otherwise it would wait forever for HEYGEN_END_PHRASE. Kept short so
// the substring match in matchesEndPhrase stays robust to TTS/transcription variance.
export const HEYGEN_FINAL_PHRASE = 'Grazie per il tuo tempo.';

function normalizePhrase(s: string): string {
  return (
    s
      .toLowerCase()
      .normalize('NFD')
      // NFD splits accents into combining marks; [^a-z0-9 ] then drops them and punctuation.
      .replace(/[^a-z0-9 ]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
  );
}

// Accent/case/punctuation-insensitive containment check, so minor TTS/transcription
// variance in the spoken closing phrase still matches. Matches EITHER the between-questions
// transition phrase OR the final thank-you phrase — both mean "this question is done".
export function matchesEndPhrase(text: string): boolean {
  const norm = normalizePhrase(text);
  return norm.includes(normalizePhrase(HEYGEN_END_PHRASE)) || norm.includes(normalizePhrase(HEYGEN_FINAL_PHRASE));
}

// Whatever the /api/interview/start endpoint returned for this provider, plus the DB
// session id. Kept loose because each provider needs different connection fields
// (HeyGen: sessionToken; Tavus: conversationUrl).
export interface StartConfig {
  dbSessionId: number;
  providerSessionId?: string;
  sessionToken?: string; // heygen
  conversationUrl?: string; // tavus
  [k: string]: unknown;
}

export interface StartResult {
  providerSessionId?: string;
}

export interface InterviewProvider {
  start(mountEl: HTMLElement, cfg: StartConfig): Promise<StartResult>;
  toggleMic(): Promise<void>; // start/stop (mute/unmute) voice chat
  stop(): Promise<void>;
  on(evt: ProviderEvent, cb: (payload: unknown) => void): void;
  // Optional: ~20s before the timer expires, nudge the avatar to wrap the question up
  // (HeyGen only — via session.message()). Tavus relies on its server-side hard cap.
  nudgeWrapUp?(): void;
}
