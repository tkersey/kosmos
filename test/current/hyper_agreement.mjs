import assert from "node:assert/strict";
import { join } from "node:path";
import { decodeRequest, encodeResult, decodeOutcome } from "../../src/embedding/index.mjs";

const pure = [
  ["constant_peer", 42], ["ignored_argument", 43], ["unused_query", 42],
  ["ignored_successor", 42], ["demanded_successor", 42], ["lazy_product", 23],
  ["lazy_sum", 1], ["lazy_stream", 1], ["stream_head", 23],
  ["identity_project", 42], ["run_constant", 42], ["nested_need", 1103],
];
const tasks = [
  ["obtain", [], 7], ["run", [20, 10, 21, 205, 215], 35],
  ["repeated", [20, 10, 21, 205, 10, 21, 205, 230], 50],
  ["adaptive", [20, 10, 21, 205, 10, 21, 205, 230], 50],
  ["dispose", [20, 10, 21, 205], 99],
];
export const hyperExamples = [
  ...pure.map(([name]) => `hyper_${name}`),
  ...tasks.map(([name]) => `hyper_task_${name}`), "hyper_composition",
  ...["obtain", "resume", "repeated", "dispose", "local"].map(name => `hyper_captured_${name}`),
];
const word = value => {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64LE(BigInt(value));
  return [...bytes];
};
const requestTrace = request => ({
  kind: "Requested", identity: request.semanticIdentity, payload: [...request.payload],
});
function terminal(step, oracle) {
  assert.equal(step.kind.toLowerCase(), oracle.kind.toLowerCase());
  assert.deepEqual([...step.value], oracle.value);
  assert.deepEqual(step.cleanupFailures ?? [], oracle.cleanupFailures ?? []);
}

async function resident(host, prepare, image, responses, oracle, initialArgs = new Uint8Array()) {
  const session = host.start(prepare(image), initialArgs);
  const trace = [];
  let step = decodeOutcome(host.drive(session)), replies = 0;
  while (step.kind === "requested") {
    trace.push(requestTrace(await decodeRequest(step.request)));
    assert(replies < responses.length);
    const value = await encodeResult(step.request, Uint8Array.from(responses[replies++]));
    step = decodeOutcome(host.drive(session, { control: "reply", value }));
  }
  terminal(step, oracle);
  assert.deepEqual(trace, oracle.trace);
  assert.equal(replies, responses.length);
  host.close(session);
}

async function restored(compare, image, initialArgs, responses, oracle, mode) {
  let step = await compare(mode, { image, initialArgs });
  let replies = 0, transitions = 0;
  const trace = [], requests = [];
  while (["Progressed", "Yielded", "Requested"].includes(step.kind)) {
    assert(++transitions < 20000, "inconclusive hyperfunction transition horizon");
    let result;
    if (step.kind === "Requested") {
      requests.push(step.state);
      trace.push(requestTrace(await decodeRequest(step.request)));
      assert(replies < responses.length);
      result = await encodeResult(step.request, Uint8Array.from(responses[replies++]));
    } else assert.equal(step.kind, "Progressed");
    step = await compare(mode, { image, state: step.state, result });
  }
  terminal(step, oracle);
  assert.deepEqual(trace, oracle.trace);
  assert.equal(replies, responses.length);
  if (mode === "advance") {
    for (const state of requests) {
      const cancelled = await compare("run", { image, state, cancel: "stop" });
      assert.equal(cancelled.kind, "Cancelled");
      assert.equal(cancelled.reason, "stop");
      assert.deepEqual(cancelled.cleanupFailures, []);
    }
  }
  return transitions + 1;
}

