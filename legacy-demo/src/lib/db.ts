// Local SQLite persistence for interviews.
// A single better-sqlite3 connection is opened lazily on first use and reused for the
// lifetime of the Node process (the app runs under @astrojs/node standalone locally).
// The schema is created — and migrated — on boot. DB file lives at ./data/interviews.db.
import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import {
  summarizeIntegrity,
  type IntegrityEventInput,
  type IntegritySummary,
} from './proctor-config';

export type { IntegrityEventInput, IntegritySummary } from './proctor-config';

export type Role = 'user' | 'avatar';
export type ProgressStatus = 'pending' | 'completed' | 'timeout' | 'skipped';
export type EndedReason = 'completed' | 'timeout' | 'user_stop' | 'error';

export interface SessionRow {
  id: number;
  provider: string;
  provider_session_id: string | null;
  questions_version: string | null;
  candidate_id: number | null;
  question_id: string | null;
  question_index: number | null;
  ended_reason: string | null;
  started_at: string;
  ended_at: string | null;
  timezone: string | null; // IANA timezone from the user's browser (e.g. "Europe/Rome")
  provider_meta: string | null; // JSON blob of post-session data fetched from provider API
}

export interface UtteranceRow {
  id: number;
  session_id: number;
  role: Role;
  text: string;
  seq: number | null;
  created_at: string;
}

export interface UtteranceInput {
  role: Role;
  text: string;
  seq?: number | null;
  createdAt?: string;
}

export interface CandidateRow {
  id: number;
  display_name: string | null;
  resume_code: string;
  created_at: string;
}

export interface ProgressRow {
  id: number;
  candidate_id: number;
  question_id: string | null;
  question_index: number;
  status: ProgressStatus;
  session_id: number | null;
  answer_summary: string | null;
  updated_at: string;
}

export interface SessionMeta {
  candidateId?: number;
  questionId?: string;
  questionIndex?: number;
  timezone?: string;
}

export interface IntegrityEventRow {
  id: number;
  session_id: number;
  type: string;
  meta: string | null; // JSON string
  ts: string;
  created_at: string;
}

// DB file location. Defaults to ./data/interviews.db for local dev. In deployed
// environments where the working directory is ephemeral (e.g. a Railway service),
// set DATABASE_PATH to a file on a mounted persistent volume so data survives restarts.
const DB_PATH = process.env.DATABASE_PATH
  ? resolve(process.env.DATABASE_PATH)
  : resolve(process.cwd(), 'data', 'interviews.db');

let db: Database.Database | null = null;

// Idempotent column add — SQLite has no `ADD COLUMN IF NOT EXISTS`, so guard on
// PRAGMA table_info. (Table/column names here are internal constants, not user input.)
function ensureColumn(conn: Database.Database, table: string, column: string, ddl: string): void {
  const cols = conn.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[];
  if (!cols.some((c) => c.name === column)) {
    conn.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
  }
}

