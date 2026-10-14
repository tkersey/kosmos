// Preserve independent source semantics while comparing current native/WASM bytes.
import assert from "node:assert/strict";
import { readFile as read } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { Kernel, encodeInput, decodeRequest, encodeResult, decodeOutcome } from "../../src/embedding/index.mjs";

const requiredExamples = ["lexical","deep","recursive","choices-all","choices-first","generator","state-local","state-shared","resource-scalar","resource-pair","answers","scoped-reader","writer-raise","scheduler","queens-dfs","queens-bfs","cell-order","nested","shallow","injection","indexed","abort-custody","unwind","reentrant","cloned","clause-abort","bounded-values","scalar-contracts","ownership","shallow-resumptions","shallow-injection","handle-operand-order","protect-operand-order","successor-state","clause-payload","yielding-cleanup","borrow-operands","cleanup-disposal","cleanup-disposal-running","cleanup-disposal-failure","cleanup-disposal-owned","product-projection","local-one-shot","local-multi-shot"];
const visitedSources = new Set(), visitedImages = new Set();
requiredExamples.push("stateful-service", "swapped-service-replies", "paired-services");
async function readFile(file, ...options) {
  const match = String(file).match(/\/source-([^/]+)\.(json|bpi3)$/);
  if (match) (match[2] === "json" ? visitedSources : visitedImages).add(match[1]);
  return read(file, ...options);
}

const [kernelPath, nativePath, fixtures, oraclePath] = process.argv.slice(2);
const { execute } = await import(pathToFileURL(oraclePath).href);
const { containsServiceTrace } = await import(new URL("./service_interactions.mjs", pathToFileURL(oraclePath)));
const kernel = new Uint8Array(await readFile(kernelPath));
const host = await Kernel.create({ bytes: kernel, expectedSha256: createHash("sha256").update(kernel).digest("hex") });
host.setLimits({ input: 8 << 20, working: 64 << 20, output: 8 << 20 });
const yielded = new Set();
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
let observations = 0;
async function compare(mode, input) {
  const control = input.cancel !== undefined ? "cancel_text" : input.result !== undefined ? "reply"
    : input.state && yielded.has(digest(input.state)) ? "resume_yield" : "none";
  const encoded = encodeInput({ image: input.image, initialArgs: input.initialArgs, state: input.state,
    control, value: input.cancel ?? input.result, quantum: mode === "advance" ? 1 : null });
  const native = spawnSync(nativePath, ["invoke"], { input: encoded, maxBuffer: 64 << 20 });
  let bytes;
  try { bytes = host.invoke(encoded); }
  catch (error) {
    assert.notEqual(native.status, 0);
    const diagnostic = error.details?.diagnostic;
    assert.ok(diagnostic, "expected a semantic rejection, not physical capacity");
    assert.ok(native.stderr.toString().includes(diagnostic), native.stderr.toString());
    throw new Error(diagnostic, { cause: error });
  }
  assert.equal(native.status, 0, native.stderr.toString());
  assert.deepEqual(bytes, new Uint8Array(native.stdout));
  // Alternate the actual producer whose portable State is used next.
  const selected = observations++ % 2 ? new Uint8Array(native.stdout) : bytes;
  const result = decodeOutcome(selected);
  if (result.kind === "yielded") yielded.add(digest(result.state));
  result.kind = result.kind[0].toUpperCase() + result.kind.slice(1);
  for (const field of ["reason", "cancellation"]) if (result[field] != null) {
    assert.equal(result[field].kind, "text");
    result[field] = result[field].value;
  }
  return { ...result, bytes: selected };
}

