#!/usr/bin/env node
// n1d v3 — autonomous investigation backend.
//
// A local HTTP server that runs the Claude Code CLI as an autonomous data-science
// agent over the user's personal health/sensing data.
//
// Design principles (general — no special-casing for any specific question):
// 1. Discovery: the agent gets a dynamically generated data catalog listing every queryable source
//    (phone-provided + every JSON source in the local personal data store), not a fixed CSV.
// 2. Fetch on demand: the agent uses fetch.mjs to export any source it needs to CSV, then analyzes.
// 3. Ask when unsure: when answering requires an assumption about the user's life that the data
//    can't verify, the agent must stop and pose a structured question (options + custom) — never
//    silently invent a proxy variable.
//
// Configuration (all via environment variables):
//   PORT                  HTTP port to listen on.            Default: 8787
//   N1_BIND               Bind address.                      Default: 127.0.0.1
//   N1_MODEL              Claude model id passed to `claude`. Default: claude-opus-4-8
//   N1_HANDBOOK           Path to the agent methodology file. Default: ../agent/handbook.md
//   N1_EXTRA_SOURCES_DIR  Optional directory of extra JSON data sources to expose in the
//                         catalog. If unset, the catalog just contains phone-provided sources.
//   N1_SENSING_FILE       Name of the optional sensing event-log file in that directory.
//                         Default: sensing.json
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.PORT) || 8787;
const MODEL = process.env.N1_MODEL || 'claude-opus-4-8';

// Personal data store: an optional directory of JSON data sources scanned into the catalog.
// Purely env-driven: set N1_EXTRA_SOURCES_DIR to point at your own store. If unset, the
// catalog simply contains the phone-provided sources (no crash).
function resolveExtraSourcesDir() {
  return process.env.N1_EXTRA_SOURCES_DIR || null;
}
const EXTRA_SOURCES_DIR = resolveExtraSourcesDir();

// Optional sensing event-log file inside the data store. It holds many modalities in a single
// JSON array (each event: { modality, timestamp, payload }), each of which becomes its own source.
// The filename is env-configurable; defaults to a neutral name.
const SENSING_FILE = process.env.N1_SENSING_FILE || 'sensing.json';

// The agent's methodology is an editable handbook, not a hardcoded string.
// Reloaded per request → editing handbook.md takes effect on save, no restart.
const HANDBOOK_PATH = process.env.N1_HANDBOOK
  || join(dirname(fileURLToPath(import.meta.url)), '..', 'agent', 'handbook.md');
function loadHandbook() {
  try { return readFileSync(HANDBOOK_PATH, 'utf8'); }
  catch { return 'You are the user\'s personal data scientist. Read CATALOG.md and TASK.md first, investigate autonomously, and write the result to result.json (steps/findings/askUser/collectionPlan/unmeasured/followups). Every number must come from code you actually ran.'; }
}

// catalog: scan the personal data store and generate the source list dynamically.
// Any new modality/file appears automatically — no code change needed.
// Safe when EXTRA_SOURCES_DIR is null or the directory is empty: returns [].
function buildCatalog() {
  const sources = [];
  if (!EXTRA_SOURCES_DIR || !existsSync(EXTRA_SOURCES_DIR)) return sources;
  const sensingPath = join(EXTRA_SOURCES_DIR, SENSING_FILE);
  if (existsSync(sensingPath)) {
    try {
      const events = JSON.parse(readFileSync(sensingPath, 'utf8'));
      const byMod = {};
      for (const e of events) {
        const m = e.modality; if (!m) continue;
        (byMod[m] ??= { count: 0, fields: new Set(), first: e.timestamp, last: e.timestamp });
        byMod[m].count++;
        for (const k of Object.keys(e.payload ?? {})) byMod[m].fields.add(k);
        if (e.timestamp < byMod[m].first) byMod[m].first = e.timestamp;
        if (e.timestamp > byMod[m].last) byMod[m].last = e.timestamp;
      }
      for (const [m, info] of Object.entries(byMod)) {
        sources.push({
          id: `sensing:${m}`, origin: 'personal data store (sensing)', modality: m,
          fields: ['timestamp', ...info.fields], count: info.count,
          coverage: `${(info.first || '').slice(0, 10)} ~ ${(info.last || '').slice(0, 10)}`,
          fetch: `node fetch.mjs sensing:${m}`,
        });
      }
    } catch {}
  }
  // Structured module files (health_*, module_*) — each is a JSON array of records.
  for (const f of readdirSync(EXTRA_SOURCES_DIR)) {
    if (!/^(health_|module_)/.test(f) || !f.endsWith('.json')) continue;
    try {
      const arr = JSON.parse(readFileSync(join(EXTRA_SOURCES_DIR, f), 'utf8'));
      if (!Array.isArray(arr) || arr.length === 0) continue;
      const id = f.replace('.json', '');
      sources.push({
          id, origin: 'personal data store (module)', modality: id,
          fields: Object.keys(arr[0] ?? {}), count: arr.length, coverage: 'see data',
          fetch: `node fetch.mjs ${id}`,
        });
    } catch {}
  }
  return sources;
}

