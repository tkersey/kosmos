import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink, chmod, stat, rename, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inventory, sha256, verifyInventory, readVerifiedFile,
  withVerifiedInventory } from "../../src/node/runtime-bundle.mjs";
import runtimeProfile from "../../src/node/runtime-profile.json" with { type: "json" };

import { reserveOutput } from "../../src/node/runtime-output.mjs";
async function area(t) { const root=await mkdtemp(join(tmpdir(), "kosmos output ")); t.after(()=>rm(root,{recursive:true,force:true})); return root; }

const required = ["runtime/world-kernel.wasm", "runtime/package.json", "runtime/bin/world.mjs",
  "runtime/src/node/runtime-bundle.mjs", "runtime/src/node/runtime-profile.json",
  "runtime/src/embedding/index.mjs", "qualification.json",
  "runtime/LICENSE", "smoke/pure.bpi3", "smoke/effect.bpi3"];
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "kosmos bundle "));
  t.after(() => rm(root, { recursive: true, force: true }));
  for (const file of required) {
    await mkdir(join(root, file, ".."), { recursive: true });
    await writeFile(join(root, file), "fixture");
  }
  const manifest = { format: "world-runtime-bundle/v1", files: await inventory(root) };
  const seal = async () => {
    const bytes = JSON.stringify(manifest);
    await writeFile(join(root, "manifest.json"), bytes);
    return sha256(bytes);
  };
  return { root, manifest, seal, hash: await seal() };
}
test("external identity and complete file inventory survive spaces", async t => {
  const f = await fixture(t);
  await verifyInventory(f.root, f.hash);
  await assert.rejects(verifyInventory(f.root, "0".repeat(64)), { code: "WORLD_BUNDLE_IDENTITY_INVALID" });
  await writeFile(join(f.root, "runtime/src/node/runtime-bundle.mjs"), "substituted");
  await assert.rejects(verifyInventory(f.root, f.hash), { code: "WORLD_BUNDLE_CORRUPT" });
});

test("executable mode is bound before admission and preserved in the private snapshot", async t => {
  const f = await fixture(t), path = join(f.root, "runtime/bin/world.mjs");
  const original = (await stat(path)).mode & 0o777;
  await chmod(path, original ^ 0o100);
  await assert.rejects(verifyInventory(f.root, f.hash), {code:"WORLD_BUNDLE_CORRUPT"});
  await chmod(path, original);
  await verifyInventory(f.root, f.hash);
  await withVerifiedInventory(f.root, f.hash, async copy => {
    await chmod(path, original ^ 0o100);
    assert.equal(((await stat(join(copy, "runtime/bin/world.mjs"))).mode & 0o111) !== 0, (original & 0o111) !== 0);
  });
});
test("missing and additional modules reject", async t => {
  const f = await fixture(t);
  await writeFile(join(f.root, "runtime/extra.mjs"), "unexpected");
  await assert.rejects(verifyInventory(f.root, f.hash), { code: "WORLD_BUNDLE_CORRUPT" });
  await rm(join(f.root, "runtime/extra.mjs"));
  await rm(join(f.root, "runtime/world-kernel.wasm"));
  await assert.rejects(verifyInventory(f.root, f.hash), { code: "WORLD_BUNDLE_CORRUPT" });
});

test("metadata reads bind the parsed generation to its inventory record", async t => {
  const f = await fixture(t);
  for (const path of ["qualification.json", "runtime/package.json"]) {
    await writeFile(join(f.root, path), '{"status":"skipped"}');
    f.manifest.files = (await inventory(f.root)).filter(file => file.path !== "manifest.json");
    const manifest = await verifyInventory(f.root, await f.seal());
    assert.equal(JSON.parse(await readVerifiedFile(f.root, manifest, path)).status, "skipped");
    // Same-length replacement after the inventory scan must not become evidence.
    await writeFile(join(f.root, path), '{"status":"passed!"}');
    await assert.rejects(readVerifiedFile(f.root, manifest, path), {code: "WORLD_BUNDLE_CORRUPT"});
  }
});

