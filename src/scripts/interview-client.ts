// UI state machine for the one-question-per-session interview.
// Screens: start → code → interview → end-of-question → paused / done. Each question is
// its own short, timed provider session; the client owns the countdown, persists every
// normalized transcript entry, and drives the New/Resume + progress flow. It talks ONLY
// to the InterviewProvider interface, so HeyGen and Tavus stay interchangeable.
import type { InterviewProvider, ProviderName, TranscriptEntry } from '../providers/types';
import { HeyGenProvider } from '../providers/heygen';
import { TavusProvider } from '../providers/tavus';
import { beaconProctor, enterFullscreen, setAvatarSpeaking, setViolationCallback, startProctor, stopProctor, warmupCamera, INTEGRITY_LABELS } from './proctor';

type Phase = 'idle' | 'connecting' | 'live';
type Screen = 'start' | 'code' | 'rules' | 'interview' | 'endq' | 'paused' | 'done';
type EndedReason = 'completed' | 'timeout' | 'user_stop' | 'error';

interface Rates {
  heygenCreditsPerMin: number;
  heygenUsdPerCredit: number;
  tavusUsdPerMin: number;
}
interface ProgressEntry {
  questionIndex: number;
  questionId: string | null;
  status: string;
  answerSummary: string | null;
}
interface CandidateInfo {
  candidate: { id: number; displayName: string | null; resumeCode: string };
  progress: ProgressEntry[];
  nextQuestionIndex: number | null;
  total: number;
  done: boolean;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

// ── DOM ─────────────────────────────────────────────────────────────────────────
const app = document.getElementById('app') as HTMLElement;
const videoEl = document.getElementById('avatar-video') as HTMLVideoElement;
const button = document.getElementById('talk-button') as HTMLButtonElement;
const statusEl = document.getElementById('status') as HTMLElement;
const captionEl = document.getElementById('caption') as HTMLElement;
const consentEl = document.getElementById('consent') as HTMLInputElement;
const providerRadios = Array.from(
  document.querySelectorAll<HTMLInputElement>('input[name="provider"]'),
);
// Start screen
const displayNameInput = document.getElementById('display-name') as HTMLInputElement;
const resumeCodeInput = document.getElementById('resume-code') as HTMLInputElement;
const btnNew = document.getElementById('btn-new') as HTMLButtonElement;
const btnResume = document.getElementById('btn-resume') as HTMLButtonElement;
const startError = document.getElementById('start-error') as HTMLElement;
// Code screen
const codeValue = document.getElementById('code-value') as HTMLElement;
const btnBegin = document.getElementById('btn-begin') as HTMLButtonElement;
// Interview top bar
const progressEl = document.getElementById('progress') as HTMLElement;
const completedEl = document.getElementById('completed') as HTMLElement;
const timerEl = document.getElementById('timer') as HTMLElement;
// End-of-question
const endqTitle = document.getElementById('endq-title') as HTMLElement;
const endqHint = document.getElementById('endq-hint') as HTMLElement;
const btnNext = document.getElementById('btn-next') as HTMLButtonElement;
const btnPause = document.getElementById('btn-pause') as HTMLButtonElement;
// Paused / done
const pausedCode = document.getElementById('paused-code') as HTMLElement;
const btnHome = document.getElementById('btn-home') as HTMLButtonElement;
const btnHome2 = document.getElementById('btn-home-2') as HTMLButtonElement;
// Cost meter
const meterEl = document.getElementById('meter') as HTMLElement;
const meterCostEl = document.getElementById('meter-cost') as HTMLElement;
const meterCreditsEl = document.getElementById('meter-credits') as HTMLElement;
// Rules screen
const btnRulesOk = document.getElementById('btn-rules-ok') as HTMLButtonElement;
// Toast
const toastEl = document.getElementById('toast') as HTMLElement;
const toastMsgEl = document.getElementById('toast-msg') as HTMLElement;

// ── State ─────────────────────────────────────────────────────────────────────────
let provider: InterviewProvider | null = null;
let phase: Phase = 'idle';
let ending = true; // true whenever no live session owns teardown (guards stray stop events)
let providerName: ProviderName = 'heygen';

let candidateId = 0;
let resumeCode = '';
let total = 7;
let currentIndex = 0;
const completedSet = new Set<number>();

let sessionId: number | null = null;
let providerSessionId: string | undefined;
let lastEndedReason: EndedReason | null = null;
let rulesShown = false;
// Pre-session camera proximity check. null = unknown/pending, true = OK, false = too far.
let cameraOk: boolean | null = null;
let cameraCheckCleanup: (() => void) | null = null;
let pendingQuestionIndex = 0;
let toastTimer: number | null = null;
let rates: Rates = { heygenCreditsPerMin: 2, heygenUsdPerCredit: 0.1, tavusUsdPerMin: 0.37 };

// Timer
let timerLimit = 285;
let timerWarn = 60;
let timerDeadline = 0;
let timerInterval: number | null = null;
let nudged = false;

// Soft auto-advance: when the avatar concludes a question itself (Tavus end_interview tool),
// the end-of-question screen counts down and moves on automatically unless the candidate
// takes over with Pausa / Prossima.
const AUTO_ADVANCE_SECONDS = 3;
let autoAdvanceInterval: number | null = null;

// Client-side auto-retry for Tavus concurrency lag. The free-tier slot is released a few
// seconds after /end; the first start of the next question briefly races that window.
// We retry silently before falling back to a manual-retry prompt.
const CLIENT_BUSY_RETRIES = 3;
const CLIENT_BUSY_DELAY_MS = 3000;

// Cost meter
const CREDITS_REPOLL_MS = 60_000;
const CREDITS_LOW = 20;
const CREDITS_CRITICAL = 6;
let meterTimer: number | null = null;
let repollTimer: number | null = null;
let meterStartMs = 0;
let startCredits: number | null = null;

const STATUS: Record<string, [string, string]> = {
  idle: ['pronta a iniziare', 'idle'],
  connecting: ['connessione…', 'connecting'],
  ready: ['pronta', 'ready'],
  listening: ['in ascolto', 'listening'],
  speaking: ['sta parlando', 'speaking'],
  stopped: ['spenta', 'idle'],
  waiting: ['un attimo…', 'waiting'],
  error: ['errore', 'error'],
};

// ── Small helpers ─────────────────────────────────────────────────────────────────
function setScreen(name: Screen): void {
  app.dataset.screen = name;
}
function setStatus(kind: string, override?: string): void {
  const [text, state] = STATUS[kind] ?? STATUS.idle;
  statusEl.textContent = override ?? text;
  statusEl.dataset.state = state;
}
function selectedProvider(): ProviderName {
  return providerRadios.find((r) => r.checked)?.value === 'tavus' ? 'tavus' : 'heygen';
}
function makeProvider(name: ProviderName): InterviewProvider {
  return name === 'tavus' ? new TavusProvider() : new HeyGenProvider();
}
function mmss(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}
function setButton(): void {
  const live = phase === 'live';
  button.textContent = phase === 'connecting' ? '… connessione' : live ? '⏹ Stop' : '🎤 Parla';
  button.dataset.on = String(live);
  button.disabled = phase === 'connecting' || (phase === 'idle' && cameraOk === false);
}
function updateTopBar(): void {
  progressEl.textContent = `Domanda ${currentIndex + 1} di ${total}`;
  completedEl.textContent = `✓ ${completedSet.size}/${total}`;
}

// ── Timer ───────────────────────────────────────────────────────────────────────
function startTimer(): void {
  clearTimer();
  timerDeadline = Date.now() + timerLimit * 1000;
  nudged = false;
  renderTimer();
  timerInterval = window.setInterval(renderTimer, 500);
}
function renderTimer(): void {
  const remaining = Math.max(0, (timerDeadline - Date.now()) / 1000);
  timerEl.textContent = mmss(Math.ceil(remaining));
  timerEl.dataset.warn = remaining <= 15 ? 'critical' : remaining <= timerWarn ? 'warn' : 'normal';
  // Optional wrap-up nudge ~20s before zero (HeyGen only; Tavus has a server hard cap).
  if (!nudged && remaining <= 20 && remaining > 0 && providerName === 'heygen') {
    nudged = true;
    provider?.nudgeWrapUp?.();
  }
  if (remaining <= 0) void onTimeout();
}
function clearTimer(): void {
  if (timerInterval != null) window.clearInterval(timerInterval);
  timerInterval = null;
}
function resetTimerDisplay(): void {
  clearTimer();
  timerEl.textContent = '—:——';
  timerEl.dataset.warn = 'normal';
}

// ── Toast notifications ────────────────────────────────────────────────────────
// Types that warrant a visible in-interview warning (not looking_away — too frequent).
const TOAST_TYPES = new Set(['tab_hidden','focus_lost','fullscreen_exit','clipboard_copy','clipboard_paste','face_absent','multiple_faces','looking_down','too_far','phone_detected']);

function showToast(type: string, label: string): void {
  if (!TOAST_TYPES.has(type)) return;
  toastMsgEl.textContent = `⚠ ${label}`;
  toastEl.hidden = false;
  if (toastTimer != null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => { toastEl.hidden = true; }, 4000);
}

// ── Cost meter ─────────────────────────────────────────────────────────────────
async function fetchCredits(): Promise<number | null> {
  try {
    const res = await fetch('/api/credits');
    const data = await res.json().catch(() => null);
    return res.ok && typeof data?.credits_left === 'number' ? data.credits_left : null;
  } catch {
    return null;
  }
}
function elapsedMin(): number {
  return (Date.now() - meterStartMs) / 60_000;
}
function renderMeter(): void {
  const min = elapsedMin();
  let costUsd: number;
  if (providerName === 'heygen') {
    const consumed = min * rates.heygenCreditsPerMin;
    costUsd = consumed * rates.heygenUsdPerCredit;
    if (startCredits != null) {
      const remaining = Math.max(0, startCredits - consumed);
      meterCreditsEl.textContent = `${remaining.toFixed(1)} crediti`;
      meterCreditsEl.dataset.low =
        remaining <= CREDITS_CRITICAL ? 'critical' : remaining <= CREDITS_LOW ? 'true' : 'false';
    } else {
      meterCreditsEl.textContent = `−${consumed.toFixed(1)} crediti`;
      meterCreditsEl.dataset.low = 'false';
    }
    meterCreditsEl.hidden = false;
  } else {
    // Tavus: no balance API → estimate from elapsed minutes (30s minimum, round up to 6s).
    const billedMin = Math.max(0.5, Math.ceil(min * 600) / 600);
    costUsd = billedMin * rates.tavusUsdPerMin;
    meterCreditsEl.hidden = true;
  }
  meterCostEl.textContent = `${providerName === 'tavus' ? 'stima' : '≈'} $${costUsd.toFixed(2)}`;
}
async function anchorCredits(): Promise<void> {
  if (providerName !== 'heygen') return;
  const real = await fetchCredits();
  if (real == null) return;
  if (startCredits == null) {
    startCredits = real;
    meterStartMs = Date.now();
  } else {
    const est = startCredits - elapsedMin() * rates.heygenCreditsPerMin;
    if (real < est) {
      startCredits = real;
      meterStartMs = Date.now();
    }
  }
  renderMeter();
}
function startMeter(): void {
  meterStartMs = Date.now();
  startCredits = null;
  meterEl.removeAttribute('hidden');
  renderMeter();
  void anchorCredits();
  meterTimer = window.setInterval(renderMeter, 1000);
  repollTimer = window.setInterval(() => void anchorCredits(), CREDITS_REPOLL_MS);
}
function stopMeter(): void {
  if (meterTimer != null) window.clearInterval(meterTimer);
  if (repollTimer != null) window.clearInterval(repollTimer);
  meterTimer = null;
  repollTimer = null;
  startCredits = null;
  meterEl.setAttribute('hidden', '');
}

// ── Persistence ──────────────────────────────────────────────────────────────────
async function persist(entry: TranscriptEntry): Promise<void> {
  if (sessionId == null) return;
  try {
    await fetch('/api/interview/utterance', {
      method: 'POST',
      headers: JSON_HEADERS,
      body: JSON.stringify({ sessionId, ...entry }),
    });
  } catch {
    /* best-effort; HeyGen reconciles at end anyway */
  }
}
async function setProgress(index: number, status: string): Promise<void> {
  try {
    await fetch('/api/candidate/progress', {
      method: 'POST',
      headers: JSON_HEADERS,
      body: JSON.stringify({ candidateId, questionIndex: index, status }),
    });
  } catch {
    /* best-effort */
  }
}
async function fetchCandidate(code: string): Promise<CandidateInfo | null> {
  try {
    const res = await fetch(`/api/candidate/${encodeURIComponent(code)}`);
    if (!res.ok) return null;
    return (await res.json()) as CandidateInfo;
  } catch {
    return null;
  }
}

// ── Session lifecycle ─────────────────────────────────────────────────────────────
async function ensureMicPermission(): Promise<void> {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  stream.getTracks().forEach((t) => t.stop());
}

async function startSession(index: number): Promise<void> {
  if (phase !== 'idle') return;
  // Block only when the proximity check has explicitly found the face too far.
  // null means the check is still loading — we allow the session to proceed.
  if (cameraOk === false) {
    setStatus('waiting', 'Avvicinati alla webcam per iniziare');
    return;
  }
  // Hand the open camera stream off to the proctor; stop the pre-session warmup.
  cameraCheckCleanup?.();
  cameraCheckCleanup = null;
  cameraOk = null;

  currentIndex = index;
  phase = 'connecting';
  setButton();
  setStatus('connecting');
  updateTopBar();

  try {
    await ensureMicPermission();
  } catch {
    phase = 'idle';
    setButton();
    setStatus('error', 'permesso microfono negato');
    return;
  }

  try {
    // Retry loop for Tavus concurrency lag — the free-tier slot is released a few seconds
    // after /end and the server already retries internally, but sometimes that budget runs
    // out first. We retry silently on the client so the user never has to click again.
    let res!: Response;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let data: any = null;
    for (let busyAttempt = 0; ; busyAttempt++) {
      res = await fetch('/api/interview/start', {
        method: 'POST',
        headers: JSON_HEADERS,
        body: JSON.stringify({
          candidateId,
          questionIndex: index,
          provider: providerName,
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        }),
      });
      data = await res.json().catch(() => null);
      const busy = res.status === 429 || data?.code === 'provider_busy';
      if (!busy || busyAttempt >= CLIENT_BUSY_RETRIES) break;
      setStatus('waiting');
      await new Promise<void>((r) => setTimeout(r, CLIENT_BUSY_DELAY_MS));
      setStatus('connecting');
    }
    if (res.status === 429 || data?.code === 'provider_busy') {
      setStatus('waiting', data?.error ?? 'Attendi qualche secondo e premi di nuovo "Parla".');
      phase = 'idle';
      setButton();
      return;
    }
    if (!res.ok || !data?.dbSessionId) throw new Error(data?.error ?? `start HTTP ${res.status}`);

    sessionId = data.dbSessionId;
    providerSessionId = data.providerSessionId ?? undefined;
    if (data.pricing) rates = data.pricing;
    if (Number(data.timeLimitSeconds) > 0) timerLimit = Number(data.timeLimitSeconds);
    if (Number(data.warnSeconds) > 0) timerWarn = Number(data.warnSeconds);
    if (Number.isInteger(data.total)) total = data.total;
    updateTopBar();

    provider = makeProvider(providerName);
    ending = false;
    lastEndedReason = null;
    provider.on('transcript', (p) => {
      const entry = p as TranscriptEntry;
      captionEl.textContent = `${entry.role === 'avatar' ? 'Alessandra' : 'Tu'}: ${entry.text}`;
      void persist(entry);
    });
    provider.on('state', (s) => {
      const kind = String(s);
      setAvatarSpeaking(kind === 'speaking');
      if (kind === 'stopped') {
        if (!ending) void onProviderStopped();
        return;
      }
      if (kind === 'complete') {
        if (!ending) void onQuestionComplete();
        return;
      }
      setStatus(kind);
    });
    provider.on('error', (e) => {
      if (ending) return;
      setStatus('error', `errore: ${String(e)}`);
      void onProviderError();
    });

    const result = await provider.start(videoEl, {
      dbSessionId: sessionId!,
      providerSessionId,
      sessionToken: data.sessionToken,
      conversationUrl: data.conversationUrl,
    });
    providerSessionId = result.providerSessionId ?? providerSessionId;

    phase = 'live';
    setButton();
    startMeter();
    startTimer();
    startProctor(sessionId!); // soft, silent integrity collector (provider-agnostic)
  } catch (err) {
    setStatus('error', `errore: ${err instanceof Error ? err.message : String(err)}`);
    await teardown('error');
    phase = 'idle';
    setButton();
  }
}

// Ends the provider session, marks the DB row ended (reconciling HeyGen's transcript,
// freeing the Tavus slot, storing a raw answer summary). Does NOT change the screen —
// callers decide where to go next. `ending` guards against re-entrant stop events.
async function teardown(reason: EndedReason): Promise<void> {
  if (ending) return;
  ending = true;
  lastEndedReason = reason;
  clearTimer();
  stopMeter();
  cameraCheckCleanup?.(); // safety net: stop warmup if not already cleaned up
  cameraCheckCleanup = null;
  cameraOk = null;
  stopProctor(); // flush + release camera; captured its own sessionId at start

  const p = provider;
  const sid = sessionId;
  const psid = providerSessionId;
  const name = providerName;
  provider = null;
  sessionId = null;

  if (p) {
    try {
      await p.stop();
    } catch {
      /* already down */
    }
  }
  if (sid != null) {
    try {
      await fetch('/api/interview/end', {
        method: 'POST',
        headers: JSON_HEADERS,
        body: JSON.stringify({ sessionId: sid, provider: name, providerSessionId: psid, endedReason: reason }),
      });
    } catch {
      /* best-effort */
    }
  }
  phase = 'idle';
}

async function onTimeout(): Promise<void> {
  if (phase !== 'live') return;
  clearTimer();
  setStatus('error', 'tempo scaduto');
  await teardown('timeout');
  showEndq();
}
async function onProviderStopped(): Promise<void> {
  await teardown('user_stop');
  showEndq();
}
// The avatar concluded the question on its own (Tavus end_interview tool) → mark it done
// and let showEndq drive the soft auto-advance.
async function onQuestionComplete(): Promise<void> {
  if (ending) return;
  await teardown('completed');
  showEndq();
}
async function onProviderError(): Promise<void> {
  await teardown('error');
  showEndq();
}

// ── Screen flow ────────────────────────────────────────────────────────────────
function showRules(index: number): void {
  pendingQuestionIndex = index;
  setScreen('rules');
}

// autoStart=true makes the next question begin its session on its own, so a candidate
// mid-interview never has to press "Parla" again — the transition feels seamless. The very
// first question is left manual (autoStart=false): that first click is the user gesture that
// grants the mic and satisfies the browser's autoplay policy for the whole session.
function beginQuestion(index: number, autoStart = false): void {
  clearAutoAdvance();
  // Stop any previous proximity check before starting a fresh one.
  cameraCheckCleanup?.();
  cameraCheckCleanup = null;
  cameraOk = null;

  currentIndex = index;
  phase = 'idle';
  ending = true; // no live session yet
  provider = null;
  sessionId = null;
  captionEl.textContent = '';
  resetTimerDisplay();
  updateTopBar();
  setStatus('idle');
  setButton();
  setScreen('interview');

  // Start a background camera check: opens the webcam preview and continuously reports
  // whether the face is close enough. Blocks "Parla" with a status message if too far.
  // null = model still loading (allow); false = too far (block); true = OK (allow).
  cameraCheckCleanup = warmupCamera((ok) => {
    cameraOk = ok;
    if (phase !== 'idle') return; // session already started — ignore
    setButton();
    if (!ok) {
      setStatus('waiting', 'Avvicinati alla webcam per iniziare');
    } else {
      setStatus('idle');
    }
  });

  if (autoStart) void startSession(index);
}

function clearAutoAdvance(): void {
  if (autoAdvanceInterval != null) window.clearInterval(autoAdvanceInterval);
  autoAdvanceInterval = null;
}

function showEndq(): void {
  clearAutoAdvance();
  const timedOut = lastEndedReason === 'timeout';
  const completed = lastEndedReason === 'completed';
  const isLast = currentIndex >= total - 1;
  setScreen('endq');

  if (isLast) {
    btnPause.hidden = true;
    endqTitle.textContent = timedOut ? 'Tempo scaduto' : 'Colloquio terminato';
    btnNext.textContent = 'Vai ai risultati';

    // Avatar concluded the last question — auto-advance to done, no action needed.
    if (completed) {
      let remaining = AUTO_ADVANCE_SECONDS;
      endqHint.textContent = `Reindirizzamento ai risultati tra ${remaining}s…`;
      autoAdvanceInterval = window.setInterval(() => {
        remaining -= 1;
        if (remaining <= 0) {
          clearAutoAdvance();
          void onNext();
        } else {
          endqHint.textContent = `Reindirizzamento ai risultati tra ${remaining}s…`;
        }
      }, 1000);
      return;
    }

    endqHint.textContent = timedOut
      ? 'Il tempo è scaduto. Premi per completare il colloquio.'
      : 'Hai risposto a tutte le domande.';
    return;
  }

  btnPause.hidden = false;
  endqTitle.textContent = timedOut ? 'Tempo scaduto' : 'Domanda conclusa';
  btnNext.textContent = 'Prossima domanda';

  // Soft auto-advance: only when the avatar itself concluded (not a timeout or manual stop)
  // and more questions remain. The countdown auto-fires onNext; Pausa/Prossima take over.
  if (completed) {
    let remaining = AUTO_ADVANCE_SECONDS;
    endqHint.textContent = `Prossima domanda tra ${remaining}s…`;
    autoAdvanceInterval = window.setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        clearAutoAdvance();
        void onNext();
      } else {
        endqHint.textContent = `Prossima domanda tra ${remaining}s…`;
      }
    }, 1000);
    return;
  }

  endqHint.textContent = timedOut
    ? 'Il tempo per questa domanda è finito. Puoi continuare o riprendere più tardi.'
    : 'Vuoi continuare con la prossima domanda?';
}

