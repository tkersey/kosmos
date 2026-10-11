// Environment-neutral byte embedding: no filesystem, Node imports, or policy callbacks.
import { compileKernelWasm, wasmRange } from "./wasm.mjs";
import { copyBytes, u64, UTF8 } from "./wire.mjs";
import { decodeOutcome } from "./codec.mjs";
import { kosmosError } from "./errors.mjs";
const authority = Symbol("admitted kernel");
const empty = new Uint8Array();

export class Kernel {
  #guest; #module; #identity; #tokens = new WeakMap();
  static async create({ bytes, expectedSha256, instanceId }) {
    const module = await compileKernelWasm(bytes, expectedSha256);
    const instance = await WebAssembly.instantiate(module, {});
    if (instanceId === undefined) {
      const words = crypto.getRandomValues(new Uint32Array(2));
      instanceId = (BigInt(words[0]) << 32n) | BigInt(words[1]);
      if (instanceId === 0n) instanceId = 1n;
    }
    return new Kernel(authority, module, instance.exports, u64(instanceId));
  }
  constructor(token, module, guest, identity) {
    if (token !== authority) throw new TypeError("use Kernel.create");
    this.#module = module; // Keep the admitted code alive only with its Kernel.
    this.#guest = guest; this.#identity = identity;
    if (guest.world_abi_version() !== 3) throw kosmosError("WORLD_KERNEL_ABI_INVALID", "Kernel ABI is not version 3");
    this.#status(guest.world_initialize(identity));
  }
  #bytes() { return new Uint8Array(wasmRange(this.#guest.memory, this.#guest.world_output_ptr(), this.#guest.world_output_len(), "output")); }
  #status(status) {
    if (status === 0) return;
    if (status === 1) {
      const capacity = decodeOutcome(this.#bytes());
      if (capacity.kind !== "needs_capacity") throw kosmosError("WORLD_KERNEL_PROTOCOL_INVALID", "Capacity status lacks a capacity outcome");
      const bound = capacity[capacity.arena === "memory" ? "memoryPages" : capacity.arena];
      throw kosmosError("WORLD_CAPACITY", "Kernel requires more physical capacity", { arena: capacity.arena, amount: bound.bytes, provenance: bound.provenance });
    }
    const diagnostic = UTF8.decode(wasmRange(this.#guest.memory, this.#guest.world_error_ptr(), this.#guest.world_error_len(), "diagnostic"));
    throw kosmosError("WORLD_KERNEL_REJECTED", "Kernel rejected the operation", {
      diagnostic: /^[A-Za-z][A-Za-z0-9]{0,127}$/.test(diagnostic) ? diagnostic : "UnknownKernelError",
    });
  }
  #stage(bytes) {
    const owned = copyBytes(bytes);
    this.#status(this.#guest.world_prepare_input(this.#identity, BigInt(owned.length)));
    wasmRange(this.#guest.memory, this.#guest.world_input_ptr(), BigInt(owned.length), "input").set(owned);
    return BigInt(owned.length);
  }
  #token(kind, handle) {
    if (handle <= 0n) throw kosmosError("WORLD_KERNEL_HANDLE_INVALID", "Kernel returned an invalid handle");
    const token = Object.freeze({ kind });
    this.#tokens.set(token, { kind, handle, live: true });
    return token;
  }
  #handle(token, kind) {
    const entry = this.#tokens.get(token);
    if (!entry || !entry.live || entry.kind !== kind) throw kosmosError("WORLD_HANDLE_INVALID", "Handle is released or belongs to another kernel");
    return entry;
  }
  setLimits({ input, working, output }) {
    this.#status(this.#guest.world_set_limits(this.#identity, u64(input), u64(working), u64(output)));
  }
  invoke(command) {
    const length = this.#stage(command);
    this.#status(this.#guest.world_invoke(this.#identity, length));
    return this.#bytes();
  }
  prepare(image) {
    const length = this.#stage(image);
    this.#status(this.#guest.world_prepare(this.#identity, length));
    return this.#token("prepared", this.#guest.world_prepared_handle());
  }
  releasePrepared(token) {
    const entry = this.#handle(token, "prepared");
    this.#status(this.#guest.world_release_prepared(this.#identity, entry.handle));
    entry.live = false;
  }
  start(token, args = empty) {
    const entry = this.#handle(token, "prepared"), length = this.#stage(args);
    this.#status(this.#guest.world_start(this.#identity, entry.handle, length));
    return this.#token("session", this.#guest.world_session_handle());
  }
  restore(token, state) {
    const entry = this.#handle(token, "prepared"), length = this.#stage(state);
    this.#status(this.#guest.world_restore(this.#identity, entry.handle, length));
    return this.#token("session", this.#guest.world_session_handle());
  }
  drive(token, { control = "none", value = empty, quantum = null, checkpoint = false } = {}) {
    const entry = this.#handle(token, "session");
    const tags = { none: 0, reply: 1, resume_yield: 2, cancel_text: 3, cancel_bytes: 4 };
    if (typeof control !== "string" || !Object.hasOwn(tags, control) || typeof checkpoint !== "boolean") throw new TypeError("invalid drive options");
    const bytes = typeof value === "string" ? new TextEncoder().encode(value) : copyBytes(value);
    if ((control === "none" || control === "resume_yield") && bytes.length) throw new TypeError("control takes no payload");
    const limit = quantum === null ? 0n : u64(quantum);
    const length = this.#stage(bytes);
    this.#status(this.#guest.world_drive(this.#identity, entry.handle, tags[control], quantum === null ? 0 : 1, limit, checkpoint ? 1 : 0, length));
    return this.#bytes();
  }
  checkpoint(token, { transfer = false } = {}) {
    if (typeof transfer !== "boolean") throw new TypeError("transfer must be Boolean");
    const entry = this.#handle(token, "session");
    this.#status(this.#guest.world_checkpoint(this.#identity, entry.handle, transfer ? 1 : 0));
    const bytes = this.#bytes();
    if (transfer) entry.live = false;
    return bytes;
  }
  close(token) {
    const entry = this.#handle(token, "session");
    this.#status(this.#guest.world_close(this.#identity, entry.handle));
    entry.live = false;
  }
  usage() {
    return Object.freeze({ workingLive: this.#guest.world_working_live(), workingPeak: this.#guest.world_working_peak(), memoryBytes: this.#guest.memory.buffer.byteLength });
  }
}
