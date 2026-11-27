import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { Kernel, decodeOutcome, decodeRequest, encodeResult } from "../../src/embedding/index.mjs";

const [coreKernel, directKernel, inputs, runsText = "5"] = process.argv.slice(2);
const workloads = ["scalar", "scalar_chain", "scalar_chain_large", "dynamic_loop", "structured",
  "repeated_calls", "higher_order", "handlers", "multi_shot", "long_cleanup", "retained_bytes"];
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const word = value => Uint8Array.from({ length: 8 }, (_, i) => Number((BigInt(value) >> BigInt(8 * i)) & 255n));
const kernels = {};
for (const [name, path] of [["core", coreKernel], ["direct", directKernel]]) {
  const bytes = new Uint8Array(readFileSync(path));
  kernels[name] = await Kernel.create({ bytes, expectedSha256: sha(bytes) });
  kernels[name].setLimits({ input: 8 << 20, working: 192 << 20, output: 8 << 20 });
}
const ns = () => process.hrtime.bigint();
async function execute(kernel, image, args, sample) {
  const prepared = kernel.prepare(image);
  const session = kernel.start(prepared, args);
  const transcript = [];
  let driveNs = 0n, options = { quantum: 256, checkpoint: true };
  for (;;) {
    const started = ns();
    const encoded = kernel.drive(session, options);
    driveNs += ns() - started;
    transcript.push(sha(encoded));
    const outcome = decodeOutcome(encoded);
    if (outcome.kind === "progressed") options = { quantum: 256, checkpoint: true };
    else if (outcome.kind === "yielded") options = { quantum: 256, checkpoint: true, control: "resume_yield" };
    else if (outcome.kind === "requested") {
      const request = await decodeRequest(outcome.request);
      const value = request.semanticIdentity === "local/producer" ? word(41 + sample * 19) : new Uint8Array();
      options = { quantum: 256, checkpoint: true, control: "reply", value: await encodeResult(outcome.request, value) };
    } else break;
  }
  kernel.close(session);
  kernel.releasePrepared(prepared);
  return { driveNs: Number(driveNs), transcript };
}
const median = values => {
  const sorted = [...values].sort((x, y) => x - y), middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
for (const workload of workloads) {
  const image = new Uint8Array(readFileSync(join(inputs, `${workload}.bpi3`)));
  for (let sample = 0; sample < 3; sample++) {
    const args = new Uint8Array(readFileSync(join(inputs, `${workload}-${sample}.args`)));
    const timings = { core: [], direct: [] };
    let reference;
    for (let run = 0; run < Number(runsText); run++) {
      for (const name of ["core", "direct"]) {
        const result = await execute(kernels[name], image, args, sample);
        reference ??= result.transcript;
        assert.deepEqual(result.transcript, reference, `${workload}/${sample}: ${name} transcript changed`);
        timings[name].push(result.driveNs);
      }
    }
    const core = median(timings.core) / 1e6, direct = median(timings.direct) / 1e6;
    console.log(JSON.stringify({ workload, sample, runs: Number(runsText), cuts: reference.length,
      core_ms: core, direct_ms: direct, speedup: core / direct }));
  }
}