async function onNext(): Promise<void> {
  clearAutoAdvance();
  btnNext.disabled = true;
  try {
    // Timeouts stay 'timeout' (retried on resume); only an affirmed, non-timed-out
    // question is marked completed.
    if (lastEndedReason !== 'timeout') {
      await setProgress(currentIndex, 'completed');
      completedSet.add(currentIndex);
    }
    const nextIndex = currentIndex + 1;
    if (nextIndex >= total) {
      // Linear pass done — the server knows if any timed-out questions still remain.
      const info = await fetchCandidate(resumeCode);
      completedSet.clear();
      info?.progress
        .filter((p) => p.status === 'completed')
        .forEach((p) => completedSet.add(p.questionIndex));
      if (!info || info.done || info.nextQuestionIndex == null) {
        setScreen('done');
        return;
      }
      beginQuestion(info.nextQuestionIndex, true);
    } else {
      beginQuestion(nextIndex, true);
    }
  } finally {
    btnNext.disabled = false;
  }
}

function onPause(): void {
  clearAutoAdvance();
  cameraCheckCleanup?.();
  cameraCheckCleanup = null;
  cameraOk = null;
  pausedCode.textContent = resumeCode;
  setScreen('paused');
}

// ── Start-screen handlers ────────────────────────────────────────────────────────
async function onNew(): Promise<void> {
  startError.textContent = '';
  if (!consentEl.checked) {
    startError.textContent = 'Devi accettare per continuare.';
    return;
  }
  providerName = selectedProvider();
  btnNew.disabled = true;
  try {
    const res = await fetch('/api/candidate', {
      method: 'POST',
      headers: JSON_HEADERS,
      body: JSON.stringify({ displayName: displayNameInput.value.trim() }),
    });
    const data = await res.json().catch(() => null);
    if (!res.ok || !data?.candidateId) throw new Error(data?.error || `HTTP ${res.status}`);
    candidateId = data.candidateId;
    resumeCode = data.resumeCode;
    if (Number.isInteger(data.total)) total = data.total;
    completedSet.clear();
    codeValue.textContent = resumeCode;
    setScreen('code');
  } catch (err) {
    startError.textContent = `Errore: ${err instanceof Error ? err.message : String(err)}`;
  } finally {
    btnNew.disabled = false;
  }
}

