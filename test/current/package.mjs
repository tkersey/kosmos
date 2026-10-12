import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile, rm, symlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const [runtime, fixtures] = process.argv.slice(2).map(value => resolve(value));
const scratch = await mkdtemp(join(tmpdir(), "kosmos-current-package-"));
try {
  const [packed] = JSON.parse(execFileSync("npm", ["pack", "--offline", "--ignore-scripts", "--json", "--pack-destination", scratch], { cwd: runtime, encoding: "utf8" }));
  const declared = JSON.parse(await readFile(join(runtime, "package.json"), "utf8")).files;
  assert.deepEqual(packed.files.map(file => file.path).sort(), [...declared].sort());
  assert.ok(packed.files.some(file => file.path === "docs/verification.md"));
  const retired = ["process_v2", "kernel-v2", "runtime-prepare.mjs", "runtime-delivery.mjs", "toolchain.mjs"];
  assert.ok(packed.files.every(file => retired.every(name => !file.path.includes(name))));
  const directory = join(scratch, "extracted");
  await mkdir(directory);
  execFileSync("tar", ["-xf", join(scratch, packed.filename), "-C", directory]);
  const root = join(directory, "package");
  const manifest = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
  assert.equal(manifest.version, "7.0.0");
  assert.deepEqual(Object.keys(manifest.exports), ["."]);
  const kosmos = await import(pathToFileURL(join(root, manifest.exports["."])));
  assert.equal(kosmos.packageVersion, manifest.version);
  const kernelPath = join(root, "kosmos-kernel.wasm");
  const bytes = new Uint8Array(await readFile(kernelPath));
  const expectedSha256 = createHash("sha256").update(bytes).digest("hex");
  const image = new Uint8Array(execFileSync(fixtures, ["image", "install"]));
  const input = kosmos.encodeInput({ image, initialArgs: new Uint8Array() });
  const expected = execFileSync(fixtures, ["invoke"], { input });
  const kernel = await kosmos.Kernel.create({ bytes, expectedSha256 });
  // Test an insufficient budget explicitly; optimization can make this fixture
  // fit the default budget without changing the capacity-failure contract.
  const unchanged = input.slice();
  kernel.setLimits({ input: 65536, working: 1, output: 65536 });
  assert.throws(() => kernel.invoke(input), error => error.code === "WORLD_CAPACITY" && error.details.arena === "working");
  assert.deepEqual(input, unchanged);
  kernel.setLimits({ input: 65536, working: 8 << 20, output: 65536 });
  assert.deepEqual(Buffer.from(kernel.invoke(input)), expected);
  const inputPath = join(scratch, "input.pki3");
  await writeFile(inputPath, input);
  const cli = join(root, "bin/kosmos.mjs");
  const args = [cli, "invoke", "--kernel", kernelPath, "--sha256", expectedSha256, "--working-budget", String(8 << 20), "--input", inputPath];
  assert.deepEqual(execFileSync(process.execPath, args, { cwd: scratch }), expected);
  assert.equal(execFileSync(process.execPath, [cli, "--version"], { encoding: "utf8" }).trim(), manifest.version);
  const alias = join(scratch, "alias.pki3");
  await symlink(inputPath, alias);
  assert.deepEqual(execFileSync(process.execPath, [...args.slice(0, -1), alias]), expected);
  const wrong = [...args]; wrong[wrong.indexOf("--sha256") + 1] = "0".repeat(64);
  const rejected = spawnSync(process.execPath, wrong);
  assert.notEqual(rejected.status, 0); assert.equal(rejected.stdout.length, 0);
  const nonfile = spawnSync(process.execPath, [...args.slice(0, -1), scratch]);
  assert.notEqual(nonfile.status, 0); assert.equal(nonfile.stdout.length, 0);
  assert.match(nonfile.stderr.toString(), /WORLD_FILE_NOT_REGULAR/);
  console.log(JSON.stringify({ check: "extracted current runtime and CLI", version: manifest.version, kernelSha256: expectedSha256, files: packed.files.length, packageBytes: packed.size }));
} finally { await rm(scratch, { recursive: true, force: true }); }
