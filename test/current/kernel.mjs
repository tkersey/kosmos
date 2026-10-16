import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { Kernel } from "../../src/embedding/index.mjs";
import { inspectKernelWasm, KERNEL_EXPORT_NAMES } from "../../src/embedding/wasm.mjs";
import { encodeInput, decodeOutcome, decodeRequest, encodeResult } from "../../src/embedding/index.mjs";

const [kernelPath, fixtureTool] = process.argv.slice(2);
const bytes = new Uint8Array(await readFile(kernelPath));
const expectedSha256 = createHash("sha256").update(bytes).digest("hex");
const inspection = inspectKernelWasm(bytes);
assert.equal(inspection.importCount, 0);
assert.equal(inspection.memory.shared, false);
assert.equal(inspection.memory.maximumPages, 4096);
const module = new WebAssembly.Module(bytes);
assert.deepEqual(WebAssembly.Module.exports(module).map(x => x.name).sort(), [...KERNEL_EXPORT_NAMES].sort());
// The authored evaluator carries its admitted code and ordinary machine state.
// Keep physical capacity explicit; the capacity/rollback checks below still
// lower each arena to its measured live usage or zero.
const limits = { input: 2 << 20, working: 128 << 20, output: 2 << 20 };
let identity = 1n;
async function kernel() {
  const k = await Kernel.create({ bytes, expectedSha256, instanceId: identity++ });
  k.setLimits(limits);
  return k;
}
const image = name => new Uint8Array(execFileSync(fixtureTool, ["image", name], { maxBuffer: 8 << 20 }));
const native = command => new Uint8Array(execFileSync(fixtureTool, ["invoke"], { input: command, maxBuffer: 8 << 20 }));
const integer = n => { const bytes = new Uint8Array(8); new DataView(bytes.buffer).setBigUint64(0, BigInt(n), true); return bytes; };

// A native specialization crosses only the existing canonical guest boundary.
// The shipped generic WASM image is unchanged and receives no outer capsule.
{
  const program = image("recursive");
  const command = encodeInput({ image: program, initialArgs: integer(9), quantum: 3 });
  const specialized = new Uint8Array(execFileSync(fixtureTool, ["specialized-invoke"], { input: command, maxBuffer: 8 << 20 }));
  assert.deepEqual(specialized, native(command));
  const cut = decodeOutcome(specialized);
  assert.ok(cut.state);
  const continuation = encodeInput({ image: program, state: cut.state, quantum: 10000 });
  const k = await kernel();
  const result = k.invoke(continuation);
  assert.deepEqual(result, native(continuation));
  assert.equal(decodeOutcome(result).kind, "completed");
}
async function leaf(request) {
  const decoded = await decodeRequest(request);
  const name = decoded.semanticIdentity;
  if (name === "example/resource-acquire") return encodeResult(request, integer(41));
  if (name === "component/release") {
    assert.deepEqual(decoded.payload, integer(83));
    return encodeResult(request, new Uint8Array());
  }
  if (name === "retained-scope/release") {
    assert.deepEqual(decoded.payload, integer(77));
    return encodeResult(request, new Uint8Array());
  }
  if (["example/tail-cleanup", "example/resource-use", "example/resource-release", "example/generator-release", "custody/release"].includes(name)) return encodeResult(request, new Uint8Array());
  throw new Error(`unbound fixture operation ${name}`);
}

await assert.rejects(Kernel.create({ bytes, expectedSha256: "0".repeat(64) }), { code: "WORLD_KERNEL_IDENTITY_INVALID" });
const wrongProfile = bytes.slice();
const needle = new TextEncoder().encode("world_abi_version");
const offset = Buffer.from(wrongProfile).indexOf(needle);
assert.ok(offset >= 0);
wrongProfile[offset + 6] = "x".charCodeAt(0);
await assert.rejects(Kernel.create({ bytes: wrongProfile, expectedSha256: createHash("sha256").update(wrongProfile).digest("hex") }));

