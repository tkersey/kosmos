import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import test from 'node:test';
import {proposalBranch, proposalDescription, proposalMessage, proposalCommitOid, mechanicalPaths} from './kosmos-proposal.mjs';
import {currentKosmosSource, appActor, storedKosmosCandidate, preparationPulls, promotionRequirements,
  originalKosmosQualification, retireKosmosProposal} from './kosmos-release-observation.mjs';
import {sha256} from './encoding.mjs';

const base = 'a'.repeat(40), actor = {id: 42, login: 'kosmos-release[bot]'};
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const file = bytes => ({type: 'file', encoding: 'base64', content: bytes.toString('base64'), sha: blob(bytes)});
async function fixture() {
  const baseManifest = Buffer.from('.{ .version = "1.0.0" }'), prepared = Buffer.from('.{ .version = "1.0.1" }');
  const native = {read: bytes => {assert.deepEqual(bytes, prepared); return '1.0.1';},
    prepare: (bytes, version) => {assert.deepEqual(bytes, baseManifest); assert.equal(version, '1.0.1'); return Buffer.from(prepared);}};
  const entries = [{path: 'build.zig.zon', mode: '100644', type: 'blob', sha: blob(baseManifest)}], tree = 'b'.repeat(40);
  const repository = {id: 1251308461, full_name: 'tkersey/kosmos', default_branch: 'main'};
  const values = new Map([
    ['', repository], ['/git/ref/heads/main', {ref: 'refs/heads/main', object: {type: 'commit', sha: base}}],
    [`/git/commits/${base}`, {sha: base, tree: {sha: tree}, committer: {date: '2026-10-30T00:00:00Z'}}],
    [`/git/trees/${tree}`, {sha: tree, truncated: false, tree: entries}],
    [`/contents/build.zig.zon?ref=${base}`, file(baseManifest)],
  ]);
  const client = {async request({path, method = 'GET'}) {
    assert.equal(method, 'GET'); assert.ok(values.has(path), path); return {status: 200, body: structuredClone(values.get(path))};
  }};
  const files = new Map(mechanicalPaths.map(path => [path, Buffer.from('native ' + path)]));
  files.set('build.zig.zon', prepared);
  const horos = {releaseId: 1, recordSha256: 'e'.repeat(64), commit: 'f'.repeat(40), tree: 'e'.repeat(40), packageIdentity: `horos-1.0.0-${'a'.repeat(44)}`};
  const person = {name: actor.login, email: 'fixture@example.invalid', date: '2026-10-30T00:00:00Z'};
  const nativeResultBytes = Buffer.from(JSON.stringify({schema: 'kosmos-refresh-result/v1', baseCommit: base, baseTree: tree,
    version: '1.0.1', horosCommit: horos.commit, horosTree: horos.tree, horosPackageIdentity: horos.packageIdentity, changed: [...mechanicalPaths]}));
  const candidate = {base, baseTree: tree, tree: 'c'.repeat(40), files, version: '1.0.1', horos, nativeResultBytes,
    author: person, committer: {...person}, impact: {impact: 'patch', disposition: 'compatible', rationale: 'Synthetic native fixture.', contracts: ['native projection']}};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  const readPreparation=async()=>({candidate});
  values.set(`/git/commits/${candidate.head}`, {sha: candidate.head, tree: {sha: candidate.tree},
    parents: [{sha: base}], message: candidate.message});
  for (const [path, bytes] of files) values.set(`/contents/${path}?ref=${candidate.head}`, file(bytes));
  const run = {id: 17, head_sha: candidate.head, event: 'pull_request', repository: {id: 1251308461},
    head_repository: {id: 1251308461}, path: '.github/workflows/runtime-bundle.yml', run_attempt: 1,
    status: 'completed', conclusion: 'failure'};
  const runs = [run];
  const command = async args => {
    const path = args[1];
    if (path === `repos/tkersey/kosmos/actions/workflows/runtime-bundle.yml/runs?head_sha=${candidate.head}&event=pull_request&per_page=100&page=1`)
      return Buffer.from(JSON.stringify({workflow_runs: runs}));
    assert.equal(path, 'repos/tkersey/kosmos/actions/runs/17'); return Buffer.from(JSON.stringify(run));
  };
  const pull = {id: 52, number: 52, state: 'open', head: {ref: proposalBranch, sha: candidate.head, repo: {id: 1251308461}},
    base: {ref: 'main', repo: {id: 1251308461}}};
  pull.body = proposalDescription(candidate).body; pull.title = `Prepare Kosmos ${candidate.version}`;
  let result = {status: 'absent'};
  const retire = retireKosmosProposal({client, native, actor, command, readResult: async () => result,readCandidate:async()=>candidate});
  return {candidate, client, native, actor, values, tree, run, runs, command, pull,readPreparation,
    retire: () => retire({pull, knownHead: candidate.head}), setReview: value => {result = value;}};
}