const cleanup = JSON.parse(await readFile(new URL("./cleanup-expectations.json", import.meta.url), "utf8"));
  {
    const word = value => Array.from({ length: 8 }, (_, i) => Number((BigInt(value) >> BigInt(8 * i)) & 255n));
    const command = (id, delta) => [0, ...word(id), ...word(delta)];
    for (const name of ["stateful-service", "swapped-service-replies", "paired-services"]) {
      const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
      const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
      const analysis = name === "paired-services" ? null : JSON.parse(await readFile(join(fixtures, `source-${name}.analysis.json`), "utf8"));
      for (const scenario of (name === "paired-services" ? ["requests"] : ["empty", "requests", "overflow", "cancelled"])) {
        const responses = name === "paired-services" ? [command(1, 1), [], [1], [], command(2, 1), [], [1], []] : scenario === "empty" ? [[1], []]
          : scenario === "cancelled" ? [command(1, 1), []]
          : scenario === "overflow" ? [command(1, 1), [], command(2, (1n << 64n) - 1n), []]
          : [command(1, 1), [], command(2, 1), [], [1], []];
        const oracle = execute(source, [], responses, scenario === "cancelled" ? [{ at: 1, reason: "stop" }] : []);
        const final = scenario === "empty" ? 0 : scenario === "requests" ? 2 : 1;
        const expectedReplies = scenario === "requests" ? 2 : scenario === "overflow" ? 1 : 0;
        for (const mode of ["run", "advance"]) {
          let step = await compare(mode, { image, initialArgs: new Uint8Array() });
          const trace = [];
          let requests = 0, replies = 0, releases = 0;
          while (["Progressed", "Yielded", "Requested"].includes(step.kind)) {
            let result, cancel;
            if (step.kind === "Yielded") {
              trace.push({ kind: "Yielded" });
              if (scenario === "cancelled") cancel = "stop";
            } else if (step.kind === "Requested") {
              const request = await decodeRequest(step.request);
              trace.push({ kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload] });
              if (request.semanticIdentity === "example/service-reply") {
                const id = name === "swapped-service-replies" ? (replies + 1) ^ 3 : replies + 1;
                assert.deepEqual([...request.payload], [...word(id), ...word(name === "paired-services" ? 0 : replies)]);
                replies++;
              } else if (request.semanticIdentity === "example/service-finalize") {
                assert.deepEqual([...request.payload], word(name === "paired-services" ? 1 : final));
                releases++;
              } else assert.equal(request.semanticIdentity, "example/service-command");
              assert.ok(requests < responses.length, "unexpected extra service request");
              result = await encodeResult(step.request, Uint8Array.from(responses[requests++]));
            }
            step = await compare(mode, { image, state: step.state, result, cancel });
          }
          assert.equal(step.kind, oracle.kind);
          if (step.value !== undefined) assert.deepEqual([...step.value], oracle.value);
          assert.deepEqual(trace, oracle.trace);
          if (analysis) assert.ok(containsServiceTrace(analysis, trace, responses), "native/WASM trace absent from interaction abstraction");
          assert.equal(replies, expectedReplies);
          assert.equal(releases, name === "paired-services" ? 2 : 1);
          if (scenario === "cancelled") assert.equal(step.reason, "stop");
        }
      }
    }
  }
  for (const { name, expected } of cleanup.entries) {
    const source = await readFile(join(fixtures, `source-${name}.json`));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    assert.deepEqual(execute(JSON.parse(source), []), expected);
    const checkTerminal = (result) => {
      assert.equal(result.kind, expected.kind, name);
      assert.deepEqual(Array.from(result.value), expected.value, name);
      if (result.kind === "Failed") assert.deepEqual(result.cleanupFailures, [], name);
    };
    const states = [];
    for (const mode of ["run", "advance"]) {
      let result = await compare(mode, { image, initialArgs: new Uint8Array() });
      let yielded = 0, count = 0;
      while (result.kind === "Progressed" || result.kind === "Yielded") {
        assert.ok(count++ < 1000, `${name}: inconclusive test transition limit`);
        if (mode === "advance") states.push(result.state);
        if (result.kind === "Yielded") {
          yielded++;
          assert.equal(name, "cleanup-disposal-failure");
          let cancelled = await compare("advance", { image, state: result.state, cancel: "stop" });
          if (cancelled.kind === "Progressed" || cancelled.kind === "Yielded")
            cancelled = await compare("run", { image, state: cancelled.state, cancel: "later" });
          // Cancellation during an existing failure records its reason but keeps
          // this already-observed yield parked; PKI3 resumes it explicitly.
          if (cancelled.kind === "Yielded")
            cancelled = await compare("run", { image, state: cancelled.state });
          assert.equal(cancelled.kind, "Failed");
          assert.deepEqual(Array.from(cancelled.value), []);
          assert.deepEqual(cancelled.cleanupFailures, []);
          assert.equal(cancelled.cancellation, "stop");
        }
        result = await compare(mode, { image, state: result.state });
      }
      assert.equal(yielded, name === "cleanup-disposal-failure" ? 1 : 0);
      checkTerminal(result);
    }
    if (name === "cleanup-disposal" || name === "cleanup-disposal-owned") {
      assert.ok(states.length > 20, "disposal cancellation frontiers missing");
      for (const state of states) {
        const cancelled = await compare("run", { image, state, cancel: "stop" });
        assert.equal(cancelled.kind, "Cancelled");
        assert.equal(cancelled.reason, "stop");
        assert.deepEqual(cancelled.cleanupFailures, []);
      }
    }
  }
  {
    const source = JSON.parse(await readFile(join(fixtures, "source-borrow-operands.json"), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, "source-borrow-operands.bpi3")));
    for (let index = 0; index < 53; index++) {
      const oracle = execute(source, [index], index >= 32 ? [[], []] : []);
      const populated = index % 2 === 1, owned = index >= 12;
      const kind = owned || !populated ? "Failed" : "Completed";
      const value = Uint8Array.of(index >= 20 ? 8 : owned ? (populated ? 8 : 9) : (populated ? 7 : 8), 0, 0, 0, 0, 0, 0, 0);
      assert.equal(oracle.kind, kind);
      assert.deepEqual(Uint8Array.from(oracle.value), value);
      for (const mode of ["advance", "run"]) {
        const trace = [];
        let step = await compare(mode, { image, initialArgs: Uint8Array.of(index) });
        let transitions = 0;
        while (["Progressed", "Yielded", "Requested"].includes(step.kind)) {
          assert.ok(transitions++ < 1024, `operand ${index}: current instruction horizon exceeded`);
          if (step.kind === "Yielded") trace.push({ kind: "Yielded" });
          let response;
          if (step.kind === "Requested") {
            const request = await decodeRequest(step.request);
            trace.push({ kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload] });
            response = await encodeResult(step.request, new Uint8Array());
          }
          step = await compare(mode, { image, state: step.state, result: response });
        }
        assert.equal(step.kind, kind);
        assert.deepEqual(step.value, value);
        const expectedTrace = kind === "Failed" && index < 42 ? [{ kind: "Yielded" }] : [];
        if (index >= 32) {
          const operandFailureOrder = [
            [1, 2], [2, 1], [1, 2], [1, 2], [2, 1], [1, 2],
            [1, 2], [2, 1], [2, 1], [2, 1], [1, 2],
          ];
          const order = index >= 42 ? operandFailureOrder[index - 42]
            : index === 33 || index === 35 || index >= 36 ? [2, 1] : [1, 2];
          for (const label of order) {
            expectedTrace.push({ kind: "Requested", identity: "custody/release", payload: [label, 0, 0, 0, 0, 0, 0, 0] });
          }
        }
        assert.deepEqual(trace, expectedTrace);
        assert.deepEqual(trace, oracle.trace);
      }
    }
  }
  {
    const source = JSON.parse(await readFile(join(fixtures, "source-scalar-contracts.json"), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, "source-scalar-contracts.bpi3")));
    for (let index = 0; index < 19; index++) {
      const oracle = execute(source, [index]);
      const result = await compare("run", { image, initialArgs: Uint8Array.of(index) });
      assert.equal(result.kind, oracle.kind, `scalar-contracts ${index}`);
      assert.deepEqual(result.value, Uint8Array.from(oracle.value), `scalar-contracts ${index}`);
      let step = await compare("advance", { image, initialArgs: Uint8Array.of(index) });
      while (step.kind === "Progressed") step = await compare("advance", { image, state: step.state });
      assert.deepEqual(step.bytes, result.bytes);
    }
  }
  for (const [name, initial] of [["lexical", [40, 0, 0, 0, 0, 0, 0, 0]], ["deep", []], ["recursive", [16, 39, 0, 0, 0, 0, 0, 0]], ["choices-all", []], ["choices-first", []], ["state-local", []], ["state-shared", []], ["answers", []], ["writer-raise", []], ["cell-order", []], ["nested", []], ["shallow", [0]], ["shallow", [1]], ["injection", [0]], ["injection", [1]], ["abort-custody", [1]], ["bounded-values", []], ["shallow-resumptions", []], ["shallow-injection", [0]], ["shallow-injection", [1]], ["handle-operand-order", []], ["protect-operand-order", []], ["product-projection", [0]], ["product-projection", [1]]]) {
    const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    const oracle = execute(source, initial);
    const result = await compare("run", { image, initialArgs: Uint8Array.from(initial) });
    assert.equal(result.kind, oracle.kind);
    assert.deepEqual(result.value, Uint8Array.from(oracle.value));
    assert.deepEqual(oracle.trace, []);
    if (name !== "recursive") {
      let step = await compare("advance", { image, initialArgs: Uint8Array.from(initial) });
      while (step.kind === "Progressed") step = await compare("advance", { image, state: step.state });
      assert.deepEqual(step.bytes, result.bytes);
    }
  }
  for (const name of ["generator", "scheduler", "reentrant", "cloned", "ownership", "successor-state", "clause-payload"]) {
    const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    const oracle = execute(source, [], name === "generator" ? [[]] : []);
    for (const mode of ["advance", "run"]) {
      const trace = [];
      let step = await compare(mode, { image, initialArgs: new Uint8Array() });
      while (step.kind !== "Completed") {
        let result;
        if (step.kind === "Yielded") trace.push({ kind: step.kind });
        else if (step.kind === "Requested") {
          const request = await decodeRequest(step.request);
          trace.push({ kind: step.kind, identity: request.semanticIdentity, payload: [...request.payload] });
          result = await encodeResult(step.request, new Uint8Array());
        } else assert.equal(step.kind, "Progressed");
        step = await compare(mode, { image, state: step.state, result });
      }
      assert.deepEqual(step.value, Uint8Array.from(oracle.value));
      assert.deepEqual(trace, oracle.trace);
    }
  }
  for (const name of ["resource-scalar", "resource-pair", "scoped-reader", "indexed", "abort-custody", "clause-abort"]) {
    const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    const responses = name === "scoped-reader" ? [[], [], []] : name === "indexed" ? [[37, 0, 0, 0, 0, 0, 0, 0], [1]] : name === "abort-custody" || name === "clause-abort" ? [[]] : [[41, 0, 0, 0, 0, 0, 0, 0], [], []];
    const initialArgs = Uint8Array.from(name === "abort-custody" ? [0] : []);
    const oracle = execute(source, [...initialArgs], responses);
    for (const mode of ["advance", "run"]) {
      const trace = [];
      let step = await compare(mode, { image, initialArgs });
      while (step.kind !== "Completed" && step.kind !== "Failed") {
        let result;
        if (step.kind === "Requested") {
          const request = await decodeRequest(step.request);
          result = await encodeResult(step.request, Uint8Array.from(responses[trace.length]));
          trace.push({ kind: step.kind, identity: request.semanticIdentity, payload: [...request.payload] });
        } else assert.equal(step.kind, "Progressed");
        step = await compare(mode, { image, state: step.state, result });
      }
      assert.equal(step.kind, oracle.kind);
      assert.deepEqual(step.value, Uint8Array.from(oracle.value));
      assert.deepEqual(trace, oracle.trace);
    }
  }
  for (const name of ["queens-dfs", "queens-bfs"]) {
    const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    const responses = [[201, 0, 0, 0, 0, 0, 0, 0], [], [], [202, 0, 0, 0, 0, 0, 0, 0], [], []];
    const oracle = execute(source, [], responses);
    const trace = [];
    let step = await compare("run", { image, initialArgs: new Uint8Array() });
    let requests = 0;
    while (step.kind !== "Completed") {
      let result;
      if (step.kind === "Yielded") trace.push({ kind: step.kind });
      else {
        assert.equal(step.kind, "Requested");
        const request = await decodeRequest(step.request);
        trace.push({ kind: step.kind, identity: request.semanticIdentity, payload: [...request.payload] });
        result = await encodeResult(step.request, Uint8Array.from(responses[requests++]));
      }
      // Every checkpoint crosses a fresh engine. Compare one bounded transition
      // and then the public run boundary from that exact successor in both engines.
      step = await compare("advance", { image, state: step.state, result });
      if (step.kind === "Progressed") step = await compare("run", { image, state: step.state });
    }
    assert.equal(requests, 6);
    assert.deepEqual(step.value, Uint8Array.from(oracle.value));
    assert.deepEqual(trace, oracle.trace);
  }
  for (const name of ["resource-scalar", "resource-pair"]) for (const duringCleanup of [false, true]) {
    const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    const controls = duringCleanup ? [{ at: 2, reason: "stop" }, { at: 2, reason: "later" }] : [{ at: 1, reason: "stop" }, { at: 2, reason: "later" }];
    const number = [41, 0, 0, 0, 0, 0, 0, 0];
    const oracle = execute(source, [], duringCleanup ? [number, [], []] : [number, []], controls);
    const trace = [];
    const observe = async (step) => {
      assert.equal(step.kind, "Requested");
      const request = await decodeRequest(step.request);
      trace.push({ kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload] });
    };
    let step = await compare("run", { image, initialArgs: new Uint8Array() });
    await observe(step);
    step = await compare("run", { image, state: step.state, result: await encodeResult(step.request, Uint8Array.from(number)) });
    await observe(step);
    step = duringCleanup
      ? await compare("run", { image, state: step.state, result: await encodeResult(step.request, new Uint8Array()) })
      : await compare("run", { image, state: step.state, cancel: "stop" });
    await observe(step);
    const obtained = await encodeResult(step.request, new Uint8Array());
    const oldRequest = await decodeRequest(step.request);
    const rebound = await compare("run", { image, state: step.state, cancel: duringCleanup ? "stop" : "later" });
    const newRequest = await decodeRequest(rebound.request);
    assert.deepEqual(newRequest.payload, oldRequest.payload);
    assert.deepEqual(newRequest.resumeSchema, oldRequest.resumeSchema);
    if (duringCleanup) {
      assert.notDeepEqual(newRequest.requestIdentity, oldRequest.requestIdentity);
      await assert.rejects(compare("run", { image, state: rebound.state, result: obtained }), /InvalidResult/);
    } else assert.deepEqual(rebound.bytes, step.bytes);
    const repeated = await compare("run", { image, state: rebound.state, cancel: "later" });
    assert.deepEqual(repeated.bytes, rebound.bytes);
    step = await compare("run", { image, state: repeated.state, result: await encodeResult(repeated.request, new Uint8Array()) });
    assert.equal(step.kind, oracle.kind);
    assert.equal(step.reason, oracle.reason);
    assert.deepEqual(step.cleanupFailures.map((bytes) => [...bytes]), oracle.cleanupFailures);
    assert.deepEqual(trace, oracle.trace);
  }
  for (const primary of [0, 1]) for (const cancel of [false, true]) {
    const source = JSON.parse(await readFile(join(fixtures, "source-unwind.json"), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, "source-unwind.bpi3")));
    const oracle = execute(source, [primary], [[], []], cancel ? [{ at: 0, reason: "stop" }, { at: 0, reason: "later" }] : []);
    const trace = [];
    let step = await compare("run", { image, initialArgs: Uint8Array.of(primary) });
    while (step.kind === "Requested") {
      const request = await decodeRequest(step.request);
      trace.push({ kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload] });
      if (cancel && trace.length === 1) {
        const obtained = await encodeResult(step.request, new Uint8Array());
        step = await compare("run", { image, state: step.state, cancel: "stop" });
        await assert.rejects(compare("run", { image, state: step.state, result: obtained }), /InvalidResult/);
        const repeated = await compare("run", { image, state: step.state, cancel: "later" });
        assert.deepEqual(repeated.bytes, step.bytes);
        step = repeated;
      }
      step = await compare("run", { image, state: step.state, result: await encodeResult(step.request, new Uint8Array()) });
    }
    assert.equal(step.kind, oracle.kind);
    assert.deepEqual(step.value, Uint8Array.from(oracle.value));
    assert.deepEqual(step.cleanupFailures.map((bytes) => [...bytes]), oracle.cleanupFailures);
    assert.equal(step.cancellation, oracle.cancellation ?? null);
    assert.deepEqual(trace, oracle.trace);
  }
  for (const primary of [0, 1]) for (const cancel of [false, true]) {
    const source = JSON.parse(await readFile(join(fixtures, "source-yielding-cleanup.json"), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, "source-yielding-cleanup.bpi3")));
    const oracle = execute(source, [primary], [[], []], cancel ? [{ at: 0, reason: "stop" }, { at: 2, reason: "later" }] : []);
    for (const mode of ["advance", "run"]) {
      const trace = [];
      let yields = 0, requests = 0, transitions = 0;
      let step = await compare(mode, { image, initialArgs: Uint8Array.of(primary) });
      while (step.kind !== "Failed") {
        assert.ok(transitions++ < 1000, "finite cleanup fixture exceeded its test horizon");
        const input = { image, state: step.state };
        if (step.kind === "Yielded") {
          trace.push({ kind: "Yielded" });
          if (cancel) input.cancel = yields === 0 ? "stop" : "later";
          yields++;
        } else if (step.kind === "Requested") {
          const request = await decodeRequest(step.request);
          trace.push({ kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload] });
          input.result = await encodeResult(step.request, new Uint8Array());
          requests++;
        } else assert.equal(step.kind, "Progressed");
        step = await compare(mode, input);
        if (input.cancel !== undefined && step.kind === "Yielded")
          step = await compare(mode, { image, state: step.state });
      }
      assert.equal(yields, 2); assert.equal(requests, 2);
      assert.equal(step.kind, oracle.kind);
      assert.deepEqual(step.value, Uint8Array.from(oracle.value));
      assert.deepEqual(step.cleanupFailures.map(bytes => [...bytes]), oracle.cleanupFailures);
      assert.equal(step.cancellation, oracle.cancellation ?? null);
      assert.deepEqual(trace, oracle.trace);
    }
  }