let boundaries = 0, transfers = 0;
const terminal = [];
for (const [name, args] of [["retainedScope", []], ["retainedScopeGeneral", []], ["branchingTailProtected", [1]], ["branchingTail", [1]], ["install", []], ["deep", []], ["recursive", integer(100)], ["resource", []], ["custody", []], ["reentrant", []], ["generator", []], ["shallow", [0]], ["scalarContracts", [0]], ["components", []], ["componentsDouble", []], ["componentsRecursive", integer(100)]]) {
  const program = image(name);
  const quantum = name.startsWith("branchingTail") || name.startsWith("retainedScope") ? 1 : 23;
  let k = await kernel();
  const prepared = k.prepare(program);
  let session = k.start(prepared, new Uint8Array(args));
  k.releasePrepared(prepared); // Active session retains the admitted owner.
  assert.throws(() => k.start(prepared), { code: "WORLD_HANDLE_INVALID" });
  let state = k.checkpoint(session), control = "none", value = new Uint8Array();
  let yields = 0, releases = 0;
  for (let round = 0; ; round++) {
    assert.ok(round < 512, `${name} failed to finish`);
    const command = encodeInput({ image: program, state, control, value, quantum });
    const expected = native(command);
    assert.deepEqual(k.invoke(command), expected, `${name} fresh guest boundary ${round}`);
    const actual = k.drive(session, { control, value, quantum, checkpoint: true });
    assert.deepEqual(actual, expected, `${name} boundary ${round}`);
    const outcome = decodeOutcome(actual);
    boundaries++;
    if (["completed", "failed", "cancelled"].includes(outcome.kind)) {
      if (name === "components" || name === "componentsDouble" || name.startsWith("retainedScope")) {
        assert.equal(yields, 1);
        assert.equal(releases, 1);
      }
      terminal.push({ name, kind: outcome.kind, value: Buffer.from(outcome.value ?? []).toString("hex") });
      k.close(session);
      assert.equal(k.usage().workingLive, 0n);
      assert.throws(() => k.drive(session), { code: "WORLD_HANDLE_INVALID" });
      break;
    }
    state = outcome.state;
    assert.ok(state);
    if (outcome.kind === "requested") {
      if (["component/release", "retained-scope/release"].includes((await decodeRequest(outcome.request)).semanticIdentity)) releases++;
      control = "reply"; value = await leaf(outcome.request);
    }
    else { control = outcome.kind === "yielded" ? "resume_yield" : "none"; value = new Uint8Array(); }
    if (outcome.kind === "yielded") yields++;
    if (round === 0 || outcome.kind === "requested") {
      const checkpoint = k.checkpoint(session, { transfer: true });
      assert.deepEqual(checkpoint, state);
      assert.equal(k.usage().workingLive, 0n);
      const old = k;
      k = await kernel();
      assert.throws(() => k.drive(session), { code: "WORLD_HANDLE_INVALID" });
      assert.throws(() => old.checkpoint(session), { code: "WORLD_HANDLE_INVALID" });
      const preparation = k.prepare(program);
      session = k.restore(preparation, checkpoint);
      k.releasePrepared(preparation);
      transfers++;
    }
  }
}
assert.equal(terminal.find(x => x.name === "branchingTail").value, "3c00000000000000");
assert.equal(terminal.find(x => x.name === "branchingTailProtected").value, "3c00000000000000");
for (const name of ["retainedScope", "retainedScopeGeneral"])
  assert.equal(terminal.find(x => x.name === name).value, "61040000000000006300000000000000");
assert.equal(terminal.find(x => x.name === "install").value, "2008000000000000");
assert.equal(terminal.find(x => x.name === "resource").value, "2a00000000000000");
assert.equal(terminal.find(x => x.name === "reentrant").value, "7100000000000000");
assert.equal(terminal.find(x => x.name === "generator").value, "2a000000000000002b00000000000000");
assert.equal(terminal.find(x => x.name === "components").value, "5300000000000000");
assert.equal(terminal.find(x => x.name === "componentsDouble").value, "a600000000000000");
assert.equal(terminal.find(x => x.name === "componentsRecursive").value, "01");

