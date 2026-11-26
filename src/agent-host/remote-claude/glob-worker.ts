// Dedicated worker thread for Remote Claude's local `Glob` directory traversal so walking large
// workspace trees and testing path patterns never contends with the agent-host event loop.

import { Worker } from 'node:worker_threads'

export interface GlobWorkerParams {
  base: string
  patternSource: string
  maxResults: number
  maxWalk: number
  skipDirs: readonly string[]
  protectedPaths?: readonly string[]
  skipPackageSuffixes?: readonly string[]
  caseInsensitive?: boolean
}

type WorkerRequest = { id: number } & GlobWorkerParams

type WorkerReply =
  { id: number; ok: true; matches: string[] } | { id: number; ok: false; message: string }

const IDLE_MS = 30_000

// Self-contained CJS worker using only Node built-ins so it works identically in Vitest and the
// bundled daemon without requiring a separate Rollup entrypoint.
const WORKER_SOURCE = `'use strict';
const { readdir } = require('node:fs/promises');
const path = require('node:path');
const { parentPort } = require('node:worker_threads');

async function walkGlob(req) {
  const regex = new RegExp(req.patternSource);
  const skip = new Set(req.skipDirs);
  const ci = req.caseInsensitive === true;
  const protectedSet = new Set((req.protectedPaths || []).map((p) => (ci ? p.toLowerCase() : p)));
  const suffixes = req.skipPackageSuffixes || [];
  const matches = [];
  let visited = 0;

  function isSkippedDir(name, abs) {
    if (skip.has(name)) return true;
    if (suffixes.length > 0) {
      const lower = name.toLowerCase();
      for (const s of suffixes) {
        if (lower.endsWith(s)) return true;
      }
    }
    if (protectedSet.size > 0) {
      const key = ci ? abs.toLowerCase() : abs;
      if (protectedSet.has(key)) return true;
    }
    return false;
  }

  async function walk(dir, prefix) {
    if (matches.length >= req.maxResults || visited >= req.maxWalk) return;
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (matches.length >= req.maxResults || visited >= req.maxWalk) return;
      if (entry.isSymbolicLink()) continue;
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory() && isSkippedDir(entry.name, abs)) continue;
      visited += 1;
      const rel = prefix ? prefix + '/' + entry.name : entry.name;
      if (entry.isDirectory()) {
        await walk(abs, rel);
      } else if (regex.test(rel)) {
        matches.push(abs);
      }
    }
  }

  await walk(req.base, '');
  return matches;
}

parentPort.on('message', (req) => {
  walkGlob(req).then(
    (matches) => parentPort.postMessage({ id: req.id, ok: true, matches }),
    (err) => parentPort.postMessage({ id: req.id, ok: false, message: err ? String(err.message || err) : 'glob failed' }),
  );
});
`

let worker: Worker | null = null
let nextId = 1
let idleTimer: ReturnType<typeof setTimeout> | null = null
const pending = new Map<
  number,
  { resolve: (matches: string[]) => void; reject: (error: Error) => void }
>()

function resetIdle(): void {
  if (idleTimer) {
    clearTimeout(idleTimer)
    idleTimer = null
  }
  if (pending.size > 0 || !worker) return
  idleTimer = setTimeout(() => {
    idleTimer = null
    if (pending.size === 0 && worker) {
      const current = worker
      worker = null
      void current.terminate()
    }
  }, IDLE_MS)
  idleTimer.unref()
}

function ensureWorker(): Worker {
  if (worker) return worker
  const instance = new Worker(WORKER_SOURCE, { eval: true })
  instance.unref()
  instance.on('message', (reply: WorkerReply) => {
    const entry = pending.get(reply.id)
    if (!entry) return
    pending.delete(reply.id)
    resetIdle()
    if (reply.ok) entry.resolve(reply.matches)
    else entry.reject(new Error(reply.message))
  })
  const failAll = (error: Error): void => {
    if (worker === instance) worker = null
    const all = [...pending.values()]
    pending.clear()
    resetIdle()
    for (const entry of all) entry.reject(error)
  }
  instance.on('error', (error) =>
    failAll(error instanceof Error ? error : new Error(String(error))),
  )
  instance.on('exit', (code) => {
    if (pending.size > 0) failAll(new Error(`Glob worker exited (${code})`))
    else if (worker === instance) worker = null
  })
  worker = instance
  return instance
}

export function runGlobInWorker(params: GlobWorkerParams): Promise<string[]> {
  if (idleTimer) {
    clearTimeout(idleTimer)
    idleTimer = null
  }
  const id = nextId++
  const w = ensureWorker()
  return new Promise<string[]>((resolve, reject) => {
    pending.set(id, { resolve, reject })
    w.postMessage({ id, ...params } satisfies WorkerRequest)
  })
}

export async function closeGlobWorker(): Promise<void> {
  if (idleTimer) {
    clearTimeout(idleTimer)
    idleTimer = null
  }
  const current = worker
  worker = null
  const all = [...pending.values()]
  pending.clear()
  for (const entry of all) entry.reject(new Error('Glob worker closed'))
  if (current) await current.terminate()
}