function writeWorkspace(ws, question, context, phoneSources, dataNotes, profile) {
  const srcDir = join(ws, 'sources');
  mkdirSync(srcDir, { recursive: true });

  // Phone-side sources (HealthKit etc.) are written into sources/ and added to the catalog.
  const catalog = buildCatalog();
  for (const [name, csv] of Object.entries(phoneSources ?? {})) {
    if (!csv) continue;
    writeFileSync(join(srcDir, `${name}.csv`), csv);
    const header = csv.split('\n')[0] ?? '';
    catalog.unshift({
      id: name, origin: 'phone (ready)', modality: name,
      fields: header.split(','), count: csv.split('\n').length - 2,
      coverage: 'matches phone data', fetch: `already at sources/${name}.csv`,
    });
  }
  writeFileSync(join(ws, 'catalog.json'), JSON.stringify(catalog, null, 2));

  const md = catalog.map(s =>
    `### ${s.id}\n- Origin: ${s.origin}　Coverage: ${s.coverage}　Samples: ${s.count}\n- Fields: ${s.fields.join(', ')}\n- Fetch: \`${s.fetch}\``
  ).join('\n\n');
  writeFileSync(join(ws, 'CATALOG.md'),
    `# Available data sources\n\nEverything you can investigate is listed below. Phone sources are already in sources/; export the rest on demand with the given command.\n\n${md}\n`);

  // fetch tool: export any personal-data-store source to CSV
  writeFileSync(join(ws, 'fetch.mjs'), buildFetchTool());

  const profileBlock = (profile?.length)
    ? `Confirmed ground truth about this user (use it; don't re-ask):\n${profile.map(p => '- ' + p).join('\n')}\n\n`
    : '';
  writeFileSync(join(ws, 'TASK.md'),
    `# Task\n\nUser question: ${question}\n\n${profileBlock}${context?.length ? 'Known conversation context:\n' + context.join('\n') + '\n\n' : ''}${dataNotes ?? ''}`);
}

// Generate the fetch.mjs tool dropped into each workspace. The resolved data-store
// path and sensing filename are baked in so the agent reads from the right place
// regardless of how the store was configured.
function buildFetchTool() {
  const D = JSON.stringify(EXTRA_SOURCES_DIR || '');
  const SENSING = JSON.stringify(SENSING_FILE);
  return `// node fetch.mjs <source_id> — export one data source to CSV at sources/<id>.csv
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
const D = ${D};
const SENSING_FILE = ${SENSING};
const id = process.argv[2];
if (!id) { console.error('usage: node fetch.mjs <source_id>'); process.exit(1); }
if (!D) { console.error('no personal data store configured (set N1_EXTRA_SOURCES_DIR)'); process.exit(1); }
mkdirSync('sources', { recursive: true });
function flat(o, p='') { const r={}; for (const k in o){ const v=o[k]; const nk=p?p+'_'+k:k;
  if (v && typeof v==='object' && !Array.isArray(v)) Object.assign(r, flat(v, nk)); else r[nk]=v; } return r; }
function toCSV(rows){ if(!rows.length) return ''; const cols=[...new Set(rows.flatMap(r=>Object.keys(r)))];
  const esc=v=>{ if(v==null) return ''; const s=String(v); return /[",\\n]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s; };
  return cols.join(',')+'\\n'+rows.map(r=>cols.map(c=>esc(r[c])).join(',')).join('\\n'); }
let rows;
if (id.startsWith('sensing:')) {
  const mod=id.slice(8); const ev=JSON.parse(readFileSync(join(D, SENSING_FILE),'utf8'));
  rows=ev.filter(e=>e.modality===mod).map(e=>({timestamp:e.timestamp, ...flat(e.payload||{})}));
} else {
  rows=JSON.parse(readFileSync(join(D, id+'.json'),'utf8')).map(r=>flat(r));
}
const out=join('sources', id.replace(':','_')+'.csv');
writeFileSync(out, toCSV(rows));
console.log('exported '+rows.length+' rows -> '+out);
`;
}