test("verified copy executes captured code and retains metadata after source replacement", async t => {
  const { execFileSync } = await import("node:child_process");
  const { readFile, chmod, access } = await import("node:fs/promises");
  const f = await fixture(t);
  const cli = join(f.root, "runtime/bin/world.mjs");
  await writeFile(cli, '#!/usr/bin/env node\nconsole.log("original generation");\n');
  await chmod(cli, 0o755);
  await writeFile(join(f.root, "runtime/package.json"), '{"type":"module"}');
  await writeFile(join(f.root, "qualification.json"), '{"status":"original"}');
  f.manifest.files = (await inventory(f.root)).filter(file => file.path !== "manifest.json");
  let copiedRoot;
  await withVerifiedInventory(f.root, await f.seal(), async copy => {
    copiedRoot = copy;
    assert.notEqual(copy, f.root);
    await writeFile(cli, '#!/usr/bin/env node\nconsole.log("replacement generation");\n');
    await writeFile(join(f.root, "qualification.json"), '{"status":"replacement"}');
    const copiedCli = join(copy, "runtime/bin/world.mjs");
    assert.equal(execFileSync(process.execPath, [copiedCli], {encoding: "utf8"}).trim(),
      "original generation");
    if (process.platform !== "win32")
      assert.equal(execFileSync(copiedCli, [], {encoding: "utf8"}).trim(), "original generation");
    assert.equal(JSON.parse(await readFile(join(copy, "qualification.json"))).status, "original");
  });
  await assert.rejects(access(copiedRoot), {code: "ENOENT"});
});
test("traversal, duplicate entries, and links reject", async t => {
  const f = await fixture(t);
  f.manifest.files.push(f.manifest.files[0]);
  await assert.rejects(verifyInventory(f.root, await f.seal()), { code: "WORLD_BUNDLE_INVALID" });
  f.manifest.files.pop();
  f.manifest.files[0].path = "../escape";
  await assert.rejects(verifyInventory(f.root, await f.seal()), { code: "WORLD_BUNDLE_INVALID" });
  await symlink(tmpdir(), join(f.root, "link"));
  await assert.rejects(inventory(f.root), { code: "WORLD_BUNDLE_INVALID" });
});

test("safe acquisition binds archive before extraction and refuses destination collision", async t => {
  const { execFileSync } = await import("node:child_process");
  const { readFile } = await import("node:fs/promises");
  const { acquireBundle, unpackArchive } = await import("../../src/node/runtime-acquire.mjs");
  const f = await fixture(t);
  const scratch = await mkdtemp(join(tmpdir(), "kosmos acquisition "));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const archive = join(scratch, "bundle.tar.gz"), output = join(scratch, "relocated bundle");
  const {chmod,stat} = await import("node:fs/promises");
  await writeFile(join(f.root,"runtime/bin/world.mjs"),'#!/usr/bin/env node\nconsole.log("acquired CLI");\n');
  await writeFile(join(f.root,"runtime/package.json"),'{"type":"module"}');
  await chmod(join(f.root,"runtime/bin/world.mjs"),0o755);
  f.manifest.files=(await inventory(f.root)).filter(file=>file.path!=="manifest.json");
  f.hash=await f.seal();
  execFileSync("tar", ["--format=ustar", "-czf", archive, "-C", f.root, "."]);
  const bytes = await readFile(archive), digest = sha256(bytes);
  await assert.rejects(acquireBundle(archive, "0".repeat(64), f.hash, output), { code: "WORLD_BUNDLE_IDENTITY_INVALID" });
  await acquireBundle(archive, digest, f.hash, output);
  await verifyInventory(output, f.hash);
  if(process.platform!=="win32"){
    assert.ok((await stat(join(output,"runtime/bin/world.mjs"))).mode & 0o100);
    assert.equal(execFileSync(join(output,"runtime/bin/world.mjs"),[],{encoding:"utf8"}).trim(),"acquired CLI");
  }
  await assert.rejects(acquireBundle(archive, digest, f.hash, output), { code: "WORLD_BUNDLE_COLLISION" });
  await symlink("/tmp", join(f.root, "escape"));
  execFileSync("tar", ["--format=ustar", "-czf", archive, "-C", f.root, "."]);
  const badArchive = await readFile(archive);
  assert.throws(() => unpackArchive(badArchive), { code: "WORLD_BUNDLE_ARCHIVE_INVALID" });
});

