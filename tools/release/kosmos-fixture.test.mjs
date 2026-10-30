import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {readRecord} from './record.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

const load = name => readFileSync(new URL(`../../test/fixtures/release/horos/${name}`, import.meta.url));
function validate(recordBytes, inventoryBytes, manifest, evidence) {
  const record = readRecord(recordBytes), inventory = parseEvidenceJson(inventoryBytes);
  assert.equal(record.repository.name, 'tkersey/horos');
  assert.equal(record.source.commit, inventory.commit); assert.equal(record.source.tree, inventory.tree);
  assert.equal(record.source.packageIdentity, inventory.packageIdentity);
  assert.equal(record.source.manifestSha256, sha256(manifest));
  assert.equal(record.artifacts.find(item => item.role === 'source').sha256, inventory.sha256);
  const file = inventory.files.find(item => item.path === 'build.zig.zon');
  assert.equal(file.blob, createHash('sha1').update(`blob ${manifest.length}\0`).update(manifest).digest('hex'));
  for (const [name, bytes] of [['source.json', inventoryBytes], ['evidence.json', evidence]]) {
    const item = record.artifacts.find(item => item.name === name);
    assert.equal(item.bytes, bytes.length); assert.equal(item.sha256, sha256(bytes));
  }
  return record;
}

test('Kosmos reads exact frozen Horos producer bytes without a shared schema package', () => {
  const record = validate(load('horos-v1.json'), load('source.json'), load('build.zig.zon.txt'), load('evidence.json'));
  assert.equal(record.source.commit, '2fbcc41c98887bcd6ece56060d263730394b1bc6');
  assert.equal(record.source.packageIdentity, 'horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU');
  assert.match(record.compatibility.rationale, /synthetic/);
});

for (const name of ['tree', 'package', 'manifest', 'inventory', 'evidence', 'future-schema', 'duplicate-key']) test(`frozen producer corruption rejects ${name}`, () => {
  let record = load('horos-v1.json'), inventory = load('source.json'), manifest = load('build.zig.zon.txt'), evidence = load('evidence.json');
  if (name === 'tree' || name === 'package' || name === 'future-schema') {
    const value = JSON.parse(record);
    if (name === 'tree') value.source.tree = 'd'.repeat(40);
    if (name === 'package') value.source.packageIdentity = `horos-8.0.0-${'a'.repeat(44)}`;
    if (name === 'future-schema') value.schema = 'repository-release/v2';
    record = encodeRecord(value);
  }
  if (name === 'duplicate-key') record = Buffer.from(record.toString().replace('"schema":', '"schema":"repository-release/v2","schema":'));
  if (name === 'manifest') manifest = Buffer.concat([manifest, Buffer.from(' ')]);
  if (name === 'inventory') inventory = Buffer.concat([inventory, Buffer.from(' ')]);
  if (name === 'evidence') evidence = Buffer.from('changed');
  assert.throws(() => validate(record, inventory, manifest, evidence));
});

test('real Kosmos native producer preserves the exact Horos publication binding across schema copies', () => {
  const own = name => readFileSync(new URL(`../../test/fixtures/release/kosmos/${name}`, import.meta.url));
  const source = parseEvidenceJson(own('source.json')), upstream = readRecord(load('horos-v1.json'));
  assert.equal(source.commit, '2b8ee91d09ee8c728574d997b3f127e92f4f41bd');
  assert.equal(source.tree, 'a828641ec3f18bee7f0ef4cfa726c7d308f8ffd1');
  assert.equal(source.sha256, 'a1ecf33292cc1eed106fbac2a7b77b66cd88f05282e51040d1526c5529e17e9b');
  assert.equal(source.size, 3774976); assert.equal(source.manifest.version, '9.1.1');
  assert.equal(source.manifest.horos.commit, upstream.source.commit);
  assert.equal(source.manifest.horos.packageIdentity, upstream.source.packageIdentity);
  assert.equal(source.manifest.sha256, sha256(own('build.zig.zon.txt')));
  for (const [name, path] of [['build.zig.zon.txt', 'build.zig.zon'], ['build-profile.json', 'build-profile.json']]) {
    const bytes = own(name), entry = source.files.find(file => file.path === path);
    assert.equal(entry.mode, 0o644);
    assert.equal(entry.blob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
  }
});
