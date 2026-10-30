import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

const sourceStep = 'Qualify every source example and instruction frontier';
const sessionsStep = 'Check every selected current session fixture';
export const kosmosJobs = Object.freeze({
  TigerStyle: ['Check every tracked Zig file and the native auditor', 'Verify TigerStyle selection and failure behavior'],
  'Qualify / sessions': [sessionsStep],
  'Qualify / session-ownership': [sessionsStep],
  'Qualify / source-regressions': [sessionsStep],
  'Qualify / native': ['Compile native qualification and independently rebuild the core', 'Check native owners and independently rebuild the core'],
  'Qualify / specialization': ['Check specialization and public receipt owners'],
  'Qualify / source': [sourceStep],
  'Qualify / source-second': [sourceStep],
  'Qualify / portable': ['Install only the browser boundary\'s tools', 'Qualify the independent oracle and optional JS boundary',
    ...['kosmos-runtime-package.tar.gz', 'kosmos-kernel.wasm', 'kernel-profile.json', 'runtime.json'].map(name => `Retain tested ${name}`)],
  'Qualify / consumer': ['Check native release tooling and source coherence', 'Consume and retain the exact native source package',
    'Retain consumer-tested source archive', 'Retain native source and package identities', 'Test repository-local release boundaries'],
  'Runtime qualification budget': ['Require runtime qualification within ten minutes'],
  'Complete qualification': ['Require TigerStyle and bounded runtime qualification'],
});
export const kosmosArtifacts = Object.freeze({
  'source.tar': 64 * 1024 * 1024, 'source.json': 4 * 1024 * 1024,
  'kosmos-runtime-package.tar.gz': 64 * 1024 * 1024, 'kosmos-kernel.wasm': 64 * 1024 * 1024,
  'kernel-profile.json': 1024 * 1024, 'runtime.json': 1024 * 1024,
});

async function pages(reader, path, field) {
  const all = [], ids = new Set();
  for (let page = 1; page <= 100; page++) {
    const value = await reader.api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    const values = value[field];
    assert.ok(Array.isArray(values) && values.length <= 100, 'invalid qualification page');
    for (const item of values) {
      assert.ok(Number.isSafeInteger(item.id) && item.id > 0 && !ids.has(item.id), 'duplicate qualification observation');
      ids.add(item.id); all.push(item);
    }
    if (values.length < 100) return all;
  }
  throw new Error('qualification pagination capacity exceeded');
}

function timestamp(value) {
  assert.equal(typeof value, 'string');
  const result = Date.parse(value);
  assert.ok(Number.isFinite(result), 'missing original qualification timestamp');
  return result;
}

export function validateKosmosJobs(jobs, run) {
  assert.equal(run.run_attempt, 1, 'qualification retry cannot replace original evidence');
  const origin = timestamp(run.run_started_at);
  assert.ok(timestamp(run.created_at) <= origin);
  assert.ok(Array.isArray(jobs));
  assert.deepEqual(jobs.map(job => job.name).sort(), Object.keys(kosmosJobs).sort(), 'required qualification inventory differs');
  for (const job of jobs) {
    assert.equal(job.run_id, run.id); assert.equal(job.run_attempt, 1); assert.equal(job.head_sha, run.head_sha);
    assert.equal(job.status, 'completed'); assert.equal(job.conclusion, 'success', `qualification failed: ${job.name}`);
    const start = timestamp(job.started_at), end = timestamp(job.completed_at);
    const gate = ['Runtime qualification budget', 'Complete qualification'].includes(job.name);
    assert.ok(start >= origin && end >= start && end - start <= (gate ? 300000 : 600000), 'job deadline exceeded');
    assert.ok(job.labels?.includes('ubuntu-24.04'), 'wrong native platform');
    assert.ok(Array.isArray(job.steps), 'missing original steps');
    for (const required of kosmosJobs[job.name]) {
      const steps = job.steps.filter(step => step.name === required);
      assert.equal(steps.length, 1, `missing unique required step: ${required}`);
      assert.equal(steps[0].status, 'completed'); assert.equal(steps[0].conclusion, 'success', `required step did not pass: ${required}`);
      const stepStart = timestamp(steps[0].started_at), stepEnd = timestamp(steps[0].completed_at);
      assert.ok(stepStart >= start && stepEnd >= stepStart && stepEnd <= end, 'step clock differs');
    }
    if (job.name.startsWith('Qualify /') || job.name === 'Runtime qualification budget')
      assert.ok(end - origin <= 600000, 'aggregate runtime deadline exceeded');
  }
  const byName = new Map(jobs.map(job => [job.name, job]));
  const runtimeGate = byName.get('Runtime qualification budget'), complete = byName.get('Complete qualification');
  for (const job of jobs.filter(job => job.name.startsWith('Qualify /')))
    assert.ok(timestamp(job.completed_at) <= timestamp(runtimeGate.started_at), 'runtime gate precedes its dependencies');
  for (const job of [runtimeGate, byName.get('TigerStyle')])
    assert.ok(timestamp(job.completed_at) <= timestamp(complete.started_at), 'complete gate precedes its dependencies');
}

