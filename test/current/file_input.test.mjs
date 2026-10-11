import assert from 'node:assert/strict';
import test from 'node:test';
import fs, { mkdtemp, writeFile, rm, symlink, truncate, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { readRegularFile } from '../../src/node/file-input.mjs';
import { MAXIMUM_KERNEL_BYTES, assertKernelByteLength } from '../../src/embedding/wasm.mjs';
import { Kernel } from '../../src/embedding/kernel.mjs';
import { frame } from '../../src/embedding/wire.mjs';
import { kernel } from './wasm_fixture.mjs';

test("oversized sparse kernels reject before allocating or reading their contents", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "kosmos-v2-kernel-size-"));
  const path = join(root, "oversized.wasm");
  const originalOpen = fs.open;
  let closes = 0;
  try {
    await writeFile(path, "");
    await truncate(path, MAXIMUM_KERNEL_BYTES + 1);
    t.mock.method(fs, "open", async (...args) => {
      const file = await originalOpen(...args);
      return {
        stat: (...args) => file.stat(...args),
        read: () => assert.fail("oversized contents must not be read"),
        close: async () => { closes++; await file.close(); },
      };
    });
    t.mock.method(Buffer, "alloc", () => assert.fail("oversized contents must not be allocated"));
    syncBuiltinESMExports();
    await assert.rejects(readRegularFile(path, assertKernelByteLength), { code: "WORLD_KERNEL_TOO_LARGE" });
    assert.equal(closes, 1);
  } finally {
    t.mock.restoreAll();
    syncBuiltinESMExports();
    await rm(root, { recursive: true, force: true });
  }
});

test("kernel reads stay bounded when an opened file grows or shrinks", async (t) => {
  try {
    for (const changedSize of [0n, 5n, BigInt(MAXIMUM_KERNEL_BYTES) + 1n]) {
      let stats = 0;
      let closes = 0;
      let readBytes = 0;
      t.mock.method(fs, "open", async () => ({
        stat: async () => ({ isFile: () => true, size: stats++ === 0 ? 4n : changedSize, mtimeNs: 0n, ctimeNs: 0n }),
        read: async (bytes, offset, length, position) => {
          assert.equal(bytes.length, 4);
          assert.equal(position, offset);
          assert.equal(length, 4 - offset);
          if (changedSize === 0n) return { bytesRead: 0 };
          bytes[offset] = 0;
          readBytes++;
          return { bytesRead: 1 };
        },
        close: async () => { closes++; },
      }));
      syncBuiltinESMExports();
      await assert.rejects(readRegularFile("changing.wasm", assertKernelByteLength), {
        code: changedSize > MAXIMUM_KERNEL_BYTES ? "WORLD_KERNEL_TOO_LARGE" : "WORLD_FILE_CHANGED",
      });
      assert.equal(readBytes, changedSize === 0n ? 0 : 4);
      assert.equal(closes, 1);
      t.mock.restoreAll();
      syncBuiltinESMExports();
    }
  } finally { t.mock.restoreAll(); syncBuiltinESMExports(); }
});