function getDb(): Database.Database {
  if (db) return db;
  mkdirSync(dirname(DB_PATH), { recursive: true });
  const conn = new Database(DB_PATH);
  conn.pragma('journal_mode = WAL');
  conn.pragma('foreign_keys = ON');
  conn.exec(`
    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      provider TEXT NOT NULL,
      provider_session_id TEXT,
      questions_version TEXT,
      candidate_id INTEGER,
      question_id TEXT,
      question_index INTEGER,
      ended_reason TEXT,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      timezone TEXT,
      provider_meta TEXT
    );
    CREATE TABLE IF NOT EXISTS utterances (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      role TEXT NOT NULL,
      text TEXT NOT NULL,
      seq INTEGER,
      created_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id)
    );
    CREATE INDEX IF NOT EXISTS idx_utterances_session ON utterances(session_id);
    CREATE TABLE IF NOT EXISTS candidates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      display_name TEXT,
      resume_code TEXT UNIQUE NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS question_progress (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      candidate_id INTEGER NOT NULL,
      question_id TEXT,
      question_index INTEGER NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('pending','completed','timeout','skipped')),
      session_id INTEGER,
      answer_summary TEXT,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (candidate_id) REFERENCES candidates(id),
      FOREIGN KEY (session_id) REFERENCES sessions(id)
    );
    CREATE INDEX IF NOT EXISTS idx_progress_candidate ON question_progress(candidate_id);
    CREATE TABLE IF NOT EXISTS integrity_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      type TEXT NOT NULL,
      meta TEXT,
      ts TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id)
    );
    CREATE INDEX IF NOT EXISTS idx_integrity_session ON integrity_events(session_id);
    CREATE TABLE IF NOT EXISTS webcam_snapshots (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      path TEXT NOT NULL,
      ts TEXT NOT NULL,
      trigger TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id)
    );
    CREATE INDEX IF NOT EXISTS idx_snapshots_session ON webcam_snapshots(session_id);
  `);

  // Migrate an existing sessions table (from the pre-per-question schema) in place.
  ensureColumn(conn, 'sessions', 'candidate_id', 'candidate_id INTEGER');
  ensureColumn(conn, 'sessions', 'question_id', 'question_id TEXT');
  ensureColumn(conn, 'sessions', 'question_index', 'question_index INTEGER');
  ensureColumn(conn, 'sessions', 'ended_reason', 'ended_reason TEXT');
  ensureColumn(conn, 'sessions', 'timezone', 'timezone TEXT');
  ensureColumn(conn, 'sessions', 'provider_meta', 'provider_meta TEXT');
  ensureColumn(conn, 'webcam_snapshots', 'trigger', 'trigger TEXT');

  db = conn;
  return conn;
}