// Physical failures cannot consume the parked response or transfer custody.
const k = await kernel(), program = image("resource"), p = k.prepare(program), s = k.start(p);
k.releasePrepared(p);
const initial = k.checkpoint(s);
let controlCoercions = 0;
const coercedControl = { toString() { controlCoercions++; return "none"; } };
for (const control of ["toString", "constructor", "__proto__", "hasOwnProperty", "unknown", null, 0, coercedControl]) {
  assert.throws(() => k.drive(s, { control, quantum: 1 }), TypeError);
  assert.deepEqual(k.checkpoint(s), initial, "invalid controls must not advance the session");
  assert.throws(() => encodeInput({ image: program, initialArgs: new Uint8Array(), control }), TypeError);
}
assert.equal(controlCoercions, 0, "control admission must not invoke caller coercion hooks");
assert.throws(() => k.close(s), error => error.details?.diagnostic === "UnfinishedSession");
const pending = decodeOutcome(k.drive(s, { checkpoint: true }));
const response = await leaf(pending.request);
k.setLimits({ ...limits, output: 0 });
assert.throws(() => k.drive(s, { control: "reply", value: response, checkpoint: true }), error => error.code === "WORLD_CAPACITY" && error.details.arena === "output");
assert.throws(() => k.checkpoint(s, { transfer: true }), { code: "WORLD_CAPACITY" });
k.setLimits(limits);
assert.deepEqual(k.checkpoint(s), pending.state);
const used = decodeOutcome(k.drive(s, { control: "reply", value: response, checkpoint: true }));
assert.equal((await decodeRequest(used.request)).semanticIdentity, "example/resource-use");
const acquired = await leaf(used.request);
k.setLimits({ ...limits, working: k.usage().workingLive });
assert.throws(() => k.drive(s, { control: "reply", value: acquired }), error => error.code === "WORLD_CAPACITY" && error.details.arena === "working");
k.setLimits(limits);
assert.deepEqual(k.checkpoint(s), used.state);
const released = decodeOutcome(k.drive(s, { control: "reply", value: acquired }));
assert.equal(released.state, null);
const final = decodeOutcome(k.drive(s, { control: "reply", value: await leaf(released.request) }));
assert.equal(final.kind, "completed");
k.close(s);
assert.equal(k.usage().workingLive, 0n);

// Reuse one preparation across terminal Sessions without accumulating live or
// reserved memory. The explicit allocator must reuse out-of-order frees.
const reusable = await kernel(), reusableImage = image("install");
const obsolete = reusableImage.slice(); obsolete[7] = 50;
assert.throws(() => reusable.prepare(obsolete), error => error.details?.diagnostic === "InvalidFamily");
const reusablePrepared = reusable.prepare(reusableImage);
let steady;
for (let i = 0; i < 12; i++) {
  const active = reusable.start(reusablePrepared);
  assert.equal(decodeOutcome(reusable.drive(active)).kind, "completed");
  reusable.close(active);
  const usage = reusable.usage();
  if (steady) {
    assert.equal(usage.workingLive, steady.workingLive);
    assert.equal(usage.memoryBytes, steady.memoryBytes);
  } else steady = usage;
}
reusable.releasePrepared(reusablePrepared);
assert.equal(reusable.usage().workingLive, 0n);

// Raw ABI bounds and namespace checks are independent of JS handle wrappers.
const raw = new WebAssembly.Instance(module, {}).exports;
assert.equal(raw.world_initialize(999n), 0);
assert.equal(raw.world_initialize(999n), 2);
assert.equal(raw.world_prepare_input(998n, 0n), 2);
assert.equal(raw.world_invoke(999n, 0n), 2);
assert.equal(raw.world_prepare_input(999n, 0n), 0);
assert.equal(raw.world_invoke(999n, 1n), 2);
assert.equal(raw.world_close(999n, 1n), 2);
assert.equal(raw.world_prepare_input(999n, 1n << 32n), 2);
assert.equal(raw.world_set_limits(999n, 1n, 1n << 32n, 1n), 2);
console.log(JSON.stringify({ check: "ABI 3 native/Node canonical agreement", kernelSha256: expectedSha256, boundaries, transfers, terminal, node: process.version }));
