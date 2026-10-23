// version-allocator — one monotonic versionCode axis for the whole magisk ecosystem.
//
// Deployed on Cloudflare (Worker + D1, free tier). Account/worker/D1 ids live in
// AGENTS.md ("Gradle version axis"), not here: this file is the reviewable source.
//
// Design notes, in the order they matter:
//
//   1. The allocation log IS the ledger: no separate counter table to drift out of sync
//      with, and MAX(code) per project is the high-water mark by construction. Losing the
//      database therefore costs a re-seed, never a wrong number.
//   2. Allocation is a single SQL statement. SQLite serializes writers, so two concurrent
//      builds cannot observe the same MAX(code) and both take it: no read-modify-write window.
//   3. Idempotency is (project, scope) — the PRIMARY KEY is the pair, not scope alone.
//      A retried pipeline asks again with the same pair and gets its original number back
//      instead of burning a new one (Google Play burns every code it ever sees, which is why
//      resolve_play_release.sh has to probe generatedApks). 2026-10-23: the first deploy
//      keyed scope alone, so two projects using the same scope string silently shared a
//      number and one got the other's code back. Caught by the smoke test, fixed before any
//      real build consumed a number.
//   4. A project must have a seed row before it can allocate. Without that gate a typo in
//      the project name silently starts a second axis at code 1, below everything already
//      shipped.
//   5. Numbers only have to be increasing, never contiguous, so recovery may always jump:
//      raise the seed row and the next allocation lands above it.
//
// Auth: bearer token (Worker secret ALLOCATE_TOKEN). The worker sits on a public
// *.workers.dev hostname; without it anyone who found the URL could walk the axis.

const JSON_HEADERS = { 'content-type': 'application/json' };

function json(body, status) {
  return new Response(JSON.stringify(body), { status: status || 200, headers: JSON_HEADERS });
}

const PROJECT_RE = /^[A-Za-z0-9._-]{1,80}$/;
const SCOPE_RE = /^[A-Za-z0-9._:-]{1,160}$/;

async function seedOf(env, project) {
  const row = await env.DB.prepare('SELECT seed FROM projects WHERE name = ?').bind(project).first();
  return row ? row.seed : null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/health') {
      return json({ ok: true, service: 'version-allocator' });
    }
    if (url.pathname === '/') {
      return json({
        service: 'version-allocator',
        endpoints: ['POST /allocate {project, scope}', 'GET /state?project=<name>', 'GET /health'],
      });
    }

    const auth = request.headers.get('authorization') || '';
    if (!env.ALLOCATE_TOKEN || auth !== 'Bearer ' + env.ALLOCATE_TOKEN) {
      return json({ error: 'unauthorized' }, 401);
    }

    if (url.pathname === '/state') {
      const project = url.searchParams.get('project') || '';
      if (!PROJECT_RE.test(project)) return json({ error: 'bad project' }, 400);
      const high = await env.DB.prepare(
        'SELECT code, created_at FROM allocations WHERE project = ? ORDER BY code DESC LIMIT 1',
      ).bind(project).first();
      const seed = await seedOf(env, project);
      return json({
        project: project,
        registered: seed !== null,
        highWater: high ? high.code : null,
        highWaterAt: high ? high.created_at : null,
        seed: seed,
      });
    }

    if (url.pathname !== '/allocate') return json({ error: 'not found' }, 404);
    if (request.method !== 'POST') return json({ error: 'POST only' }, 405);

    let body;
    try {
      body = await request.json();
    } catch (err) {
      return json({ error: 'invalid json' }, 400);
    }
    const project = String(body.project || '').trim();
    const scope = String(body.scope || '').trim();
    if (!PROJECT_RE.test(project)) return json({ error: 'bad project' }, 400);
    if (!SCOPE_RE.test(scope)) return json({ error: 'bad scope' }, 400);
    if ((await seedOf(env, project)) === null) {
      return json({ error: 'unknown project: add a seed row first', project: project }, 400);
    }

    const now = new Date().toISOString();

    // max(high-water mark for THIS project, seed - 1) + 1, inserted only if this
    // (project, scope) pair is new. Both the guard and the read-back filter on project:
    // a scope string is only unique inside its project.
    const inserted = await env.DB.prepare(
      'INSERT INTO allocations (project, scope, code, created_at) ' +
        'SELECT ?2, ?1, ' +
        'max(COALESCE((SELECT MAX(code) FROM allocations WHERE project = ?2), 0), ' +
        '    COALESCE((SELECT seed - 1 FROM projects WHERE name = ?2), 0)) + 1, ' +
        '?3 ' +
        'WHERE NOT EXISTS (SELECT 1 FROM allocations WHERE project = ?2 AND scope = ?1) ' +
        'RETURNING project, scope, code, created_at',
    )
      .bind(scope, project, now)
      .first();

    if (inserted) {
      return json({ ok: true, project: project, scope: scope, code: inserted.code, replayed: false });
    }

    const existing = await env.DB.prepare(
      'SELECT code, created_at FROM allocations WHERE project = ? AND scope = ?',
    )
      .bind(project, scope)
      .first();
    if (!existing) return json({ error: 'allocation vanished, retry' }, 409);
    return json({
      ok: true,
      project: project,
      scope: scope,
      code: existing.code,
      replayed: true,
      firstAllocatedAt: existing.created_at,
    });
  },
};