for (const [name, expected, branches] of [["local-one-shot", 15, [15]], ["local-multi-shot", 32, [15, 17]]]) {
  const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
  const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
  const scalar = n => [n, 0, 0, 0, 0, 0, 0, 0];
  const oracle = execute(source, [], [scalar(10), ...branches.map(() => [])]);
  const expectedTrace = [{ kind: "Requested", identity: "local/producer", payload: [] },
    ...branches.flatMap(n => [{ kind: "Yielded" }, { kind: "Requested", identity: "local/branch", payload: scalar(n) }])];
  assert.deepEqual(oracle, { kind: "Completed", value: scalar(expected), trace: expectedTrace });
  for (const mode of ["run", "advance"]) {
    const trace = [], frontiers = [];
    let step = await compare(mode, { image, initialArgs: new Uint8Array() });
    while (step.kind !== "Completed") {
      assert.ok(frontiers.length < 256, `${name}: inconclusive transition horizon`);
      frontiers.push(step.state);
      let response;
      if (step.kind === "Yielded") trace.push({ kind: "Yielded" });
      else if (step.kind === "Requested") {
        const request = await decodeRequest(step.request);
        trace.push({ kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload] });
        response = await encodeResult(step.request, Uint8Array.from(request.semanticIdentity === "local/producer" ? scalar(10) : []));
      } else assert.equal(step.kind, "Progressed");
      step = await compare(mode, { image, state: step.state, result: response });
    }
    assert.deepEqual([...step.value], scalar(expected));
    assert.deepEqual(trace, expectedTrace);
    // Every portable frontier is restored by both runtimes before cancellation,
    // including captured tokens and each active multi-shot branch.
    for (const state of frontiers) {
      const cancelled = await compare("run", { image, state, cancel: "stop" });
      assert.equal(cancelled.kind, "Cancelled");
      assert.equal(cancelled.reason, "stop");
      assert.deepEqual(cancelled.cleanupFailures, []);
    }
  }
}
assert.deepEqual([...visitedSources].sort(), requiredExamples.toSorted());
assert.deepEqual([...visitedImages].sort(), requiredExamples.toSorted());
console.log(JSON.stringify({ check: "current source oracle/native/WASM agreement", fixtures: requiredExamples.length, observations }));
