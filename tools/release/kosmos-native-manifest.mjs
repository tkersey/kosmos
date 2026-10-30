import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, realpathSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {parseVersion} from './version.mjs';
import {nativeInvocation} from './kosmos-prepare.mjs';

export function manifestOperations(toolPath, compilerPath) {
  const tool = {path: realpathSync(toolPath)}, compiler = {path: realpathSync(compilerPath)};
  const toolDigest = sha256(readFileSync(tool.path)), compilerDigest = sha256(readFileSync(compiler.path));
  const facts = bytes => {
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1024 * 1024);
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'kosmos-manifest-')));
    try {
      for (const name of ['home', 'tmp']) mkdirSync(join(root, name), {mode: 0o700});
      const path = join(root, 'build.zig.zon'); writeFileSync(path, bytes, {flag: 'wx', mode: 0o400});
      assert.equal(sha256(readFileSync(tool.path)), toolDigest, 'trusted native parser changed');
      assert.equal(sha256(readFileSync(compiler.path)), compilerDigest, 'trusted native compiler changed');
      const invocation = nativeInvocation({tool, compiler, root, args: ['manifest', compiler.path, root], readOnlyPaths: [path]});
      const value = parseEvidenceJson(execFileSync(invocation.file, invocation.args,
        {cwd: root, env: invocation.env, timeout: 30000, maxBuffer: 1024 * 1024, encoding: 'buffer'}));
      assert.equal(value.sha256, sha256(bytes)); assert.equal(value.minimumCompiler, '0.17.0');
      parseVersion(value.version); return value;
    } finally {rmSync(root, {recursive: true, force: true});}
  };
  return {sha256: toolDigest, compilerSha256: compilerDigest, facts, read: bytes => facts(bytes).version};
}

export async function sourceManifest(client, commit) {
  assert.match(commit, /^[0-9a-f]{40}$/);
  const response = await client.request({path: `/contents/build.zig.zon?ref=${commit}`});
  assert.equal(response.status, 200);
  const value = response.body;
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  const bytes = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
  assert.ok(bytes.length > 0 && bytes.length <= 1024 * 1024);
  assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), value.sha, 'manifest Git blob differs');
  return bytes;
}

export function classifyNativeVersion({client, native, actor, command}) {
  return async ({subject, pull, baseTree, baseManifestBytes, manifestBytes, originalCommits}) => {
    if (!actor || pull.user?.id !== actor.id || pull.user?.login !== actor.login || originalCommits.length !== 1 ||
      typeof pull.body !== 'string' || !pull.body.startsWith('<!-- repository-proposal/v1 ')) return {versionOnly:false};
    const {readKosmosPreparation} = await import('./kosmos-preparation-artifact.mjs');
    const {proposalDescription} = await import('./kosmos-proposal.mjs');
    const original = await readKosmosPreparation({base:subject.base,head:subject.head},command);
    assert.ok(original,'original native preparation required for version-only classification');
    const candidate=original.candidate;
    assert.equal(candidate.baseTree,baseTree);assert.equal(candidate.tree,subject.tree);
    assert.equal(pull.body,proposalDescription(candidate).body,'native proposal body changed');
    assert.equal(originalCommits[0].message,candidate.message);
    assert.deepEqual(candidate.files.get('build.zig.zon'),manifestBytes);
    const base=native.facts(baseManifestBytes),after=native.facts(manifestBytes);
    assert.equal(after.version,candidate.version);
    return {versionOnly:base.version!==after.version && base.horos.commit===candidate.horos.commit &&
      base.horos.packageIdentity===candidate.horos.packageIdentity};
  };
}
