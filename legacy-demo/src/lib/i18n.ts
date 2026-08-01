// Internationalisation — single source of truth for UI strings.
// Add a new locale by extending the `Locale` union and adding its entry to `locales`.
// Currently only Italian is shipped; the structure is in place for future additions.

export type Locale = 'it';
export const DEFAULT_LOCALE: Locale = 'it';

const it = {
  // ── Navigation ────────────────────────────────────────────────────────────
  'nav.back_home': '← Home',
  'nav.back_archive': '← Archivio',

  // ── Admin list ────────────────────────────────────────────────────────────
  'admin.list.title': 'Archivio Interviste',
  'admin.list.empty': 'Nessuna intervista registrata.',
  'admin.list.col.candidate': 'Candidato',
  'admin.list.col.code': 'Codice',
  'admin.list.col.progress': 'Progresso',
  'admin.list.col.provider': 'Provider',
  'admin.list.col.cost': 'Costo (stimato)',
  'admin.list.col.last_activity': 'Ultima attività',
  'admin.list.action.detail': 'Dettaglio →',

  // ── Admin detail ──────────────────────────────────────────────────────────
  'admin.detail.unnamed': 'Candidato senza nome',
  'admin.detail.stat.questions': 'Domande',
  'admin.detail.stat.total_duration': 'Durata totale',
  'admin.detail.stat.total_cost': 'Costo totale',
  'admin.detail.stat.integrity': 'Segnali integrità',
  'admin.detail.stat.registered': 'Registrato',

  // ── Progress status ───────────────────────────────────────────────────────
  'status.pending': 'In attesa',
  'status.completed': 'Completata',
  'status.timeout': 'Timeout',
  'status.skipped': 'Saltata',

  // ── Session meta bar ──────────────────────────────────────────────────────
  'session.started': 'Iniziata',
  'session.ended': 'Terminata',
  'session.id_prefix': 'Sessione #',
  'session.estimated': 'stimato',
  'session.actual_duration': 'effettivo',
  'session.credits': 'crediti',
  'session.min': 'min',
  'session.no_session': 'Nessuna sessione avviata per questa domanda.',

  // ── Provider data block ───────────────────────────────────────────────────
  'provider.updated': 'aggiornato',
  'provider.refresh': '↻ Aggiorna dati',
  'provider.load': '↻ Carica dati provider',
  'provider.loading': 'Caricamento…',
  'provider.no_data': 'Dati provider non ancora disponibili.',
  'provider.no_data_hint': 'Usa "Carica dati provider" per recuperarli.',

  // Tavus
  'provider.tavus.title': 'Dati Tavus',
  'provider.tavus.perception_label': 'Analisi visuale AI (Tavus Raven)',
  'provider.tavus.recording': 'Registrazione',
  'provider.tavus.transcript': 'Trascrizione Tavus con timing',

  // HeyGen
  'provider.heygen.title': 'Dati HeyGen (effettivi)',
  'provider.heygen.credits': 'Crediti consumati',
  'provider.heygen.duration': 'Durata effettiva',
  'provider.heygen.cost': 'Costo effettivo',
  'provider.heygen.end_reason': 'Fine sessione',
  'provider.heygen.mode': 'Modalità',

  // ── Integrity ─────────────────────────────────────────────────────────────
  'integrity.title': 'Integrità',
  'integrity.risk': 'rischio',
  'integrity.band.low': 'basso',
  'integrity.band.medium': 'medio',
  'integrity.band.high': 'alto',
  'integrity.clean': '✓ Nessun segnale di integrità registrato',

  // ── Answer summary ────────────────────────────────────────────────────────
  'answer.summary.title': 'Sintesi risposta',

  // ── Snapshots ─────────────────────────────────────────────────────────────
  'snapshots.title': 'Snapshot webcam',
  'snapshots.legend.event': 'su evento',
  'snapshots.legend.periodic': 'periodico',

  // ── Transcript ────────────────────────────────────────────────────────────
  'transcript.title': 'Trascrizione',
  'transcript.turns': 'turni',
  'transcript.empty': 'Nessuna trascrizione disponibile.',

  // ── Speakers ─────────────────────────────────────────────────────────────
  'speaker.avatar': 'Alessandra',
  'speaker.candidate': 'Candidato',

  // ── Fallback for missing dates ────────────────────────────────────────────
  'time.unknown': '—',
} as const;

// Derive the key union from the `it` object so adding/removing keys is automatically reflected.
export type I18nKey = keyof typeof it;

const locales: Record<Locale, Record<string, string>> = { it };

export function t(key: I18nKey, locale: Locale = DEFAULT_LOCALE): string {
  return locales[locale][key] ?? key;
}

// ── Date/time helpers ─────────────────────────────────────────────────────────
// All timestamps are stored as UTC ISO-8601; these helpers convert to the target
// timezone for display. Passing `null` timezone falls back to the runtime's local TZ
// (usually UTC in a server environment — prefer always passing a known TZ).

export function formatDateTime(
  iso: string | null | undefined,
  timezone?: string | null,
  locale: Locale = DEFAULT_LOCALE,
): string {
  if (!iso) return t('time.unknown', locale);
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('it-IT', {
    timeZone: timezone ?? undefined,
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function formatTime(
  iso: string | null | undefined,
  timezone?: string | null,
  locale: Locale = DEFAULT_LOCALE,
): string {
  if (!iso) return t('time.unknown', locale);
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleTimeString('it-IT', { timeZone: timezone ?? undefined });
}