async function onResume(): Promise<void> {
  startError.textContent = '';
  if (!consentEl.checked) {
    startError.textContent = 'Devi accettare per continuare.';
    return;
  }
  providerName = selectedProvider();
  const code = resumeCodeInput.value.trim().toUpperCase();
  if (!code) {
    startError.textContent = 'Inserisci un codice.';
    return;
  }
  btnResume.disabled = true;
  try {
    const info = await fetchCandidate(code);
    if (!info) throw new Error('Codice non valido.');
    candidateId = info.candidate.id;
    resumeCode = info.candidate.resumeCode;
    total = info.total ?? total;
    completedSet.clear();
    info.progress
      .filter((p) => p.status === 'completed')
      .forEach((p) => completedSet.add(p.questionIndex));
    if (info.done || info.nextQuestionIndex == null) {
      setScreen('done');
      return;
    }
    showRules(info.nextQuestionIndex);
  } catch (err) {
    startError.textContent = `Errore: ${err instanceof Error ? err.message : String(err)}`;
  } finally {
    btnResume.disabled = false;
  }
}

function goHome(): void {
  cameraCheckCleanup?.();
  cameraCheckCleanup = null;
  cameraOk = null;
  displayNameInput.value = '';
  resumeCodeInput.value = '';
  startError.textContent = '';
  captionEl.textContent = '';
  setScreen('start');
}