test("kernel loading rejects directories and FIFOs without blocking", { skip: process.platform === "win32" }, async () => {
  const root = await mkdtemp(join(tmpdir(), "kosmos-v2-kernel-kind-"));
  try {
    const fifo = join(root, "kernel.fifo");
    const alias = join(root, "kernel-link.fifo");
    const made = spawnSync("mkfifo", [fifo], { encoding: "utf8", timeout: 2000 });
    assert.equal(made.status, 0, made.error?.message ?? made.stderr);
    await symlink(fifo, alias);
    const module = new URL("../../src/node/file-input.mjs", import.meta.url).href;
    const script = `import assert from "node:assert/strict";
      import { readRegularFile } from ${JSON.stringify(module)};
      await assert.rejects(readRegularFile(process.env.WORLD_TEST_KERNEL),
        { code: "WORLD_FILE_NOT_REGULAR" });`;
    for (const path of [root, fifo, alias]) {
      const result = spawnSync(process.execPath, ["--input-type=module", "--eval", script], {
        encoding: "utf8", timeout: 2000, env: { ...process.env, WORLD_TEST_KERNEL: path },
      });
      assert.equal(result.error, undefined, result.error?.message);
      assert.equal(result.status, 0, result.stderr);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});


test('current kernel loading accepts regular paths, file URLs and symlinks', async () => {
  const root = await mkdtemp(join(tmpdir(), 'kosmos-current-files-'));
  try {
    const bytes = kernel(), file = join(root, 'kernel.wasm'), alias = join(root, 'alias.wasm');
    await writeFile(file, bytes); await symlink(file, alias);
    const expectedSha256 = createHash('sha256').update(bytes).digest('hex');
    for (const path of [file, pathToFileURL(file), alias, pathToFileURL(alias)]) {
      const owned = await readRegularFile(path, assertKernelByteLength);
      assert.deepEqual(owned, Buffer.from(bytes));
      assert.ok(await Kernel.create({ bytes: owned, expectedSha256, instanceId: 1n }));
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('current CLI rejects ambiguous options and cannot overwrite input files', async () => {
  const root = await mkdtemp(join(tmpdir(), 'kosmos-current-cli-'));
  try {
    const cli = fileURLToPath(new URL('../../bin/kosmos.mjs', import.meta.url));
    const bytes = kernel({ outcome: frame('ABL_PKO3', Uint8Array.of(3,0)) });
    const path = join(root, 'kernel.wasm'), input = join(root, 'input.pki3');
    const digest = createHash('sha256').update(bytes).digest('hex');
    await writeFile(path, bytes); await writeFile(input, Uint8Array.of(1));
    const base = [cli,'invoke','--kernel',path,'--sha256',digest,'--input',input];
    for (const extra of [['--unknown','x'],['--kernel',path],['--output',path],['--input-budget','-1']]) {
      const result = spawnSync(process.execPath,[...base,...extra],{timeout:2000});
      assert.equal(result.status,1); assert.equal(result.stdout.length,0);
      assert.deepEqual(await readFile(path),Buffer.from(bytes));
    }
    const valid = spawnSync(process.execPath,base,{timeout:2000});
    assert.equal(valid.status,0,valid.stderr.toString());
    assert.deepEqual(valid.stdout,Buffer.from(frame('ABL_PKO3',Uint8Array.of(3,0))));
    const fifo = join(root,'input.fifo');
    if(process.platform !== 'win32') {
      assert.equal(spawnSync('mkfifo',[fifo],{timeout:2000}).status,0);
      for(const selected of [root,fifo]) for(const field of ['--kernel','--input']) {
        const args=[...base]; args[args.indexOf(field)+1]=selected;
        const result=spawnSync(process.execPath,args,{timeout:2000});
        assert.equal(result.error,undefined); assert.equal(result.status,1);
        assert.match(result.stderr.toString(),/WORLD_FILE_NOT_REGULAR/);
      }
    }
  } finally { await rm(root,{recursive:true,force:true}); }
});

test('current CLI enforces the kernel extent limit before allocating its contents', async () => {
  const root = await mkdtemp(join(tmpdir(), 'kosmos-current-cli-limit-'));
  try {
    const path = join(root, 'huge.wasm'), hook = join(root, 'allocation-guard.mjs');
    await writeFile(path, ''); await truncate(path, MAXIMUM_KERNEL_BYTES + 1);
    await writeFile(hook, `const allocate = Buffer.alloc;
      Buffer.alloc = function(size, ...args) {
        if (size > ${MAXIMUM_KERNEL_BYTES}) throw new Error('oversized contents were allocated');
        return allocate.call(this, size, ...args);
      };`);
    const cli = fileURLToPath(new URL('../../bin/kosmos.mjs', import.meta.url));
    const result = spawnSync(process.execPath, ['--import', pathToFileURL(hook).href,
      cli, 'invoke', '--kernel', path, '--sha256', '0'.repeat(64), '--input', path], { timeout: 2000 });
    assert.equal(result.error, undefined); assert.equal(result.status, 1);
    assert.match(result.stderr.toString(), /WORLD_KERNEL_TOO_LARGE/);
    assert.doesNotMatch(result.stderr.toString(), /oversized contents were allocated/);
    assert.equal(result.stdout.length, 0);
  } finally { await rm(root, { recursive: true, force: true }); }
});
