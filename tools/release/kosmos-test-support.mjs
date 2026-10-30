import {createHash} from 'node:crypto';
import {metadata} from './test-support.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {kosmosJobs} from './kosmos-qualification.mjs';

export function kosmosFixture() {
  const input = metadata('kosmos'), upstreamRecord = metadata('horos');
  const commit = input.source.commit, tree = input.source.tree;
  const manifest = Buffer.from(`.{ .version = "1.0.0", .dependencies = .{ .horos = .{ .url = "git+https://github.com/tkersey/horos#${commit}", .hash = "${upstreamRecord.source.packageIdentity}" } } }\n`);
  const archive = Buffer.from('synthetic adapter archive, not native authentication');
  const profile = {zig: '0.17.0', target: 'wasm32-freestanding', hostMode: 'safe', kernelMode: 'small',
    wasmBackend: 'llvm', wasmLinker: 'lld', cpu: 'lime1', features: ['bulk_memory_opt'], stackBytes: 65536, maximumMemoryBytes: 268435456};
  const profileBytes = Buffer.from(JSON.stringify(profile));
  const generated = {target: profile.target, mode: profile.kernelMode, backend: profile.wasmBackend, linker: profile.wasmLinker,
    cpu: profile.cpu, features: profile.features, stackBytes: profile.stackBytes, maximumMemoryBytes: profile.maximumMemoryBytes};
  const inventory = {commit, tree, archive: 'source.tar', sha256: sha256(archive), size: archive.length,
    packageIdentity: input.source.packageIdentity, compiler: '0.17.0',
    files: [['build.zig.zon', manifest], ['build-profile.json', profileBytes]].map(([path, bytes]) => ({
      path, mode: 0o644, blob: createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')})),
    manifest: {sha256: sha256(manifest), version: '1.0.0', minimumCompiler: '0.17.0', horos: {
      url: `git+https://github.com/tkersey/horos#${commit}`, commit, packageIdentity: upstreamRecord.source.packageIdentity}}};
  const payloads = new Map([['source.tar', archive], ['source.json', Buffer.from(JSON.stringify(inventory))],
    ['kosmos-runtime-package.tar.gz', Buffer.from('synthetic final npm payload')], ['kosmos-kernel.wasm', Buffer.from('synthetic final wasm')],
    ['kernel-profile.json', Buffer.from(JSON.stringify(generated))]]);
  const runtime = {schema: 'kosmos-runtime/v1', version: '1.0.0', compiler: '0.17.0', profile: generated,
    artifacts: ['kosmos-runtime-package.tar.gz', 'kosmos-kernel.wasm', 'kernel-profile.json'].map(name => ({name,
      bytes: payloads.get(name).length, sha256: sha256(payloads.get(name))}))};
  payloads.set('runtime.json', Buffer.from(JSON.stringify(runtime)));
  input.artifacts[1].name = 'source.json';
  for (const [name, role] of [['kosmos-runtime-package.tar.gz', 'runtime'], ['kosmos-kernel.wasm', 'runtime'], ['kernel-profile.json', 'evidence'], ['runtime.json', 'evidence']])
    input.artifacts.push({name, role, platform: null, bytes: 1, sha256: 'c'.repeat(64)});
  const upstream = [{id: 3, record: upstreamRecord, recordSha256: sha256(encodeRecord(upstreamRecord)),
    admissionVerification: Buffer.from('synthetic authentication fixture')}];
  const run = {id: 17, repository: {id: 1251308461}, head_repository: {id: 1251308461},
    path: '.github/workflows/runtime-bundle.yml', head_sha: commit, event: 'push', head_branch: 'main',
    run_attempt: 1, status: 'completed', conclusion: 'success', workflow_id: 23,
    created_at: '2026-10-30T00:00:00Z', run_started_at: '2026-10-30T00:00:00Z'};
  const jobs = Object.entries(kosmosJobs).map(([name, steps], index) => {
    const minutes = name === 'Complete qualification' ? [7,8] : name === 'Runtime qualification budget' ? [5,6] : name === 'TigerStyle' ? [0,7] : [0,5];
    const time = minute => `2026-10-30T00:0${minute}:00Z`;
    return {id: index + 50, name, run_id: run.id, run_attempt: 1, head_sha: commit, status: 'completed', conclusion: 'success',
      started_at: time(minutes[0]), completed_at: time(minutes[1]), labels: ['ubuntu-24.04'],
      steps: steps.map(name => ({name, status: 'completed', conclusion: 'success', started_at: time(minutes[0]), completed_at: time(minutes[1])}))};
  });
  const artifacts = [...payloads].map(([name, bytes], index) => ({id: index + 80, name, expired: false,
    size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    workflow_run: {id: run.id, repository_id: 1251308461, head_repository_id: 1251308461, head_sha: commit}}));
  const content = bytes => ({type: 'file', encoding: 'base64', content: bytes.toString('base64')});
  const replies = new Map([
    ['repos/tkersey/kosmos', {full_name: 'tkersey/kosmos', id: 1251308461, default_branch: 'main'}],
    ['repos/tkersey/kosmos/actions/runs/17', run],
    [`repos/tkersey/kosmos/actions/workflows/runtime-bundle.yml/runs?head_sha=${commit}&event=push&per_page=100&page=1`, {workflow_runs: [run]}],
    ['repos/tkersey/kosmos/actions/workflows/23', {path: run.path}],
    [`repos/tkersey/kosmos/contents/${run.path}?ref=${commit}`, content(Buffer.from('synthetic workflow'))],
    [`repos/tkersey/kosmos/contents/build-profile.json?ref=${commit}`, content(profileBytes)],
    ['repos/tkersey/kosmos/actions/runs/17/attempts/1/jobs?per_page=100&page=1', {jobs}],
    ['repos/tkersey/kosmos/actions/runs/17/artifacts?per_page=100&page=1', {artifacts}],
    [`repos/tkersey/kosmos/git/commits/${commit}`, {sha: commit, tree: {sha: tree}}],
    ...artifacts.map(artifact => [`repos/tkersey/kosmos/actions/artifacts/${artifact.id}/zip`, payloads.get(artifact.name)]),
  ]);
  const command = async args => {
    if (!replies.has(args[1])) throw new Error(`unexpected API: ${args[1]}`);
    const value = replies.get(args[1]); return Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  };
  return {input, upstream, manifest, profile, profileBytes, inventory, runtime, payloads, run, jobs, artifacts, replies, command, commit, tree};
}
