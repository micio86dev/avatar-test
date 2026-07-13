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