// ── Sessions ──────────────────────────────────────────────────────────────────
export function createSession(
  provider: string,
  providerSessionId: string | null,
  questionsVersion: string | null,
  meta: SessionMeta = {},
): number {
  const now = new Date().toISOString();
  const info = getDb()
    .prepare(
      `INSERT INTO sessions
         (provider, provider_session_id, questions_version, candidate_id, question_id, question_index, timezone, started_at, ended_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
    )
    .run(
      provider,
      providerSessionId,
      questionsVersion,
      meta.candidateId ?? null,
      meta.questionId ?? null,
      meta.questionIndex ?? null,
      meta.timezone ?? null,
      now,
    );
  return Number(info.lastInsertRowid);
}

export function endSession(
  sessionId: number,
  providerSessionId?: string | null,
  endedReason?: EndedReason | null,
): void {
  const now = new Date().toISOString();
  getDb()
    .prepare(
      `UPDATE sessions
         SET ended_at = ?,
             provider_session_id = COALESCE(?, provider_session_id),
             ended_reason = COALESCE(?, ended_reason)
       WHERE id = ?`,
    )
    .run(now, providerSessionId ?? null, endedReason ?? null, sessionId);
}

export function setProviderMeta(sessionId: number, meta: Record<string, unknown>): void {
  getDb()
    .prepare(`UPDATE sessions SET provider_meta = ? WHERE id = ?`)
    .run(JSON.stringify(meta), sessionId);
}

export function getSession(sessionId: number): SessionRow | undefined {
  return getDb().prepare(`SELECT * FROM sessions WHERE id = ?`).get(sessionId) as
    | SessionRow
    | undefined;
}

// ── Utterances ────────────────────────────────────────────────────────────────
export function insertUtterance(sessionId: number, u: UtteranceInput): void {
  getDb()
    .prepare(
      `INSERT INTO utterances (session_id, role, text, seq, created_at) VALUES (?, ?, ?, ?, ?)`,
    )
    .run(sessionId, u.role, u.text, u.seq ?? null, u.createdAt ?? new Date().toISOString());
}

// Reconcile: drop the live-captured rows for a session and replace them with an
// authoritative set (used for HeyGen, whose server transcript is the source of truth).
export function replaceUtterances(sessionId: number, rows: UtteranceInput[]): void {
  const conn = getDb();
  const del = conn.prepare(`DELETE FROM utterances WHERE session_id = ?`);
  const ins = conn.prepare(
    `INSERT INTO utterances (session_id, role, text, seq, created_at) VALUES (?, ?, ?, ?, ?)`,
  );
  const tx = conn.transaction((items: UtteranceInput[]) => {
    del.run(sessionId);
    items.forEach((u, i) => {
      ins.run(sessionId, u.role, u.text, u.seq ?? i, u.createdAt ?? new Date().toISOString());
    });
  });
  tx(rows);
}

export function getUtterances(sessionId: number): UtteranceRow[] {
  return getDb()
    .prepare(`SELECT * FROM utterances WHERE session_id = ? ORDER BY COALESCE(seq, id), id`)
    .all(sessionId) as UtteranceRow[];
}

// ── Candidates & progress ───────────────────────────────────────────────────────
export function createCandidate(displayName: string | null, resumeCode: string): number {
  const now = new Date().toISOString();
  const info = getDb()
    .prepare(`INSERT INTO candidates (display_name, resume_code, created_at) VALUES (?, ?, ?)`)
    .run(displayName, resumeCode, now);
  return Number(info.lastInsertRowid);
}

// Seed one 'pending' progress row per question, in order (atomic).
export function seedProgress(
  candidateId: number,
  questions: { id: string }[],
): void {
  const conn = getDb();
  const now = new Date().toISOString();
  const ins = conn.prepare(
    `INSERT INTO question_progress
       (candidate_id, question_id, question_index, status, session_id, answer_summary, updated_at)
     VALUES (?, ?, ?, 'pending', NULL, NULL, ?)`,
  );
  const tx = conn.transaction((items: { id: string }[]) => {
    items.forEach((q, i) => ins.run(candidateId, q.id, i, now));
  });
  tx(questions);
}

export function getCandidateByCode(code: string): CandidateRow | undefined {
  return getDb().prepare(`SELECT * FROM candidates WHERE resume_code = ?`).get(code) as
    | CandidateRow
    | undefined;
}

export function getCandidateById(id: number): CandidateRow | undefined {
  return getDb().prepare(`SELECT * FROM candidates WHERE id = ?`).get(id) as
    | CandidateRow
    | undefined;
}

export function getProgress(candidateId: number): ProgressRow[] {
  return getDb()
    .prepare(`SELECT * FROM question_progress WHERE candidate_id = ? ORDER BY question_index`)
    .all(candidateId) as ProgressRow[];
}

export function setProgressStatus(
  candidateId: number,
  questionIndex: number,
  status: ProgressStatus,
): void {
  getDb()
    .prepare(
      `UPDATE question_progress SET status = ?, updated_at = ?
       WHERE candidate_id = ? AND question_index = ?`,
    )
    .run(status, new Date().toISOString(), candidateId, questionIndex);
}

export function setProgressSession(
  candidateId: number,
  questionIndex: number,
  sessionId: number,
): void {
  getDb()
    .prepare(
      `UPDATE question_progress SET session_id = ?, updated_at = ?
       WHERE candidate_id = ? AND question_index = ?`,
    )
    .run(sessionId, new Date().toISOString(), candidateId, questionIndex);
}

export function setAnswerSummary(
  candidateId: number,
  questionIndex: number,
  summary: string,
): void {
  getDb()
    .prepare(
      `UPDATE question_progress SET answer_summary = ?, updated_at = ?
       WHERE candidate_id = ? AND question_index = ?`,
    )
    .run(summary, new Date().toISOString(), candidateId, questionIndex);
}

// ── Integrity (soft proctoring) ─────────────────────────────────────────────────
// Batch-insert a client flush of integrity events for a session, in one transaction
// (mirrors the replaceUtterances pattern). `meta` is serialized to a JSON string.
export function insertIntegrityEvents(sessionId: number, events: IntegrityEventInput[]): void {
  if (!events.length) return;
  const conn = getDb();
  const now = new Date().toISOString();
  const ins = conn.prepare(
    `INSERT INTO integrity_events (session_id, type, meta, ts, created_at) VALUES (?, ?, ?, ?, ?)`,
  );
  const tx = conn.transaction((items: IntegrityEventInput[]) => {
    for (const e of items) {
      ins.run(sessionId, e.type, e.meta ? JSON.stringify(e.meta) : null, e.ts, now);
    }
  });
  tx(events);
}

export function getIntegrityEvents(sessionId: number): IntegrityEventRow[] {
  return getDb()
    .prepare(`SELECT * FROM integrity_events WHERE session_id = ? ORDER BY ts, id`)
    .all(sessionId) as IntegrityEventRow[];
}

// Derived at query time (no stored column) — same approach as the cost estimate on the
// review page. Returns the weighted risk score + band for a session's integrity events.
export function computeIntegritySummary(sessionId: number): IntegritySummary {
  const rows = getIntegrityEvents(sessionId);
  const parsed = rows.map((r) => ({
    type: r.type,
    meta: r.meta ? (JSON.parse(r.meta) as Record<string, unknown>) : null,
  }));
  return summarizeIntegrity(parsed);
}

export interface SnapshotRow {
  id: number;
  session_id: number;
  path: string;
  ts: string;
  trigger: string | null; // null = periodic; otherwise the IntegrityType that triggered it
  created_at: string;
}

export function insertSnapshot(
  sessionId: number,
  path: string,
  ts: string,
  trigger: string | null = null,
): void {
  const now = new Date().toISOString();
  getDb()
    .prepare(
      `INSERT INTO webcam_snapshots (session_id, path, ts, trigger, created_at) VALUES (?, ?, ?, ?, ?)`,
    )
    .run(sessionId, path, ts, trigger, now);
}

export function getSnapshots(sessionId: number): SnapshotRow[] {
  return getDb()
    .prepare(`SELECT * FROM webcam_snapshots WHERE session_id = ? ORDER BY ts`)
    .all(sessionId) as SnapshotRow[];
}

// ── Admin queries ──────────────────────────────────────────────────────────────

export interface CandidateListRow extends CandidateRow {
  session_count: number;
  completed_questions: number;
  total_questions: number;
  last_activity: string | null;
  providers_used: string | null; // GROUP_CONCAT of distinct providers
  total_heygen_min: number; // sum of completed HeyGen session durations
  total_tavus_min: number; // sum of completed Tavus session durations
}

export function getAllCandidates(): CandidateListRow[] {
  return getDb()
    .prepare(
      // Independent per-candidate subqueries — NOT two parallel LEFT JOINs. Joining
      // sessions and question_progress at once fans out to #sessions × #questions rows,
      // which inflates any non-DISTINCT aggregate (completed_questions ×#sessions, the
      // minute sums ×#questions). Correlated subqueries keep each aggregate independent.
      `SELECT
         c.id, c.display_name, c.resume_code, c.created_at,
         (SELECT COUNT(*) FROM sessions s WHERE s.candidate_id = c.id) AS session_count,
         (SELECT COUNT(*) FROM question_progress qp
            WHERE qp.candidate_id = c.id AND qp.status = 'completed') AS completed_questions,
         (SELECT COUNT(*) FROM question_progress qp WHERE qp.candidate_id = c.id) AS total_questions,
         (SELECT MAX(COALESCE(s.ended_at, s.started_at)) FROM sessions s
            WHERE s.candidate_id = c.id) AS last_activity,
         (SELECT GROUP_CONCAT(DISTINCT s.provider) FROM sessions s
            WHERE s.candidate_id = c.id) AS providers_used,
         (SELECT COALESCE(SUM((julianday(s.ended_at) - julianday(s.started_at)) * 1440.0), 0)
            FROM sessions s
            WHERE s.candidate_id = c.id AND s.provider = 'heygen' AND s.ended_at IS NOT NULL)
           AS total_heygen_min,
         (SELECT COALESCE(SUM((julianday(s.ended_at) - julianday(s.started_at)) * 1440.0), 0)
            FROM sessions s
            WHERE s.candidate_id = c.id AND s.provider = 'tavus' AND s.ended_at IS NOT NULL)
           AS total_tavus_min
       FROM candidates c
       ORDER BY last_activity DESC, c.created_at DESC`,
    )
    .all() as CandidateListRow[];
}

// First question by index that is NOT completed (pending or timed-out both re-run) —
// this is the "retry on resume" landing point. null when every question is completed.
export function getNextQuestionIndex(candidateId: number): number | null {
  const row = getDb()
    .prepare(
      `SELECT MIN(question_index) AS idx FROM question_progress
       WHERE candidate_id = ? AND status != 'completed'`,
    )
    .get(candidateId) as { idx: number | null };
  return row?.idx ?? null;
}