export function validateKosmosPayloads(payloads, {commit, tree, profile}) {
  assert.ok(payloads instanceof Map);
  for (const [name, maximum] of Object.entries(kosmosArtifacts)) {
    const bytes = payloads.get(name);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= maximum, `missing bounded payload ${name}`);
  }
  const inventory = parseEvidenceJson(payloads.get('source.json'));
  assert.equal(inventory.commit, commit); assert.equal(inventory.tree, tree); assert.equal(inventory.compiler, '0.17.0');
  assert.equal(inventory.archive, 'source.tar'); assert.equal(inventory.sha256, sha256(payloads.get('source.tar')));
  assert.equal(inventory.size, payloads.get('source.tar').length);
  const runtime = parseEvidenceJson(payloads.get('runtime.json'));
  assert.equal(runtime.schema, 'kosmos-runtime/v1'); assert.equal(runtime.compiler, '0.17.0');
  assert.equal(runtime.version, inventory.manifest.version); assert.equal(inventory.manifest.minimumCompiler, '0.17.0');
  assert.ok(inventory.packageIdentity.startsWith(`kosmos-${runtime.version}-`));
  const generated = parseEvidenceJson(payloads.get('kernel-profile.json'));
  assert.deepEqual(runtime.profile, generated);
  assert.equal(profile.zig, '0.17.0'); assert.equal(profile.hostMode, 'safe');
  assert.deepEqual(generated, {target: profile.target, mode: profile.kernelMode, backend: profile.wasmBackend,
    linker: profile.wasmLinker, cpu: profile.cpu, features: profile.features, stackBytes: profile.stackBytes,
    maximumMemoryBytes: profile.maximumMemoryBytes});
  assert.deepEqual(runtime.artifacts.map(item => item.name).sort(), ['kernel-profile.json', 'kosmos-kernel.wasm', 'kosmos-runtime-package.tar.gz']);
  for (const item of runtime.artifacts) {
    assert.equal(item.bytes, payloads.get(item.name).length); assert.equal(item.sha256, sha256(payloads.get(item.name)), 'final distributable bytes differ');
  }
  return {inventory, runtime};
}

export async function admitKosmosQualification({runId, commit, tree, event = 'push'}, command = githubCommand) {
  assert.match(commit, /^[0-9a-f]{40}$/); assert.match(tree, /^[0-9a-f]{40}$/);
  assert.ok(Number.isSafeInteger(runId) && runId > 0); assert.ok(['push', 'pull_request'].includes(event));
  const reader = new GitHubReader('tkersey/kosmos', command);
  await reader.verifyRepository();
  const run = await reader.api(`actions/runs/${runId}`);
  assert.equal(run.id, runId); assert.equal(run.repository.id, 1251308461); assert.equal(run.head_repository.id, 1251308461);
  assert.equal(run.path, '.github/workflows/runtime-bundle.yml'); assert.equal(run.head_sha, commit); assert.equal(run.event, event);
  if (event === 'push') assert.equal(run.head_branch, 'main');
  assert.equal(run.run_attempt, 1); assert.equal(run.status, 'completed'); assert.equal(run.conclusion, 'success');
  const observed = await pages(reader, `actions/workflows/runtime-bundle.yml/runs?head_sha=${commit}&event=${event}`, 'workflow_runs');
  assert.equal(observed.length, 1, 'ambiguous duplicate qualification runs'); assert.equal(observed[0].id, runId);
  const workflow = await reader.api(`actions/workflows/${run.workflow_id}`); assert.equal(workflow.path, run.path);
  const content = async path => {
    const value = await reader.api(`contents/${path}?ref=${commit}`);
    assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
    return Buffer.from(value.content.replaceAll('\n', ''), 'base64');
  };
  const workflowBytes = await content(run.path), profileBytes = await content('build-profile.json');
  const jobs = await pages(reader, `actions/runs/${runId}/attempts/1/jobs`, 'jobs'); validateKosmosJobs(jobs, run);
  const artifacts = await pages(reader, `actions/runs/${runId}/artifacts`, 'artifacts');
  const payloads = new Map();
  for (const [name, maximum] of Object.entries(kosmosArtifacts)) {
    const matches = artifacts.filter(artifact => artifact.name === name);
    assert.equal(matches.length, 1, `missing unique qualified artifact: ${name}`);
    const artifact = matches[0];
    assert.equal(artifact.expired, false); assert.equal(artifact.workflow_run.id, runId);
    assert.equal(artifact.workflow_run.repository_id, 1251308461); assert.equal(artifact.workflow_run.head_repository_id, 1251308461);
    assert.equal(artifact.workflow_run.head_sha, commit);
    assert.ok(Number.isSafeInteger(artifact.size_in_bytes) && artifact.size_in_bytes > 0 && artifact.size_in_bytes <= maximum);
    const bytes = await command(['api', `repos/tkersey/kosmos/actions/artifacts/${artifact.id}/zip`], maximum);
    assert.ok(Buffer.isBuffer(bytes)); assert.equal(bytes.length, artifact.size_in_bytes);
    assert.equal(artifact.digest, `sha256:${sha256(bytes)}`, 'artifact transport digest differs');
    payloads.set(name, bytes);
  }
  validateKosmosPayloads(payloads, {commit, tree, profile: parseEvidenceJson(profileBytes)});
  const actual = await reader.api(`git/commits/${commit}`);
  assert.equal(actual.sha, commit); assert.equal(actual.tree.sha, tree);
  const evidence = encodeRecord({run, jobs, artifacts, workflowSha256: sha256(workflowBytes), profileSha256: sha256(profileBytes)});
  return {run, jobs, payloads, evidence, workflow: {path: run.path, commit, sha256: sha256(workflowBytes)}};
}