test('stored candidate reconstructs the exact native manifest, Git tree and original commit', async () => {
  const f = await fixture();
  assert.deepEqual(await currentKosmosSource(f.client), {commit: base, tree: f.tree});
  assert.deepEqual(await storedKosmosCandidate(f.candidate.head, f), f.candidate);
  f.values.get(`/git/commits/${f.candidate.head}`).message += 'changed';
  await assert.rejects(storedKosmosCandidate(f.candidate.head, f), /strictly equal/);
});

test('pre-review retirement admits only the unique original terminal failed qualification', async () => {
  const f = await fixture(), result = await f.retire();
  assert.equal(result.epochClosed, true); assert.deepEqual(result.previousCandidate, f.candidate);
  assert.deepEqual(result.qualificationFailure, {runId: 17, conclusion: 'failure'});
});

for (const [name, mutate] of [
  ['success', f => {f.run.conclusion = 'success';}],
  ['pending', f => {f.run.status = 'in_progress'; f.run.conclusion = null;}],
  ['skipped', f => {f.run.conclusion = 'skipped';}],
  ['neutral', f => {f.run.conclusion = 'neutral';}],
  ['missing run', f => {f.runs.length = 0;}],
  ['duplicate run', f => {f.runs.push({...f.run, id: 18});}],
  ['retry', f => {f.run.run_attempt = 2;}],
  ['wrong repository', f => {f.run.head_repository.id++;}],
  ['different workflow', f => {f.run.path = '.github/workflows/other.yml';}],
  ['different source', f => {f.run.head_sha = base;}],
  ['manual run', f => {f.run.event = 'workflow_dispatch';}],
]) test(`unreviewed retirement refuses ${name}`, async () => {
  const f = await fixture(); mutate(f); await assert.rejects(f.retire());
});

test('an original authenticated closed owner epoch permits successor preparation', async () => {
  const f = await fixture();
  const envelope = {schema: 'repository-review-result/v1', context: {repository: 'tkersey/kosmos', base,
    head: f.candidate.head, tree: f.candidate.tree, pullNumber: 52}, status: 'blocked', reason: 'Owner closed the invalidated epoch.',
    epochClosed: true, turn: 1, previousSha256: null, stateSha256: null, retainedEvidence: null};
  f.setReview({status: 'blocked', bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 20}, artifact: {id: 21}});
  assert.equal((await f.retire()).review.runId, 20);
  envelope.epochClosed = false;
  f.setReview({status: 'blocked', bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 20}, artifact: {id: 21}});
  await assert.rejects(f.retire(), /did not close/);
});

for (const status of ['pending', 'running']) test(`owner ${status} is never replaced by a failed product run`, async () => {
  const f = await fixture(); f.setReview({status}); await assert.rejects(f.retire(), /still active/);
});