test("bundle mode normalization preserves executable intent and safe archive round trips", async t => {
  const { execFileSync } = await import("node:child_process");
  const { readFile } = await import("node:fs/promises");
  const { acquireBundle, unpackArchive } = await import("../../src/node/runtime-acquire.mjs");
  const f = await fixture(t), file = "runtime/bin/world.mjs";
  const scratch = await mkdtemp(join(tmpdir(), "kosmos archive modes "));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  for (const [mode, delivered] of [[0o600, 0o644], [0o640, 0o644], [0o664, 0o644],
    [0o601, 0o755], [0o610, 0o755], [0o700, 0o755], [0o750, 0o755],
    [0o777, 0o755], [0o4755, 0o755]]) {
    await chmod(join(f.root, file), mode);
    assert.equal((await stat(join(f.root, file))).mode & 0o777, mode & 0o777);
    f.manifest.files = (await inventory(f.root)).filter(entry => entry.path !== "manifest.json");
    assert.equal(f.manifest.files.find(entry => entry.path === file).mode, delivered);
    const hash = await f.seal();
    await verifyInventory(f.root, hash);
    const archive = join(scratch, `${mode}.tar.gz`), output = join(scratch, `${mode}`);
    execFileSync("tar", ["--format=ustar", "-czf", archive, "-C", f.root, "."]);
    const bytes = await readFile(archive);
    assert.equal(unpackArchive(bytes).find(entry => entry.path === file).mode, delivered);
    await acquireBundle(archive, sha256(bytes), hash, output);
    assert.equal((await stat(join(output, file))).mode & 0o7777, delivered,
      "extraction cannot restore set-id or group/other write permissions");
    await withVerifiedInventory(output, hash, async copy => {
      assert.equal((await stat(join(copy, file))).mode & 0o777,
        delivered === 0o755 ? 0o500 : 0o400);
      await verifyInventory(copy, hash);
    });
    await chmod(join(output, file), delivered === 0o755 ? 0o644 : 0o755);
    await assert.rejects(verifyInventory(output, hash), { code: "WORLD_BUNDLE_CORRUPT" });
  }
});

