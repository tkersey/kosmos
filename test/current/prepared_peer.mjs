import assert from "node:assert/strict";
import { spawn } from "node:child_process";

// One outstanding command, length-framed binary replies. Keeping the process
// alive shares only Prepared; the peer constructs a fresh Session for each cut.
export function preparedPeer(path) {
  const child = spawn(path, ["prepared-invoke-stream"], { stdio: ["pipe", "pipe", "pipe"] });
  let buffered = Buffer.alloc(0), pending, diagnostic = "", failure;
  const fail = error => { failure = error; pending?.reject(error); pending = undefined; };
  child.stderr.on("data", bytes => { diagnostic = (diagnostic + bytes).slice(-32768); });
  child.on("error", fail);
  child.stdin.on("error", fail);
  child.stdout.on("data", bytes => {
    buffered = Buffer.concat([buffered, bytes]);
    if (buffered.length < 4) return;
    const length = buffered.readUInt32LE();
    if (length < 1 || length > 64 << 20) return fail(new Error("invalid native peer frame"));
    if (buffered.length < length + 4) return;
    if (!pending || buffered.length !== length + 4) return fail(new Error("unsolicited native peer output"));
    const result = { status: buffered[4], stdout: buffered.subarray(5), stderr: buffered.subarray(5).toString() };
    buffered = Buffer.alloc(0);
    const { resolve } = pending;
    pending = undefined;
    resolve(result);
  });
  const exited = new Promise(resolve => child.on("close", (code, signal) => {
    if (pending || code !== 0 || signal) fail(new Error(`native peer exited ${code ?? signal}: ${diagnostic}`));
    resolve({ code, signal });
  }));
  const kill = () => child.kill();
  process.once("exit", kill);
  return {
    invoke(command) {
      if (failure) return Promise.reject(failure);
      assert.equal(pending, undefined, "native peer commands must be serial");
      return new Promise((resolve, reject) => {
        pending = { resolve, reject };
        const size = Buffer.alloc(4);
        size.writeUInt32LE(command.length);
        child.stdin.write(Buffer.concat([size, command]));
      });
    },
    async close() {
      child.stdin.end();
      const result = await exited;
      process.removeListener("exit", kill);
      if (failure) throw failure;
      assert.deepEqual(result, { code: 0, signal: null });
      assert.equal(buffered.length, 0);
    },
  };
}