// sessionId -> workspace path, so a follow-up turn resumes the SAME conversation
// in the SAME workspace (the agent keeps everything it already fetched/computed).
const SESSIONS = new Map();

// Hard ceiling on a single claude run. The phone's request timeout is 480s; keep
// the killer slightly under that so a timeout surfaces as a clean error event
// rather than the phone giving up on a dead socket.
const RUN_TIMEOUT_MS = 460_000;

// --- Job store -------------------------------------------------------------
// Every run is recorded under a job id so a phone that loses the live stream
// (e.g. on backgrounding) can reconnect with GET /job/:id and recover the steps
// + final result/error instead of silently failing.
const JOBS = new Map();            // id -> { id, status, steps, result, error, sessionId, createdAt, updatedAt }
const JOB_TTL_MS = 60 * 60 * 1000; // keep finished jobs for an hour

function newJob() {
  const id = randomUUID();
  const job = { id, status: 'running', steps: [], result: null, error: null,
                sessionId: null, createdAt: Date.now(), updatedAt: Date.now() };
  JOBS.set(id, job);
  // opportunistic GC of old jobs
  const cutoff = Date.now() - JOB_TTL_MS;
  for (const [k, j] of JOBS) if (j.status !== 'running' && j.updatedAt < cutoff) JOBS.delete(k);
  return job;
}
function jobStep(job, step) { job.steps.push(step); job.updatedAt = Date.now(); }
function jobDone(job, result, sessionId) {
  job.status = 'done'; job.result = result; job.sessionId = sessionId ?? job.sessionId;
  job.updatedAt = Date.now();
}
function jobError(job, error) {
  job.status = 'error'; job.error = String(error); job.updatedAt = Date.now();
}

// Robustly extract the agent's result object. The agent is asked to write
// result.json, but LLMs sometimes wrap JSON in prose or a ```json fence, or
// write slightly malformed JSON. Recover what we can; never hand back a raw throw.
function parseResultFile(resultPath) {
  if (!existsSync(resultPath)) return { ok: false, reason: 'no-file' };
  let raw;
  try { raw = readFileSync(resultPath, 'utf8'); }
  catch (e) { return { ok: false, reason: 'unreadable', error: String(e) }; }
  const parsed = extractJSON(raw);
  if (parsed) return { ok: true, payload: parsed };
  return { ok: false, reason: 'unparseable', raw };
}

// When result.json is missing/unparseable, build an honest payload the app can
// render — never a blank turn. Surfaces the situation as a finding so the user
// sees an explanation rather than nothing.
function fallbackPayload(parsed, mode) {
  // If the agent wrote prose with an embedded object we couldn't fully parse,
  // try once more to salvage any partial object from the raw text.
  if (parsed.reason === 'unparseable' && parsed.raw) {
    const salvaged = extractJSON(parsed.raw);
    if (salvaged) return salvaged;
  }
  const headline = parsed.reason === 'no-file'
    ? "The analysis finished without writing a result this time."
    : "The analysis produced output the app couldn't read.";
  return {
    steps: [{ title: 'Analysis ended without a clean result', detail: `reason: ${parsed.reason}` }],
    findings: [{
      headline,
      caveat: "This is a backend hiccup, not a finding about your data. Try asking again — your previous data is kept.",
    }],
    askUser: null,
    ...(mode === 'onboarding' ? { groundTruth: [], suggestedQuestions: [] } : {}),
  };
}

