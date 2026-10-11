import assert from 'node:assert/strict';
import test from 'node:test';
import crypto from 'node:crypto';
import { syncBuiltinESMExports } from 'node:module';
import { runInNewContext } from 'node:vm';
import { inspectKernelWasm, MAXIMUM_KERNEL_BYTES, wasmRange, wasmOffset } from '../../src/embedding/wasm.mjs';
import { Kernel } from '../../src/embedding/kernel.mjs';

import { kernel } from "./wasm_fixture.mjs";
const admit = (bytes, options) => Kernel.create({ bytes, ...options, instanceId: 1n });

test('oversized kernel bytes reject before copying or hashing', async (t) => {
  const input = new Uint8Array(MAXIMUM_KERNEL_BYTES + 1);
  Object.defineProperty(input, 'byteLength', { value: 0 });
  try {
    t.mock.method(globalThis, 'Uint8Array', new Proxy(Uint8Array, {
      construct: () => assert.fail('oversized kernel must not be copied'),
      get: (target, key) => key === 'from' ? () => assert.fail('oversized kernel must not be copied') : Reflect.get(target, key),
    }));
    t.mock.method(crypto, 'createHash', () => assert.fail('oversized kernel must not be hashed'));
    syncBuiltinESMExports();
    await assert.rejects(admit(input, { expectedSha256: '0'.repeat(64) }), { name: 'RangeError' });
  } finally { t.mock.restoreAll(); syncBuiltinESMExports(); }
});

test('kernel snapshots preserve Buffer and Uint8Array views without invoking iterators', async () => {
  const bytes = kernel();
  const expectedSha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const backing = new Uint8Array(bytes.length + 2);
  backing.set(bytes, 1);
  for (const input of [backing.subarray(1, -1), Buffer.from(backing.buffer, 1, bytes.length)]) {
    input[Symbol.iterator] = () => assert.fail('kernel admission must copy the byte view');
    assert.ok(await admit(input, { expectedSha256 }) instanceof Kernel);
  }
});

test('kernel admission preserves the cross-realm Uint8Array domain', async () => {
  const bytes = kernel();
  const foreign = runInNewContext('Uint8Array.from(values)', { values: [...bytes] });
  const expectedSha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  assert.deepEqual(inspectKernelWasm(foreign), inspectKernelWasm(bytes));
  assert.ok(await admit(foreign, { expectedSha256 }) instanceof Kernel);
  await assert.rejects(admit(Object.create(Uint8Array.prototype), { expectedSha256 }),
    /expected Uint8Array/);
});

test('static ABI admission accepts the exact interface and rejects altered types, imports and names',()=>{
  const valid=kernel();assert.ok(WebAssembly.validate(valid));
  const admitted=inspectKernelWasm(valid);
  assert.equal(admitted.importCount,0);assert.equal(admitted.exportCount,23);
  for(const change of [{wrongType:true},{extraExport:true},{missingExport:true},{imports:true},{start:true},{shared:true},
    {rename:(name)=>name==='memory'?'\uFEFFmemory':name},
    {rename:(name)=>name==='world_invoke'?'\uFEFFworld_invoke':name}]) {
    const bytes=kernel(change);assert.ok(WebAssembly.validate(bytes),'negative fixture must be structurally valid WASM');
    assert.throws(()=>inspectKernelWasm(bytes),{name:'KosmosHostError'});
  }
});

test('guest ranges require exact unsigned offsets and complete memory containment',()=>{
  const memory=new WebAssembly.Memory({initial:1,maximum:1});
  assert.equal(wasmRange(memory,65535,1n,'value').length,1);
  assert.equal(wasmOffset(-1,'pointer'),0xffffffff);
  for(const [pointer,length] of [[65535,2n],[-1,1n],[0,-1n],[0,1n<<64n],[1.5,1n]]) {
    assert.throws(()=>wasmRange(memory,pointer,length,'value'),{name:'KosmosHostError'});
  }
});

test('kernel factory checks identity before compilation and ABI before instantiation', async (t) => {
  const bytes = kernel();
  t.mock.method(WebAssembly, 'compile', () => assert.fail('identity mismatch must not compile'));
  await assert.rejects(admit(bytes, { expectedSha256: '0'.repeat(64) }), { code: 'WORLD_KERNEL_IDENTITY_INVALID' });
  t.mock.restoreAll();
  t.mock.method(WebAssembly, 'instantiate', () => assert.fail('rejected kernel must not instantiate'));
  for (const change of [{wrongType:true},{extraExport:true},{missingExport:true},{imports:true},{start:true},{shared:true}]) {
    const input = kernel(change);
    await assert.rejects(admit(input, { expectedSha256: crypto.createHash('sha256').update(input).digest('hex') }), { name: 'KosmosHostError' });
  }
});