test('check requirements derive actual accepted definitions and retain effective human policy', async () => {
  const f = await fixture();
  for (const path of ['.github/workflows/repository-automation.yml', '.github/workflows/repository-review.yml',
    '.github/workflows/runtime-bundle.yml', 'docs/repository-local-releases.md'])
    f.values.set(`/contents/${path}?ref=${base}`, file(Buffer.from(path)));
  const value = await promotionRequirements(base, 77, f.client);
  assert.equal(value.checks.qualification.appId, 15368); assert.equal(value.checks.review.appId, 77);
  assert.equal(value.control.sha256, sha256(Buffer.from(value.control.path)));
  assert.equal(value.reviews.requiredApprovingReviewCount, 0);
  assert.equal(value.acceptedRequirements.text, 'docs/repository-local-releases.md');
});

test('preparation pull observation rejects multiple open candidates', async () => {
  const f = await fixture();
  f.values.set(`/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}&per_page=100&page=1`, [f.pull]);
  assert.equal((await preparationPulls(f.client))[0].number, 52);
  f.values.get(`/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}&per_page=100&page=1`).push({...f.pull, id: 53, number: 53});
  await assert.rejects(preparationPulls(f.client), /multiple open/);
});

test('App actor identity is obtained from the exact installation login', async () => {
  const value = await appActor({repository: 'tkersey/kosmos', repositoryId: 1251308461, appId: 1, login: actor.login}, async args => {
    assert.equal(args[1], 'users/kosmos-release%5Bbot%5D'); return Buffer.from(JSON.stringify({...actor, type: 'Bot'}));
  });
  assert.deepEqual(value, actor);
});

import {frozenKosmosCandidate} from './kosmos-release-observation.mjs';
for(const status of ['pending','running','complete'])test(`original ${status} candidate stays frozen across later discovery`,async()=>{
  const f=await fixture();const candidate=await frozenKosmosCandidate(f.pull,{commit:base},{readCandidate:async()=>f.candidate,
    readResult:async()=>({status}),qualification:async()=>assert.fail('active owner must remain authoritative')});
  assert.deepEqual(candidate,f.candidate);
});
test('only closed blocked owner or original terminal failed qualification permits fresh discovery',async()=>{
  const f=await fixture(),options={readCandidate:async()=>f.candidate,readResult:async()=>({status:'blocked',envelope:{epochClosed:true}})};
  assert.equal(await frozenKosmosCandidate(f.pull,{commit:base},options),null);
  options.readResult=async()=>({status:'absent'});options.qualification=async()=>({status:'completed',conclusion:'failure'});
  assert.equal(await frozenKosmosCandidate(f.pull,{commit:base},options),null);
  options.qualification=async()=>({status:'completed',conclusion:'success'});
  assert.deepEqual(await frozenKosmosCandidate(f.pull,{commit:base},options),f.candidate);
  await assert.rejects(frozenKosmosCandidate(f.pull,{commit:'f'.repeat(40)},options),/stale base/);
});

test('original prepared candidate stays frozen before its first PR is created',async()=>{
  const f=await fixture(),readPreparation=async value=>{assert.deepEqual(value,{base});return {candidate:f.candidate};};
  assert.deepEqual(await frozenKosmosCandidate(null,{commit:base},{readPreparation}),f.candidate);
  assert.equal(await frozenKosmosCandidate(null,{commit:base},{readPreparation:async()=>null}),null);
});


test('retirement binds original source and closure independently of edited explanatory prose', async () => {
  const f = await fixture();
  const envelope = {schema: 'repository-review-result/v1', context: {repository: 'tkersey/kosmos', base,
    head: f.candidate.head, tree: f.candidate.tree, pullNumber: 52}, status: 'blocked', reason: 'Original closed owner epoch.',
    epochClosed: true, turn: 1, previousSha256: null, stateSha256: null, retainedEvidence: null};
  f.setReview({status: 'blocked', bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 20}, artifact: {id: 21}});
  f.pull.body += 'Reviewed explanatory rationale.\n'; f.pull.title = 'Human explanatory title';
  assert.equal((await f.retire()).review.runId, 20);
});

test('retirement cannot substitute an unrelated described subject for the observed branch', async () => {
  const f = await fixture();
  f.pull.body = f.pull.body.replace(`Head: \`${f.candidate.head}\``, `Head: \`${'f'.repeat(40)}\``);
  await assert.rejects(f.retire(), /live branch differs/);
});
