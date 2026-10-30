import assert from 'node:assert/strict';
import test from 'node:test';
import {assembleKosmos} from './kosmos-assemble.mjs';
import {readRecord} from './record.mjs';
import {kosmosFixture} from './kosmos-test-support.mjs';

function assemble(f) {
  const payloads = new Map(f.payloads); payloads.set('evidence.json', Buffer.from('synthetic review evidence'));
  return assembleKosmos(f.input, payloads, f.manifest, f.upstream, f.profileBytes);
}

test('assembly derives native source facts and exact Horos binding; final distributables retain their tested bytes', () => {
  const f = kosmosFixture(); f.input.source = null; f.input.tag = 'v99.0.0'; f.input.dependencies = null;
  const bytes = assemble(f), record = readRecord(bytes);
  assert.equal(record.tag, 'v1.0.0'); assert.equal(record.source.commit, f.commit);
  assert.equal(record.dependencies[0].source.packageIdentity, f.upstream[0].record.source.packageIdentity);
  assert.equal(record.dependencies[0].release.id, 3);
  assert.deepEqual(assemble(f), bytes);
  for (const artifact of record.artifacts.filter(value => value.role === 'runtime'))
    assert.equal(artifact.bytes, f.payloads.get(artifact.name).length);
});

for (const [name, mutate] of [
  ['missing publication', f => {f.upstream = [];}],
  ['ambiguous publication', f => {f.upstream.push(f.upstream[0]);}],
  ['missing original authentication', f => {f.upstream[0].admissionVerification = null;}],
  ['wrong upstream package', f => {f.upstream[0].record.source.packageIdentity = `horos-1.0.0-${'b'.repeat(44)}`;}],
  ['wrong upstream commit', f => {f.upstream[0].record.source.commit = 'd'.repeat(40); f.upstream[0].record.qualification.run.commit = 'd'.repeat(40); f.upstream[0].record.review.landing.commit = 'd'.repeat(40);}],
  ['manifest mutation', f => {f.manifest = Buffer.from('wrong');}],
  ['profile mutation', f => {f.profileBytes = Buffer.from('{}');}],
  ['source archive corruption', f => {f.payloads.set('source.tar', Buffer.from('changed'));}],
  ['final npm mutation', f => {f.payloads.set('kosmos-runtime-package.tar.gz', Buffer.from('changed'));}],
  ['missing final artifact', f => {f.input.artifacts.pop();}],
  ['wrong qualified head', f => {f.input.qualification.run.commit = 'd'.repeat(40);}],
]) test(`assembly rejects ${name}`, () => {
  const f = kosmosFixture(); mutate(f); assert.throws(() => assemble(f));
});