// Try hard to pull a JSON object out of arbitrary text.
function extractJSON(text) {
  if (typeof text !== 'string' || !text.trim()) return null;
  const t = text.trim();
  // 1. straight parse
  try { const o = JSON.parse(t); if (o && typeof o === 'object') return o; } catch {}
  // 2. fenced ```json ... ``` block
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) { try { const o = JSON.parse(fence[1].trim()); if (o && typeof o === 'object') return o; } catch {} }
  // 3. first balanced {...} span (handles prose around the object, strings/escapes aware)
  const span = balancedObject(t);
  if (span) { try { const o = JSON.parse(span); if (o && typeof o === 'object') return o; } catch {} }
  return null;
}

function balancedObject(s) {
  const start = s.indexOf('{');
  if (start < 0) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < s.length; i++) {
    const ch = s[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === '\\') esc = true;
      else if (ch === '"') inStr = false;
    } else {
      if (ch === '"') inStr = true;
      else if (ch === '{') depth++;
      else if (ch === '}') { depth--; if (depth === 0) return s.slice(start, i + 1); }
    }
  }
  return null;
}

// resumeId: if set, continue that Claude session instead of starting fresh.
// onStep streams chain-of-thought; resolves with the captured session_id.
function streamClaude(workspace, { prompt, resumeId }, onStep) {
  return new Promise((resolve, reject) => {
    const args = ['-p', '--model', MODEL, '--output-format', 'stream-json', '--verbose',
                  '--allowedTools', 'Bash,Read,Write,Glob,Grep', '--max-turns', '60'];
    if (resumeId) args.push('--resume', resumeId);
    args.push(prompt);
    const p = spawn('claude', args, { cwd: workspace });
    let timedOut = false;
    const killer = setTimeout(() => {
      timedOut = true; p.kill('SIGKILL');
      reject(new Error(`analysis timed out after ${Math.round(RUN_TIMEOUT_MS / 1000)}s`));
    }, RUN_TIMEOUT_MS);
    let buf = '', sessionId = null;
    p.stdout.on('data', chunk => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        try {
          const ev = JSON.parse(line);
          if (ev.session_id) sessionId = ev.session_id;
          for (const step of eventToSteps(ev)) onStep(step);
        } catch {}
      }
    });
    p.on('error', e => { clearTimeout(killer); if (!timedOut) reject(e); });
    p.on('close', () => { clearTimeout(killer); if (!timedOut) resolve(sessionId); });
  });
}

function eventToSteps(ev) {
  if (ev.type !== 'assistant') return [];
  const steps = [];
  for (const c of ev.message?.content ?? []) {
    if (c.type === 'text' && c.text?.trim()) {
      steps.push({ title: 'Thinking', detail: c.text.trim().replace(/\s+/g, ' ').slice(0, 160) });
    } else if (c.type === 'tool_use') {
      const i = c.input ?? {};
      if (c.name === 'Bash') {
        const cmd = i.command ?? '';
        const title = cmd.includes('fetch.mjs') ? 'Pulling a data source' : 'Running code';
        steps.push({ title, detail: (i.description || cmd.split('\n')[0]).slice(0, 100) });
      } else if (c.name === 'Write') steps.push({ title: 'Writing analysis script', detail: String(i.file_path ?? '').split('/').pop() });
      else if (c.name === 'Read') steps.push({ title: 'Reading', detail: String(i.file_path ?? '').split('/').pop() });
      else if (c.name === 'Glob' || c.name === 'Grep') steps.push({ title: 'Searching data', detail: i.pattern ?? '' });
    }
  }
  return steps;
}

