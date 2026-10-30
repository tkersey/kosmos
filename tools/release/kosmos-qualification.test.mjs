import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {admitKosmosQualification, validateKosmosJobs, validateKosmosPayloads, kosmosJobs} from './kosmos-qualification.mjs';
import {kosmosFixture} from './kosmos-test-support.mjs';

test('original twelve-job qualification retains six exact final payloads; TigerStyle remains outside runtime budget', async () => {
  const f = kosmosFixture();
  const result = await admitKosmosQualification({runId: 17, commit: f.commit, tree: f.tree}, f.command);
  assert.equal(result.jobs.length, 12); assert.equal(result.payloads.size, 6);
  assert.deepEqual(JSON.parse(result.evidence).jobs, f.jobs);
});

for (const [name, mutate] of [
  ['missing lane', f => f.jobs.pop()],
  ['duplicate lane', f => {f.jobs[1] = f.jobs[0];}],
  ['missing actual step', f => f.jobs[1].steps.pop()],
  ['skipped actual step', f => {f.jobs[1].steps[0].conclusion = 'skipped';}],
  ['wrong platform', f => {f.jobs[1].labels = ['macos-14'];}],
  ['wrong source', f => {f.jobs[1].head_sha = f.tree;}],
  ['runtime budget overrun', f => {f.jobs[1].completed_at = '2026-10-30T00:10:01Z';}],
  ['individual Tiger deadline overrun', f => {f.jobs[0].completed_at = '2026-10-30T00:10:01Z';}],
  ['premature aggregate', f => {f.jobs[10].started_at = '2026-10-30T00:04:59Z';}],
  ['retry laundering', f => {f.run.run_attempt = 2;}],
  ['wrong workflow', f => {f.run.path = '.github/workflows/diagnostic.yml';}],
  ['wrong event', f => {f.run.event = 'workflow_dispatch';}],
  ['expired artifact', f => {f.artifacts[0].expired = true;}],
  ['replayed artifact', f => {f.artifacts[0].workflow_run.id++;}],
  ['transport corruption', f => {f.replies.set('repos/tkersey/kosmos/actions/artifacts/80/zip', Buffer.from('corrupt'));}],
  ['duplicate original run', f => {f.replies.get(`repos/tkersey/kosmos/actions/workflows/runtime-bundle.yml/runs?head_sha=${f.commit}&event=push&per_page=100&page=1`).workflow_runs.push({...f.run, id: 18});}],
]) test(`qualification rejects ${name}`, async () => {
  const f = kosmosFixture(); mutate(f);
  await assert.rejects(admitKosmosQualification({runId: 17, commit: f.commit, tree: f.tree}, f.command));
});

for (const result of ['skipped', 'neutral', 'failure', 'cancelled', 'timed_out', null]) test(`required ${result} lane cannot qualify`, () => {
  const f = kosmosFixture(); f.jobs[1].conclusion = result;
  assert.throws(() => validateKosmosJobs(f.jobs, f.run));
});

for (const name of ['kosmos-runtime-package.tar.gz', 'kosmos-kernel.wasm', 'kernel-profile.json']) test(`changed final ${name} blocks despite unchanged source`, () => {
  const f = kosmosFixture(); f.payloads.set(name, Buffer.from('changed final bytes'));
  assert.throws(() => validateKosmosPayloads(f.payloads, f));
});

test('admission inventory names every required executable workflow step and retains no repacked payload', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/runtime-bundle.yml', import.meta.url), 'utf8');
  for (const steps of Object.values(kosmosJobs)) for (const name of steps) assert.ok(workflow.includes(`name: ${name}\n`), name);
  assert.equal((workflow.match(/archive: false/g) ?? []).length, 6);
  assert.ok(!workflow.includes('npm pack'));
});
