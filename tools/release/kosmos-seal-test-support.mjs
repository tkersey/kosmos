import assert from 'node:assert/strict';
import {retainedFixture} from './promotion-test-support.mjs';
import {expectedReviewSettings} from './review-check.mjs';
import {kosmosFixture} from './kosmos-test-support.mjs';
import {reviewNames} from './review-result.mjs';
import {encodeRecord, sha256} from './encoding.mjs';

export function sealFixture() {
  const source = {commit: 'a'.repeat(40), tree: 'b'.repeat(40)}, subject = {base: 'd'.repeat(40), head: source.commit, tree: source.tree};
  const declaration = {impact: 'patch', disposition: 'compatible', rationale: 'Test declaration.', contracts: ['source']};
  const context = {repository: 'tkersey/kosmos', ...subject, pullNumber: 1};
  const retained = retainedFixture(context, expectedReviewSettings);
  const envelope = {schema: 'repository-review-result/v1', context, status: 'complete', epochClosed: true,
    reason: 'Test original result.', turn: 1, previousSha256: null, stateSha256: null,
    retainedEvidence: Buffer.from(JSON.stringify(retained)).toString('base64')};
  const bytes = Buffer.from(JSON.stringify(envelope));
  const result = {bytes, envelope, run: {id: 8, run_attempt: 1, head_sha: subject.base, head_branch: 'main',
    repository: {id: 1251308461}, head_repository: {id: 1251308461}, status: 'completed', conclusion: 'success',
    event: 'schedule', path: '.github/workflows/repository-review.yml', html_url: 'https://github.com/tkersey/kosmos/actions/runs/8'},
  job: {id: 9, name: 'Owner review', run_id: 8, run_attempt: 1, head_sha: subject.base, status: 'completed', conclusion: 'success',
    labels: ['ubuntu-24.04'], started_at: '2026-10-30T01:00:00Z', completed_at: '2026-10-30T01:09:00Z'},
  artifact: {id: 10, name: reviewNames(subject.base, subject.head).result, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    workflow_run: {id: 8, repository_id: 1251308461, head_repository_id: 1251308461, head_sha: subject.base}},
  workflow: {path: '.github/workflows/repository-review.yml', commit: subject.base, sha256: 'd'.repeat(64)}};
  const record = {schema: 'repository-publication-boundary/v1', repository: 'tkersey/kosmos', source, pendingVersion: '1.0.0',
    version: '1.0.0', status: 'ready', baseline: null, bootstrap: null, changes: [{subject, declaration, versionOnly: false,
      review: {runId: 8, artifactId: 10, sha256: sha256(bytes)}}]};
  const boundaryBytes = encodeRecord(record);
  const boundary = {status: 'ready', version: '1.0.0', record, bytes: boundaryBytes, sha256: sha256(boundaryBytes),
    reviewProvenance: new Map([[sha256(bytes), result]])};

  const native = kosmosFixture();
  Object.assign(native.inventory, {compilerSha256: 'f'.repeat(64), compilerPlatform: 'linux-x86_64'});
  native.payloads.set('source.json', Buffer.from(JSON.stringify(native.inventory)));

  for (const artifact of native.artifacts) {
    artifact.size_in_bytes = native.payloads.get(artifact.name).length;
    artifact.digest = 'sha256:' + sha256(native.payloads.get(artifact.name));
  }
  const workflow = {path: native.run.path, commit: native.commit, sha256: 'e'.repeat(64)};
  const qualification = {run: native.run, jobs: native.jobs, workflow,
    evidence: encodeRecord({run: native.run, jobs: native.jobs, artifacts: native.artifacts, workflowSha256: workflow.sha256}), payloads: native.payloads};
  return {boundary, qualification, manifestBytes: native.manifest, admission: {path: '.github/workflows/repository-release.yml', commit: source.commit, sha256: 'f'.repeat(64)},
    admitted: native.upstream, profileBytes: native.profileBytes,
    node: {name: 'node', version: '26.9.0', platform: 'linux-x86_64', sha256: 'e'.repeat(64)}};
}