test("archive acquisition survives restrictive and shared-group producer umasks", async () => {
  const { spawnSync } = await import("node:child_process");
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  for (const mask of ["002", "027", "077"]) {
    const run = spawnSync("/bin/sh", ["-c", 'umask "$1"; shift; exec "$@"', "kosmos-umask-test", mask,
      process.execPath, "--test", "--test-reporter=tap",
      "--test-name-pattern=^safe acquisition binds archive before extraction and refuses destination collision$",
      import.meta.filename], { env, encoding: "utf8", timeout: 20_000 });
    assert.equal(run.status, 0, `umask ${mask}: ${run.error ?? ""}\n${run.stdout}\n${run.stderr}`);
    assert.match(run.stdout, /^# tests 1$/m);
    assert.match(run.stdout, /^# pass 1$/m);
  }
});

test("manifest modes must describe the canonical delivery representation", async t => {
  const f = await fixture(t);
  for (const mode of [0o600, 0o775]) {
    f.manifest.files[0].mode = mode;
    await assert.rejects(verifyInventory(f.root, await f.seal()), { code: "WORLD_BUNDLE_INVALID" });
  }
});

test("unsupported profile and unexecuted qualification cannot pass", async t => {
  const { verifyBundle, requiredChecks } = await import("../../src/node/runtime-bundle.mjs");
  const f = await fixture(t);
  await assert.rejects(verifyBundle(f.root, f.hash), { code: "WORLD_BUNDLE_INCOMPATIBLE" });
  f.manifest.kernel = { abi: 3, path: "runtime/world-kernel.wasm" };
  f.manifest.packageVersion = "6.0.0";
  f.manifest.build = { target: runtimeProfile.target, kernelMode: runtimeProfile.kernelMode, zig: runtimeProfile.zig,
    hostMode: runtimeProfile.hostMode, stackBytes: runtimeProfile.stackBytes, maximumMemoryBytes: runtimeProfile.maximumMemoryBytes,
    defaults: {...runtimeProfile.defaults}, backend: runtimeProfile.wasmBackend, linker: runtimeProfile.wasmLinker,
    cpu: runtimeProfile.cpu, features: [...runtimeProfile.features], toolchain: {version:runtimeProfile.zig,executableIdentity:{sha256:"d".repeat(64)},libraryInventorySha256:"e".repeat(64)} };
  f.manifest.source = {repository:"https://github.com/tkersey/world",commit:"a".repeat(40),tree:"b".repeat(40),clean:true,
    dependency:{...runtimeProfile.boundary,lockSha256:"c".repeat(64)}};
  await writeFile(join(f.root,"runtime/package.json"), JSON.stringify({name:"@tkersey/world",version:"6.0.0",type:"module",exports:{".":"./src/embedding/index.mjs"},bin:{world:"./bin/world.mjs"}}));
  f.manifest.requiredChecks = requiredChecks;
  await writeFile(join(f.root, "qualification.json"), JSON.stringify({ checks: requiredChecks.map(name => ({ name, status: "skipped" })) }));
  f.manifest.files = (await inventory(f.root)).filter(file => file.path !== "manifest.json");
  await assert.rejects(verifyBundle(f.root, await f.seal()), { code: "WORLD_BUNDLE_INCOMPLETE" });
  const valid = structuredClone(f.manifest);
  for (const mutate of [
    m => {m.build.zig="0.17.0-dev.1";}, m => {m.build.hostMode="unknown";}, m => {m.build.kernelMode="fast";},
    m => {m.build.target="wasm64-freestanding";}, m => {m.build.stackBytes++;}, m => {m.build.maximumMemoryBytes++;},
    m => {m.build.defaults.working++;}, m => {m.build.backend="unknown";}, m => {m.build.linker="unknown";},
    m => {m.build.cpu="unknown";}, m => {m.source.dependency.commit="0".repeat(40);},
    m => {m.build.features.push("unknown");},
    m => {m.source.dependency.inventorySha256="0".repeat(64);}, m => {m.build.toolchain.libraryInventorySha256="unknown";},
  ]) {
    Object.assign(f.manifest, structuredClone(valid));
    mutate(f.manifest);
    await assert.rejects(verifyBundle(f.root, await f.seal()), {code:"WORLD_BUNDLE_INCOMPATIBLE"});
  }
});

test("worker entry detection survives ancestor aliases and importing stays inert", async t => {
  const { spawnSync } = await import("node:child_process");
  const { resolve } = await import("node:path");
  const { pathToFileURL } = await import("node:url");
  const root = await mkdtemp(join(tmpdir(), "kosmos worker alias "));
  t.after(() => rm(root, {recursive:true,force:true}));
  const repo = resolve(import.meta.dirname,"../..");
  await symlink(repo,join(root,"source alias"),"dir");
  for(const source of [repo,join(root,"source alias")]){
    const worker=join(source,"src/node/runtime-smoke.mjs");
    const result=spawnSync(process.execPath,[worker,join(root,"missing bundle"),"0".repeat(64),"start"],{encoding:"utf8",timeout:30000});
    assert.notEqual(result.status,0,"a direct worker must execute and reject the missing kernel, never silently skip");
    assert.match(result.stderr,/ENOENT/);
    const imported=spawnSync(process.execPath,["--input-type=module","-e",`await import(${JSON.stringify(pathToFileURL(worker).href)})`],{encoding:"utf8",timeout:30000});
    assert.equal(imported.status,0,imported.stderr);assert.equal(imported.stdout,"");
  }
});

test("authenticated inventories cannot omit the runtime profile", async t => {
  const f = await fixture(t), path = "runtime/src/node/runtime-profile.json";
  await rm(join(f.root, path));
  f.manifest.files = f.manifest.files.filter(file => file.path !== path);
  await assert.rejects(verifyInventory(f.root, await f.seal()), { code: "WORLD_BUNDLE_INCOMPLETE" });
});

test('reservation cleanup follows its selected parent and rejects directory replacement', async t => {
  const root = await area(t), first = join(root, 'first'), second = join(root, 'second'), alias = join(root, 'parent alias');
  await mkdir(first); await mkdir(second); await symlink(first, alias, 'dir');
  const reservation = await reserveOutput(join(alias, 'output'));
  await mkdir(join(second, 'output.preparing'));
  await writeFile(join(second, 'output.preparing/sentinel'), 'keep');
  await unlink(alias); await symlink(second, alias, 'dir');
  await reservation.cleanup();
  assert.equal(await readFile(join(second, 'output.preparing/sentinel'), 'utf8'), 'keep');
  const replaced = await reserveOutput(join(root, 'replacement'));
  await rename(replaced.stage, join(root, 'old owned stage'));
  await mkdir(replaced.stage);
  await writeFile(join(replaced.stage, 'sentinel'), 'keep');
  await assert.rejects(replaced.cleanup(), {code:'WORLD_BUNDLE_OUTPUT_CHANGED'});
  await assert.rejects(replaced.cleanup(), {code:'WORLD_BUNDLE_OUTPUT_CHANGED'});
  assert.equal(await readFile(join(replaced.stage, 'sentinel'), 'utf8'), 'keep');
});


test('reservation initialization failures release an empty stage and close opened handles', async t => {
  const { execFileSync } = await import('node:child_process');
  const root = await area(t), moduleUrl = new URL('../../src/node/runtime-output.mjs', import.meta.url).href;
  for (const failure of ['open', 'stat', 'replacement']) {
    const output = join(root, failure);
    execFileSync(process.execPath, ['--input-type=module', '-e', `
      import assert from 'node:assert/strict';
      import fs from 'node:fs';
      import { syncBuiltinESMExports } from 'node:module';
      const output = ${JSON.stringify(output)}, failure = ${JSON.stringify(failure)};
      const original = fs.promises.open;
      let closed = false;
      fs.promises.open = async (...args) => {
        if (failure === 'replacement') {
          await fs.promises.rename(args[0], args[0] + '.initial');
          await fs.promises.mkdir(args[0]);
          await fs.promises.writeFile(args[0] + '/sentinel', 'keep');
          throw Object.assign(new Error('injected replacement'), { code: 'EMFILE' });
        }
        if (failure === 'open') throw Object.assign(new Error('injected open'), { code: 'EMFILE' });
        const handle = await original(...args), close = handle.close.bind(handle);
        handle.stat = async () => { throw Object.assign(new Error('injected stat'), { code: 'EIO' }); };
        handle.close = async () => { closed = true; return close(); };
        return handle;
      };
      syncBuiltinESMExports();
      const { reserveOutput } = await import(${JSON.stringify(moduleUrl)});
      await assert.rejects(reserveOutput(output), { code: failure === 'stat' ? 'EIO' : 'EMFILE' });
      assert.equal(fs.existsSync(output + '.preparing'), failure === 'replacement');
      assert.equal(closed, failure === 'stat');
      fs.promises.open = original; syncBuiltinESMExports();
      if (failure === 'replacement')
        assert.equal(fs.readFileSync(output + '.preparing/sentinel', 'utf8'), 'keep');
      else await (await reserveOutput(output)).cleanup();
    `], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  }
});
