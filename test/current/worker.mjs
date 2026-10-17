import { Kernel } from "/src/embedding/index.mjs";
let kernel, session;
self.onmessage = async ({ data }) => {
  try {
    if (data.op === "start" || data.op === "restore") {
      const bytes = new Uint8Array(await (await fetch(data.kernelPath ?? "/kernel.wasm")).arrayBuffer());
      kernel = await Kernel.create({ bytes, expectedSha256: data.sha256 });
      kernel.setLimits({ input: 2 << 20, working: 128 << 20, output: 2 << 20 });
      const prepared = kernel.prepare(new Uint8Array(data.image));
      session = data.op === "start" ? kernel.start(prepared, new Uint8Array(data.initialArgs ?? [])) : kernel.restore(prepared, new Uint8Array(data.state));
      kernel.releasePrepared(prepared);
    }
    const output = kernel.drive(session, { control: data.control ?? "none", value: new Uint8Array(data.value ?? []), quantum: data.quantum ?? null, checkpoint: data.checkpoint ?? false });
    let state = null;
    if (data.transfer) state = Array.from(kernel.checkpoint(session, { transfer: true }));
    if (data.close) kernel.close(session);
    self.postMessage({ output: Array.from(output), state, workingLive: String(kernel.usage().workingLive) });
  } catch (error) {
    self.postMessage({ error: error.code ?? error.message, diagnostic: error.details?.diagnostic });
  }
};
