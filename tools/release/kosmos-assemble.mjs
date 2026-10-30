import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {parseEvidenceJson} from './evidence-json.mjs';
import {sha256} from './encoding.mjs';
import {produceRecord, validateRecord} from './record.mjs';
import {validateKosmosPayloads} from './kosmos-qualification.mjs';

export function assembleKosmos(metadata, payloads, manifestBytes, admittedHoros, profileBytes) {
  assert.equal(metadata.repository.name, 'tkersey/kosmos');
  assert.ok(Buffer.isBuffer(manifestBytes) && manifestBytes.length <= 1024 * 1024);
  assert.ok(Buffer.isBuffer(profileBytes));
  const inventory = parseEvidenceJson(payloads.get('source.json'));
  validateKosmosPayloads(payloads, {commit: inventory.commit, tree: inventory.tree, profile: parseEvidenceJson(profileBytes)});
  assert.ok(Array.isArray(inventory.files) && inventory.files.length > 0 && inventory.files.length <= 10000);
  assert.equal(new Set(inventory.files.map(file => file.path)).size, inventory.files.length, 'duplicate source inventory');
  for (const [path, bytes] of [['build.zig.zon', manifestBytes], ['build-profile.json', profileBytes]]) {
    const entries = inventory.files.filter(file => file.path === path);
    assert.equal(entries.length, 1, 'missing unique source definition');
    assert.equal(entries[0].mode, 0o644);
    const blob = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
    assert.equal(entries[0].blob, blob, 'source definition differs from native inventory');
  }
  assert.equal(inventory.manifest.sha256, sha256(manifestBytes), 'native manifest facts differ');
  assert.equal(inventory.manifest.minimumCompiler, '0.17.0');
  const version = inventory.manifest.version;
  assert.match(inventory.packageIdentity, /^kosmos-(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-[A-Za-z0-9_-]{44}$/);
  assert.ok(inventory.packageIdentity.startsWith(`kosmos-${version}-`));
  assert.ok(Array.isArray(admittedHoros) && admittedHoros.length === 1, 'exactly one admitted Horos publication required');
  const upstream = admittedHoros[0];
  validateRecord(upstream.record);
  assert.equal(upstream.record.repository.name, 'tkersey/horos');
  assert.ok(Number.isSafeInteger(upstream.id) && upstream.id > 0);
  assert.match(upstream.recordSha256, /^[0-9a-f]{64}$/);
  assert.ok(Buffer.isBuffer(upstream.admissionVerification) && upstream.admissionVerification.length > 0, 'missing original publication authentication');
  assert.equal(inventory.manifest.horos.url, `git+https://github.com/tkersey/horos#${upstream.record.source.commit}`);
  assert.equal(inventory.manifest.horos.commit, upstream.record.source.commit);
  assert.equal(inventory.manifest.horos.packageIdentity, upstream.record.source.packageIdentity);
  const source = {commit: inventory.commit, tree: inventory.tree, version,
    manifestSha256: sha256(manifestBytes), packageIdentity: inventory.packageIdentity, lockSha256: null};
  const dependencies = [{repository: upstream.record.repository, source: upstream.record.source,
    release: {id: upstream.id, tag: upstream.record.tag, recordSha256: upstream.recordSha256}}];
  const required = {'source.tar': 'source', 'source.json': 'inventory', 'kosmos-runtime-package.tar.gz': 'runtime',
    'kosmos-kernel.wasm': 'runtime', 'kernel-profile.json': 'evidence', 'runtime.json': 'evidence'};
  for (const [name, role] of Object.entries(required)) {
    const artifacts = metadata.artifacts.filter(artifact => artifact.name === name);
    assert.equal(artifacts.length, 1, `missing unique final artifact: ${name}`); assert.equal(artifacts[0].role, role);
  }
  return produceRecord({...metadata, source, tag: `v${version}`, dependencies}, payloads);
}

export async function assemblePublishedKosmos({metadata, payloads, manifestBytes, profileBytes, horosReleaseId, upstreamDirectory}, command) {
  const {admitPublishedRelease} = await import('./release-admission.mjs');
  const admitted = await admitPublishedRelease({repository: 'tkersey/horos', releaseId: horosReleaseId,
    outputDirectory: upstreamDirectory}, command);
  return assembleKosmos(metadata, payloads, manifestBytes, [admitted], profileBytes);
}