export async function hyperAgreement({ fixtures, readFile, selected, compare, execute, host, prepare }) {
  const costs = [];
  async function load(name) {
    const source = JSON.parse(await readFile(join(fixtures, `source-${name}.json`), "utf8"));
    const image = new Uint8Array(await readFile(join(fixtures, `source-${name}.bpi3`)));
    return { source, image };
  }
  for (const [suffix, value] of pure) {
    const name = `hyper_${suffix}`;
    if (!selected(name)) continue;
    const { source, image } = await load(name);
    const oracle = execute(source, []);
    assert.deepEqual(oracle, { kind: "Completed", value: word(value), trace: [] });
    for (const mode of ["run", "advance"]) {
      const calls = await restored(compare, image, new Uint8Array(), [], oracle, mode);
      if (mode === "advance") costs.push({ fixture: name, invocations: calls });
    }
  }
  for (const [suffix, payloads, value] of tasks) {
    const name = `hyper_task_${suffix}`;
    if (!selected(name)) continue;
    const { source, image } = await load(name);
    const responses = payloads.map(() => word(5));
    const oracle = execute(source, [], responses);
    assert.deepEqual(oracle, {
      kind: "Completed", value: word(value),
      trace: payloads.map(value => ({ kind: "Requested", identity: "hyper/task", payload: word(value) })),
    });
    await resident(host, prepare, image, responses, oracle);
    for (const mode of ["run", "advance"]) {
      const calls = await restored(compare, image, new Uint8Array(), responses, oracle, mode);
      if (mode === "advance") costs.push({ fixture: name, invocations: calls });
    }
    if (suffix === "adaptive") {
      const onceReplies = [5, 5, 3, 5, 5].map(word);
      const once = execute(source, [], onceReplies);
      assert.deepEqual(once, {
        kind: "Completed", value: word(33),
        trace: [20, 10, 21, 203, 213].map(value => ({
          kind: "Requested", identity: "hyper/task", payload: word(value),
        })),
      });
      await resident(host, prepare, image, onceReplies, once);
      for (const mode of ["run", "advance"]) {
        const calls = await restored(compare, image, new Uint8Array(), onceReplies, once, mode);
        if (mode === "advance") costs.push({ fixture: name, scenario: "once", invocations: calls });
      }
    }
    if (suffix === "run") {
      const overflowReplies = [word(5), word(5), word((1n << 64n) - 1n)];
      const failed = execute(source, [], overflowReplies);
      assert.equal(failed.kind, "Failed");
      assert.deepEqual(failed.value, []);
      await resident(host, prepare, image, overflowReplies, failed);
      for (const mode of ["run", "advance"]) {
        const calls = await restored(compare, image, new Uint8Array(), overflowReplies, failed, mode);
        if (mode === "advance") costs.push({ fixture: name, scenario: "overflow", invocations: calls });
      }
    }
  }
  for (const kind of ["obtain", "resume", "repeated", "dispose"]) {
    const name = `hyper_captured_${kind}`;
    if (!selected(name)) continue;
    const { source, image } = await load(name);
    for (const [producer, consumer] of [[10, 20], [3, 40]]) {
      const produced = [producer, consumer, producer, producer + 5, producer + 100];
      const payloads = kind === "obtain" ? [] : kind === "dispose"
        ? [consumer, ...produced, consumer, consumer + 100] : kind === "repeated"
          ? [consumer, ...produced, consumer, ...produced, consumer,
            consumer + 2 * (producer + 5), consumer + 100, consumer + 100]
          : [consumer, ...produced, consumer, consumer + producer + 5, consumer + 100];
      const value = kind === "obtain" ? 7 : kind === "dispose" ? consumer
        : consumer + (kind === "repeated" ? 2 : 1) * (producer + 5);
      const initialArgs = Uint8Array.from([...word(producer), ...word(consumer)]);
      const responses = payloads.map(() => word(5));
      const oracle = execute(source, [...initialArgs], responses);
      assert.deepEqual(oracle, {
        kind: "Completed", value: word(value),
        trace: payloads.map(value => ({
          kind: "Requested", identity: "hyper/captured", payload: word(value),
        })),
      });
      await resident(host, prepare, image, responses, oracle, initialArgs);
      for (const mode of ["run", "advance"]) {
        const calls = await restored(compare, image, initialArgs, responses, oracle, mode);
        if (mode === "advance") costs.push({
          fixture: name, producer, consumer, invocations: calls,
        });
      }
    }
  }
  if (selected("hyper_captured_local")) {
    const name = "hyper_captured_local";
    const { source, image } = await load(name);
    const responses = [word(5), word(5)];
    const oracle = execute(source, [], responses);
    assert.deepEqual(oracle, {
      kind: "Completed", value: word(13),
      trace: [7, 7].map(value => ({
        kind: "Requested", identity: "hyper/captured", payload: word(value),
      })),
    });
    await resident(host, prepare, image, responses, oracle);
    for (const mode of ["run", "advance"]) {
      const calls = await restored(compare, image, new Uint8Array(), responses, oracle, mode);
      if (mode === "advance") costs.push({ fixture: name, invocations: calls });
    }
  }
  if (selected("hyper_composition")) {
    const { source, image } = await load("hyper_composition");
    for (let value = 0; value < 256; value++) {
      const initial = [value], oracle = execute(source, initial);
      assert.deepEqual(oracle, {
        kind: "Completed", value: [...word(2 * (value + 3)), Number(value === 7)], trace: [],
      });
      await restored(compare, image, Uint8Array.from(initial), [], oracle, "run");
      if (value === 0 || value === 7 || value === 255) {
        const calls = await restored(compare, image, Uint8Array.from(initial), [], oracle, "advance");
        costs.push({ fixture: "hyper_composition", input: value, invocations: calls });
      }
    }
  }
  console.log(JSON.stringify({ check: "typed hyperfunction quantum-one observations", costs }));
}