test('kernel compilation owns its bytes across asynchronous suspension', async (t) => {
  const bytes = kernel({ outcome: Uint8Array.of(51, 52) });
  const expectedSha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const compile = WebAssembly.compile.bind(WebAssembly);
  t.mock.method(WebAssembly, 'compile', async input => {
    assert.notStrictEqual(input, bytes);
    const result = compile(input);
    bytes.fill(0xff);
    await Promise.resolve();
    return result;
  });
  assert.ok(await admit(bytes, { expectedSha256 }) instanceof Kernel);
  assert.ok(bytes.every(byte => byte === 0xff));
});

test('kernel compilation rejects invalid function bodies without instantiation', async (t) => {
  const bytes = kernel();
  bytes[bytes.length - 1] = 0xff;
  assert.equal(WebAssembly.validate(bytes), false);
  t.mock.method(WebAssembly, 'instantiate', () => assert.fail('invalid code must not instantiate'));
  await assert.rejects(admit(bytes, { expectedSha256: crypto.createHash('sha256').update(bytes).digest('hex') }), { code: 'WORLD_KERNEL_WASM_INVALID' });
});

test('cached code rechecks identity and creates independent guest instances', async (t) => {
  const firstBytes = kernel({ outcome: Uint8Array.of(91, 92) });
  const secondBytes = kernel({ outcome: Uint8Array.of(81, 82) });
  const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
  const compile = WebAssembly.compile.bind(WebAssembly);
  let compilations = 0;
  const memories = [], instantiate = WebAssembly.instantiate.bind(WebAssembly);
  t.mock.method(WebAssembly, 'instantiate', async (...args) => { const result = await instantiate(...args); memories.push(result.exports.memory); return result; });
  t.mock.method(WebAssembly, 'compile', async bytes => { compilations++; return compile(bytes); });
  const first = await admit(firstBytes, { expectedSha256: digest(firstBytes) });
  const second = await admit(firstBytes, { expectedSha256: digest(firstBytes) });
  assert.equal(compilations, 1);
  assert.equal(memories.length, 2);
  assert.notStrictEqual(memories[0], memories[1]);
  first.setLimits({ input: 1, working: 1, output: 1 });
  assert.deepEqual(first.invoke(new Uint8Array()), Uint8Array.of(91, 92));
  assert.deepEqual(second.invoke(new Uint8Array()), Uint8Array.of(91, 92));
  await assert.rejects(admit(secondBytes, { expectedSha256: digest(firstBytes) }), { code: 'WORLD_KERNEL_IDENTITY_INVALID' });
  const different = await admit(secondBytes, { expectedSha256: digest(secondBytes) });
  assert.deepEqual(different.invoke(new Uint8Array()), Uint8Array.of(81, 82));
  assert.equal(compilations, 2);
});

test('a collected module or missing WeakRef safely recompiles', async (t) => {
  const bytes = kernel({ outcome: Uint8Array.of(73, 74) });
  const expectedSha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const compile = WebAssembly.compile.bind(WebAssembly);
  let count = 0;
  t.mock.method(WebAssembly, 'compile', async input => { count++; return compile(input); });
  const original = globalThis.WeakRef;
  try {
    globalThis.WeakRef = class { constructor() {} deref() { return undefined; } };
    await admit(bytes, { expectedSha256 });
    await admit(bytes, { expectedSha256 });
    assert.equal(count, 2);
    globalThis.WeakRef = undefined;
    await admit(bytes, { expectedSha256 });
    await admit(bytes, { expectedSha256 });
    assert.equal(count, 4);
  } finally { globalThis.WeakRef = original; }
});

test('concurrent admission keeps different kernel identities separate', async () => {
  const inputs = [kernel({outcome:Uint8Array.of(61)}), kernel({outcome:Uint8Array.of(62)})];
  const hosts = await Promise.all(inputs.map(bytes => admit(bytes, { expectedSha256: crypto.createHash('sha256').update(bytes).digest('hex') })));
  assert.deepEqual(hosts[0].invoke(new Uint8Array()), Uint8Array.of(61));
  assert.deepEqual(hosts[1].invoke(new Uint8Array()), Uint8Array.of(62));
});