// ── Wiring ───────────────────────────────────────────────────────────────────────
button.addEventListener('click', () => {
  if (phase === 'idle') void startSession(currentIndex);
  else if (phase === 'live') void teardown('user_stop').then(showEndq);
});
btnNew.addEventListener('click', () => void onNew());
btnResume.addEventListener('click', () => void onResume());
btnBegin.addEventListener('click', () => showRules(0));
btnRulesOk.addEventListener('click', () => {
  rulesShown = true;
  void enterFullscreen();
  beginQuestion(pendingQuestionIndex);
});
btnNext.addEventListener('click', () => void onNext());
btnPause.addEventListener('click', onPause);
btnHome.addEventListener('click', goHome);
btnHome2.addEventListener('click', goHome);

setViolationCallback(showToast);

// On tab/window close, end a live Tavus conversation server-side. A local provider.stop()
// only leaves the Daily room and may not transmit during unload, so the single Tavus slot
// (and its billing) would linger until max_call_duration. sendBeacon reliably delivers the
// end request to our own server, which then fires the Tavus REST /end and frees the slot at
// once. HeyGen is intentionally left untouched (no behavior change outside Tavus).
let unloadHandled = false;
function releaseOnUnload(): void {
  if (unloadHandled) return;
  unloadHandled = true;
  beaconProctor(); // ship any buffered integrity events before the page goes away
  if (providerName === 'tavus' && sessionId != null && !ending) {
    // endedReason 'user_stop' (not 'timeout') keeps the question 'pending' → retried on resume.
    const payload = JSON.stringify({
      sessionId,
      provider: 'tavus',
      providerSessionId,
      endedReason: 'user_stop',
    });
    navigator.sendBeacon('/api/interview/end', new Blob([payload], { type: 'application/json' }));
  }
  provider?.stop().catch(() => {});
}
// pagehide is the reliable unload signal (bfcache/mobile); beforeunload covers desktop close.
window.addEventListener('pagehide', releaseOnUnload);
window.addEventListener('beforeunload', releaseOnUnload);

// Initial UI.
setScreen('start');
setButton();
