// Byte-only public entry point. This module also loads in a browser Worker.
export const packageVersion = "9.1.0";
export { Kernel } from "./kernel.mjs";
export { encodeInput, decodeOutcome, decodeRequest, encodeResult, validateValue } from "./codec.mjs";
export { inspectKernelWasm } from "./wasm.mjs";