const server = createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method === 'GET' && req.url === '/health') {
    res.end(JSON.stringify({ ok: true, backend: 'autonomous-investigator', model: MODEL,
                             sources: buildCatalog().length })); return;
  }
  // Reconnect/poll endpoint: a phone that lost the live stream (backgrounding,
  // flaky link) refetches the whole job by id — steps so far + result/error.
  if (req.method === 'GET' && req.url.startsWith('/job/')) {
    const id = decodeURIComponent(req.url.slice('/job/'.length).split('?')[0]);
    const job = JOBS.get(id);
    if (!job) { res.statusCode = 404; res.end(JSON.stringify({ error: 'unknown job id' })); return; }
    res.end(JSON.stringify({
      id: job.id, status: job.status, steps: job.steps,
      result: job.result, error: job.error, sessionId: job.sessionId })); return;
  }
  if (req.method !== 'POST') { res.statusCode = 404; res.end('{}'); return; }
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    let parsed;
    try { parsed = JSON.parse(body); }
    catch { res.statusCode = 400; res.end(JSON.stringify({ error: 'bad json' })); return; }
    // Start-then-poll: respond IMMEDIATELY with a job id and run the job in the
    // background. The phone never holds a long-lived connection (which iOS kills on
    // backgrounding / status-bar pull); it just polls GET /job/:id with short requests.
    const job = newJob();
    res.end(JSON.stringify({ jobId: job.id }));
    runJob(job, parsed).catch(e => { console.error('[n1d] runJob:', e); jobError(job, e); });
  });
});

// Execute one investigation/onboarding run, recording everything into the job.
// Runs independently of any client connection.
async function runJob(job, { question, sessionId, phoneSources, dataNotes = '', profile, mode }) {
  let ws, prompt, resumeId;
  const resumeWs = sessionId && SESSIONS.get(sessionId);
  if (resumeWs && existsSync(resumeWs)) {
    ws = resumeWs; resumeId = sessionId;
    try { rmSync(join(ws, 'result.json')); } catch {}
    prompt = `The user replied to your question: "${question}"\n\nContinue from where you were — do not redo work you've already done. Use what you already fetched/computed. Re-investigate only what this answer changes, then write the updated result.json.`;
    console.log(`[n1d] resume ${sessionId} in ${ws}: ${String(question).slice(0, 50)}…`);
  } else {
    ws = mkdtempSync(join(tmpdir(), 'n1-'));
    const task = mode === 'onboarding'
      ? "ONBOARDING: The user just granted data access. (1) Explore their data and propose a few high-confidence GROUND-TRUTH facts about their routines for them to confirm (e.g. work location/hours, home, typical bedtime/wake, commute) — only things the data actually supports — in result.json's `groundTruth` array (each: id, statement, question, options?, allowCustom), 3-6 candidates. (2) ALSO surface 3-5 PERSONALIZED, high-value questions THIS specific user would find worth investigating, grounded in patterns you actually saw in their data (not generic) — put them in `suggestedQuestions` (array of plain-language question strings, in the user's likely language). Do NOT emit findings."
      : "Read CATALOG.md and TASK.md first, then begin your investigation.";
    writeWorkspace(ws, question, [], phoneSources, dataNotes, profile);
    prompt = `${loadHandbook()}\n\n---\n\n${task}`;
    console.log(`[n1d] ${mode === 'onboarding' ? 'onboarding' : 'investigate'} job=${job.id}: ${String(question).slice(0, 60)}… ws=${ws}`);
  }

  const newSession = await streamClaude(ws, { prompt, resumeId }, step => jobStep(job, step));
  if (newSession) { SESSIONS.set(newSession, ws); job.sessionId = newSession; }

  const result = parseResultFile(join(ws, 'result.json'));
  if (result.ok) {
    jobDone(job, result.payload, newSession);
  } else {
    console.error(`[n1d] result recovery failed (${result.reason}) for job ${job.id}`);
    jobDone(job, fallbackPayload(result, mode), newSession);
  }
}

// Bind to localhost by default. To let an iPhone reach it over Tailscale, set
// N1_BIND=0.0.0.0 — and ONLY on a private tailnet you fully trust: this server runs an
// agent with shell access, so never expose it on an untrusted network.
const HOST = process.env.N1_BIND || '127.0.0.1';
server.listen(PORT, HOST, () =>
  console.log(`n1d v3 (autonomous investigator) on http://${HOST}:${PORT} · model=${MODEL} · ${buildCatalog().length} sources`));
