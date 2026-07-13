// HeyGen LiveAvatar provider (FULL mode: HeyGen does ASR + LLM + TTS).
// Verified against @heygen/liveavatar-web-sdk v0.0.18 type defs:
//  - transcript-carrying events are AgentEventsEnum.USER_TRANSCRIPTION / AVATAR_TRANSCRIPTION,
//    each payload { text: string } (the *_STARTED/_ENDED events carry NO text).
//  - mic is muted/unmuted via session.voiceChat.mute()/unmute().
import {
  LiveAvatarSession,
  SessionEvent,
  SessionState,
  SessionDisconnectReason,
  AgentEventsEnum,
  SessionInteractivityMode,
} from '@heygen/liveavatar-web-sdk';
import {
  matchesEndPhrase,
  type InterviewProvider,
  type ProviderEvent,
  type StartConfig,
  type StartResult,
  type TranscriptEntry,
} from './types';

type Handler = (payload: unknown) => void;

export class HeyGenProvider implements InterviewProvider {
  private session: LiveAvatarSession | null = null;
  private avatarSpeaking = false;
  // Set when the avatar's transcript contains the closing phrase while it is still
  // speaking; the actual 'complete' is emitted on AVATAR_SPEAK_ENDED so the sentence
  // finishes before the question tears down.
  private pendingComplete = false;
  private handlers: Record<ProviderEvent, Handler[]> = { transcript: [], state: [], error: [] };

  on(evt: ProviderEvent, cb: Handler): void {
    this.handlers[evt].push(cb);
  }

  private emit(evt: ProviderEvent, payload: unknown): void {
    for (const cb of this.handlers[evt]) cb(payload);
  }

  private transcript(role: TranscriptEntry['role'], text: string): void {
    const t = text?.trim();
    if (!t) return;
    this.emit('transcript', { role, text: t, ts: Date.now() } satisfies TranscriptEntry);
  }

  async start(mountEl: HTMLElement, cfg: StartConfig): Promise<StartResult> {
    const token = cfg.sessionToken;
    if (!token) throw new Error('HeyGen: missing sessionToken');

    const session = new LiveAvatarSession(token, {
      // CONVERSATIONAL = hands-free VAD turn-taking (not push-to-talk).
      voiceChat: { mode: SessionInteractivityMode.CONVERSATIONAL, defaultMuted: false },
    });
    this.session = session;

    session.on(SessionEvent.SESSION_STATE_CHANGED, (state) => {
      if (state === SessionState.CONNECTING) this.emit('state', 'connecting');
      if (state === SessionState.CONNECTED) this.emit('state', 'ready');
    });

    // Stream ready → attach video + audio to the <video> element.
    session.on(SessionEvent.SESSION_STREAM_READY, () => {
      const el = mountEl as HTMLMediaElement;
      session.attach(el);
      void (el as HTMLVideoElement).play?.().catch(() => {});
      this.emit('state', 'ready');
    });

    session.on(SessionEvent.SESSION_DISCONNECTED, (reason) => {
      this.session = null;
      this.avatarSpeaking = false;
      if (reason === SessionDisconnectReason.CLIENT_INITIATED) this.emit('state', 'stopped');
      else this.emit('error', 'disconnected');
    });

    // Turn-taking + barge-in (priority #1: cut her off the moment the user speaks).
    session.on(AgentEventsEnum.USER_SPEAK_STARTED, () => {
      this.emit('state', 'listening');
      if (this.avatarSpeaking) {
        try {
          session.interrupt();
        } catch {
          /* server VAD also handles barge-in in CONVERSATIONAL mode */
        }
        this.avatarSpeaking = false;
      }
    });
    session.on(AgentEventsEnum.AVATAR_SPEAK_STARTED, () => {
      this.avatarSpeaking = true;
      this.emit('state', 'speaking');
    });
    session.on(AgentEventsEnum.AVATAR_SPEAK_ENDED, () => {
      this.avatarSpeaking = false;
      this.emit('state', 'ready');
      // The closing phrase has now been fully spoken → signal the question is done.
      if (this.pendingComplete) {
        this.pendingComplete = false;
        this.emit('state', 'complete');
      }
    });

    // The transcript-carrying events (final text). Chunk variants are ignored here to
    // avoid duplicate partials in the DB.
    session.on(AgentEventsEnum.USER_TRANSCRIPTION, (e) => this.transcript('user', e.text));
    session.on(AgentEventsEnum.AVATAR_TRANSCRIPTION, (e) => {
      this.transcript('avatar', e.text);
      // No tool-calling in FULL mode: the avatar marks a question done by SPEAKING the
      // fixed closing phrase. Defer 'complete' to AVATAR_SPEAK_ENDED if still talking.
      if (matchesEndPhrase(e.text)) {
        if (this.avatarSpeaking) this.pendingComplete = true;
        else this.emit('state', 'complete');
      }
    });

    session.on(AgentEventsEnum.SESSION_STOPPED, () => {
      this.session = null;
      this.avatarSpeaking = false;
      this.emit('state', 'stopped');
    });

    await session.start(); // connects LiveKit + auto-starts the mic
    return { providerSessionId: session.sessionId ?? cfg.providerSessionId };
  }

  // Nudge her LLM to wrap the current question up, in FULL mode. `message()` injects an
  // instruction the LLM answers (a natural closing line), unlike `repeat()` which would
  // speak verbatim. Best-effort — the client hard-stops at zero regardless.
  nudgeWrapUp(): void {
    try {
      this.session?.message('Concludi ora questa domanda: fai una breve frase di chiusura e fermati.');
    } catch {
      /* session already tearing down → the hard-stop timer covers it */
    }
  }

  // Mute/unmute the always-on conversational mic. The primary UI button uses start/stop;
  // this is the interface's mic toggle, wired to the real VoiceChat API.
  async toggleMic(): Promise<void> {
    const vc = this.session?.voiceChat;
    if (!vc) return;
    if (vc.isMuted) await vc.unmute();
    else await vc.mute();
  }

  async stop(): Promise<void> {
    const s = this.session;
    this.session = null;
    if (s) {
      try {
        await s.stop();
      } catch {
        /* already torn down */
      }
    }
  }
}
