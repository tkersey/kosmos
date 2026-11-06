import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve, extname, join } from "node:path";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chromium, firefox } from "./browser-tools/node_modules/playwright-core/index.mjs";
import { encodeInput, decodeOutcome, decodeRequest, encodeResult } from "../../src/embedding/index.mjs";
const [kernelPath, fixtureTool] = process.argv.slice(2);
const kernel = await readFile(kernelPath);
const sha256 = createHash("sha256").update(kernel).digest("hex");
const image = new Uint8Array(execFileSync(fixtureTool, ["image", "resource"]));
const root = resolve(import.meta.dirname, "../..");
const server = createServer(async (request, response) => {
  try {
    const path = new URL(request.url, "http://localhost").pathname;
    if (path === "/") { response.end("<!doctype html><title>Kosmos Worker conformance</title>"); return; }
    if (path === "/kernel.wasm") { response.setHeader("Content-Type", "application/wasm"); response.end(kernel); return; }
    const file = path === "/worker.mjs" ? resolve(import.meta.dirname, "worker.mjs") :
      /^\/src\/embedding\/[a-z-]+\.mjs$/.test(path) ? resolve(root, path.slice(1)) : null;
    if (!file) { response.writeHead(404); response.end(); return; }
    response.setHeader("Content-Type", extname(file) === ".mjs" ? "text/javascript" : "application/octet-stream");
    response.end(await readFile(file));
  } catch { response.writeHead(500); response.end(); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}/`;
const results = [];
try {
  for (const [engine, type] of [["chromium", chromium], ["firefox", firefox]]) {
    const browser = await type.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.goto(url);
      await page.evaluate(() => {
        window.workers = new Map(); window.nextWorker = 0;
        window.workerCall = (id, payload) => new Promise((resolve, reject) => {
          const worker = window.workers.get(id);
          worker.onmessage = event => resolve(event.data);
          worker.onerror = event => reject(new Error(event.message));
          worker.postMessage(payload);
        });
      });
      const start = payload => page.evaluate(async payload => {
        const id = window.nextWorker++;
        window.workers.set(id, new Worker("/worker.mjs", { type: "module" }));
        return { id, result: await window.workerCall(id, payload) };
      }, payload);
      const terminate = id => page.evaluate(id => { window.workers.get(id).terminate(); window.workers.delete(id); }, id);
      const rejected = await start({ op: "start", sha256: "0".repeat(64), image: Array.from(image) });
      assert.equal(rejected.result.error, "WORLD_KERNEL_IDENTITY_INVALID");
      await terminate(rejected.id);
      const first = await start({ op: "start", sha256, image: Array.from(image), transfer: true });
      assert.equal(first.result.error, undefined);
      const requested = decodeOutcome(new Uint8Array(first.result.output));
      assert.equal((await decodeRequest(requested.request)).semanticIdentity, "example/resource-acquire");
      assert.equal(first.result.workingLive, "0");
      await terminate(first.id);
      const reply = await encodeResult(requested.request, Uint8Array.of(41, 0, 0, 0, 0, 0, 0, 0));
      const command = encodeInput({ image, state: new Uint8Array(first.result.state), control: "reply", value: reply });
      const native = new Uint8Array(execFileSync(fixtureTool, ["invoke"], { input: command }));
      const used = decodeOutcome(native);
      assert.equal((await decodeRequest(used.request)).semanticIdentity, "example/resource-use");
      const second = await start({ op: "restore", sha256, image: Array.from(image), state: Array.from(used.state),
        control: "reply", value: Array.from(await encodeResult(used.request, new Uint8Array())) });
      assert.equal(second.result.error, undefined);
      const released = decodeOutcome(new Uint8Array(second.result.output));
      assert.equal((await decodeRequest(released.request)).semanticIdentity, "example/resource-release");
      const done = await page.evaluate(({ id, value }) => window.workerCall(id, { op: "drive", control: "reply", value, close: true }),
        { id: second.id, value: Array.from(await encodeResult(released.request, new Uint8Array())) });
      assert.equal(done.error, undefined);
      assert.deepEqual(decodeOutcome(new Uint8Array(done.output)).value, Uint8Array.of(42, 0, 0, 0, 0, 0, 0, 0));
      assert.equal(done.workingLive, "0");
      await terminate(second.id);
      for (const name of ["retainedScope", "retainedScopeGeneral"]) {
        const program = new Uint8Array(execFileSync(fixtureTool, ["image", name]));
        const paused = await start({ op: "start", sha256, image: Array.from(program), transfer: true });
        assert.equal(paused.result.error, undefined);
        assert.equal(decodeOutcome(new Uint8Array(paused.result.output)).kind, "yielded");
        assert.equal(paused.result.workingLive, "0");
        await terminate(paused.id);
        const resumed = encodeInput({ image: program,
          state: new Uint8Array(paused.result.state), control: "resume_yield" });
        const cleaning = decodeOutcome(new Uint8Array(execFileSync(fixtureTool, ["invoke"], { input: resumed })));
        assert.equal(cleaning.kind, "requested");
        const cleanup = await decodeRequest(cleaning.request);
        assert.equal(cleanup.semanticIdentity, "retained-scope/release");
        assert.deepEqual(cleanup.payload, Uint8Array.of(77, 0, 0, 0, 0, 0, 0, 0));
        const finished = await start({ op: "restore", sha256, image: Array.from(program),
          state: Array.from(cleaning.state), control: "reply",
          value: Array.from(await encodeResult(cleaning.request, new Uint8Array())), close: true });
        assert.equal(finished.result.error, undefined);
        const result = decodeOutcome(new Uint8Array(finished.result.output));
        assert.equal(result.kind, "completed");
        assert.deepEqual(result.value, Uint8Array.of(0x61, 4, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0));
        assert.equal(finished.result.workingLive, "0");
        await terminate(finished.id);
      }
      const replayProgram = new Uint8Array(execFileSync(fixtureTool, ["image", "diagnostic-replay"]));
      const replayInput = new Uint8Array(execFileSync(fixtureTool, ["replay-input", "matching"]));
      const expectedReplay = new Uint8Array(execFileSync(fixtureTool, ["invoke"], {
        input: encodeInput({ image: replayProgram, initialArgs: replayInput }), maxBuffer: 8 << 20,
      }));
      assert.equal(decodeOutcome(expectedReplay).kind, "completed");
      const interrupted = await start({ op: "start", sha256, image: Array.from(replayProgram),
        initialArgs: Array.from(replayInput), quantum: 47, transfer: true });
      assert.equal(interrupted.result.error, undefined);
      assert.equal(decodeOutcome(new Uint8Array(interrupted.result.output)).kind, "progressed");
      assert.equal(interrupted.result.workingLive, "0");
      await terminate(interrupted.id);
      replayInput.fill(255);
      const continued = await start({ op: "restore", sha256, image: Array.from(replayProgram),
        state: interrupted.result.state, close: true });
      assert.equal(continued.result.error, undefined);
      assert.deepEqual(new Uint8Array(continued.result.output), expectedReplay);
      assert.equal(continued.result.workingLive, "0");
      await terminate(continued.id);
      results.push({ engine, version: browser.version(), workersDestroyed: 9,
        retainedScopedComputations: 2, restoredDiagnosticReplays: 1 });
    } finally { await browser.close(); }
  }
} finally { await new Promise(resolve => server.close(resolve)); }
console.log(JSON.stringify({ check: "real browser Worker/native/fresh Worker transfer", kernelSha256: sha256, results }));
