import { createHash } from "node:crypto";
import { lstat, readdir, mkdtemp, mkdir, writeFile, chmod, rm } from "node:fs/promises";
import { resolve, join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { readRegularFile } from "./file-input.mjs";
import { Kernel } from "../embedding/index.mjs";
import { inspectKernelWasm } from "../embedding/wasm.mjs";
import runtimeProfile from "./runtime-profile.json" with { type: "json" };
// Historical v1 admission policy is independent of current native source pins.
const packageVersion = "6.0.0";
Object.freeze(runtimeProfile.defaults);
Object.freeze(runtimeProfile.boundary);
Object.freeze(runtimeProfile.features);
Object.freeze(runtimeProfile);

export const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
export const requiredChecks = Object.freeze([
  "dependency-package", "toolchain-unchanged",
  "check", "check-release-fast", "delivered-kernel", "delivered-package",
  "delivered-source", "delivered-capacity", "delivered-transfer", "portable-smoke",
]);
export function reject(code, message) { throw Object.assign(new Error(message), { code }); }
export async function readBounded(path, limit = 64 << 20) {
  return readRegularFile(path, size => {
    if (size > BigInt(limit)) reject("WORLD_BUNDLE_INVALID", `file exceeds ${limit} bytes: ${path}`);
  });
}
// Delivery preserves executable intent, not producer umask or privileged bits.
export const bundleFileMode = mode => mode & 0o111 ? 0o755 : 0o644;

async function scanInventory(root, prefix = "", entries = [], count = { value: 0 }) {
  if (entries.length > 512) reject("WORLD_BUNDLE_INVALID", "bundle exceeds 512 files");
  for (const name of (await readdir(join(root, prefix))).sort()) {
    if (++count.value > 1024 || prefix.split("/").length > 16) reject("WORLD_BUNDLE_INVALID", "bundle structure limit exceeded");
    const path = prefix ? `${prefix}/${name}` : name;
    if (!/^[A-Za-z0-9_.\/-]+$/.test(path)) reject("WORLD_BUNDLE_INVALID", `unsafe path: ${path}`);
    const stat = await lstat(join(root, path));
    if (stat.isSymbolicLink()) reject("WORLD_BUNDLE_INVALID", `symlink: ${path}`);
    if (stat.isDirectory()) {
      await scanInventory(root, path, entries, count);
    }
    else if (stat.isFile()) {
      const bytes = await readBounded(join(root, path));
      entries.push({ path, bytes: bytes.length, sha256: sha256(bytes), mode: stat.mode & 0o777 });
    } else reject("WORLD_BUNDLE_INVALID", `not a regular file: ${path}`);
  }
  if (entries.length > 512) reject("WORLD_BUNDLE_INVALID", "bundle exceeds 512 files");
  return entries.sort((a, b) => a.path.localeCompare(b.path, "en"));
}
export async function inventory(root) {
  const files = await scanInventory(root);
  for (const file of files) file.mode = bundleFileMode(file.mode);
  return files;
}
export async function verifyInventory(root, expected) {
  if (!/^[a-f0-9]{64}$/.test(expected ?? ""))
    reject("WORLD_BUNDLE_IDENTITY_INVALID", "an external manifest SHA-256 is required");
  if (!(await lstat(root)).isDirectory()) reject("WORLD_BUNDLE_INVALID", "root must be a directory");
  const bytes = await readBounded(join(root, "manifest.json"), 1 << 20);
  if (sha256(bytes) !== expected) reject("WORLD_BUNDLE_IDENTITY_INVALID", "manifest digest mismatch");
  let manifest;
  try { manifest = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { reject("WORLD_BUNDLE_INVALID", "malformed manifest"); }
  if (manifest.format !== "world-runtime-bundle/v1" || !Array.isArray(manifest.files) ||
      manifest.files.length > 511) reject("WORLD_BUNDLE_INVALID", "unsupported manifest structure");
  const paths = new Set();
  for (const file of manifest.files) {
    if (!file || typeof file.path !== "string" || !/^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/.test(file.path) ||
        file.path.split("/").some(part => part === "." || part === "..") ||
        file.path === "manifest.json" || paths.has(file.path) ||
        !Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > (64 << 20) ||
        !/^[a-f0-9]{64}$/.test(file.sha256) || ![0o644, 0o755].includes(file.mode))
      reject("WORLD_BUNDLE_INVALID", "invalid inventory entry");
    paths.add(file.path);
  }
  const actual = (await inventory(root)).filter(file => file.path !== "manifest.json");
  if (actual.length !== manifest.files.length) reject("WORLD_BUNDLE_CORRUPT", "missing or unexpected bundle file");
  for (let i = 0; i < actual.length; i++) {
    const a = actual[i], b = manifest.files[i];
    if (a.path !== b.path || a.bytes !== b.bytes || a.sha256 !== b.sha256 || a.mode !== b.mode)
      reject("WORLD_BUNDLE_CORRUPT", `file identity mismatch: ${a.path}`);
  }
  for (const path of ["runtime/world-kernel.wasm", "runtime/package.json", "runtime/bin/world.mjs",
    "runtime/src/node/runtime-bundle.mjs", "runtime/src/node/runtime-profile.json",
    "runtime/src/embedding/index.mjs", "qualification.json",
    "runtime/LICENSE", "smoke/pure.bpi3", "smoke/effect.bpi3"])
    if (!paths.has(path)) reject("WORLD_BUNDLE_INCOMPLETE", `required file missing: ${path}`);
  return manifest;
}

/** Return the same bounded bytes whose identity matches the supplied inventory. */
export async function readVerifiedFile(root, manifest, path, limit = 64 << 20) {
  const entry = manifest.files.find(file => file.path === path);
  if (!entry) reject("WORLD_BUNDLE_INCOMPLETE", `required file missing: ${path}`);
  const bytes = await readBounded(join(root, path), limit);
  if (bytes.length !== entry.bytes || sha256(bytes) !== entry.sha256)
    reject("WORLD_BUNDLE_CORRUPT", `file identity mismatch: ${path}`);
  return bytes;
}

async function useInventoryCopy(root, manifest, expected, use) {
  const copy = await mkdtemp(join(tmpdir(), "kosmos verified bundle "));
  try {
    const manifestBytes = await readBounded(join(root, "manifest.json"), 1 << 20);
    if (sha256(manifestBytes) !== expected)
      reject("WORLD_BUNDLE_IDENTITY_INVALID", "manifest changed before snapshot");
    await writeFile(join(copy, "manifest.json"), manifestBytes, { flag: "wx", mode: 0o400 });
    // At most one bounded file buffer is retained during copying. The private
    // tree holds at most the already admitted file count and extents.
    for (const entry of manifest.files) {
      const stat = await lstat(join(root, entry.path));
      if (!stat.isFile()) reject("WORLD_BUNDLE_INVALID", `not a regular file: ${entry.path}`);
      if (bundleFileMode(stat.mode) !== entry.mode)
        reject("WORLD_BUNDLE_CORRUPT", `file mode changed before snapshot: ${entry.path}`);
      const mode = entry.mode & 0o111 ? 0o500 : 0o400;
      const bytes = await readVerifiedFile(root, manifest, entry.path);
      const destination = join(copy, entry.path);
      await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
      await writeFile(destination, bytes, { flag: "wx", mode });
      await chmod(destination, mode);
    }
    return await use(copy, manifest);
  } finally {
    await rm(copy, { recursive: true, force: true });
  }
}

/** Callback-scoped inventory snapshot; full runtime qualification is separate. */
export async function withVerifiedInventory(root, expected, use) {
  root = resolve(root);
  return useInventoryCopy(root, await verifyInventory(root, expected), expected, use);
}

export async function verifyBundle(root, expected, smoke = false) {
  root = resolve(root);
  const manifest = await verifyInventory(root, expected);
  if (manifest.kernel?.abi !== 3 || manifest.packageVersion !== packageVersion ||
      manifest.kernel.path !== "runtime/world-kernel.wasm" ||
      manifest.build?.target !== runtimeProfile.target || manifest.build.kernelMode !== runtimeProfile.kernelMode)
    reject("WORLD_BUNDLE_INCOMPATIBLE", "unsupported ABI, package or build profile");
  if (!/^[a-f0-9]{40}$/.test(manifest.source?.commit ?? "") ||
      !/^[a-f0-9]{40}$/.test(manifest.source?.tree ?? "") || manifest.source.clean !== true ||
      manifest.source.repository !== "https://github.com/tkersey/world" ||
      manifest.source.dependency?.commit !== runtimeProfile.boundary.commit ||
      manifest.source.dependency?.package !== runtimeProfile.boundary.package ||
      !/^[a-f0-9]{64}$/.test(manifest.source.dependency?.lockSha256 ?? "") ||
      manifest.build.zig !== runtimeProfile.zig || manifest.build.hostMode !== runtimeProfile.hostMode ||
      manifest.build.backend !== runtimeProfile.wasmBackend || manifest.build.linker !== runtimeProfile.wasmLinker ||
      manifest.build.cpu !== runtimeProfile.cpu ||
      manifest.build.stackBytes !== runtimeProfile.stackBytes || manifest.build.maximumMemoryBytes !== runtimeProfile.maximumMemoryBytes ||
      manifest.build.defaults?.input !== runtimeProfile.defaults.input || manifest.build.defaults?.working !== runtimeProfile.defaults.working || manifest.build.defaults?.output !== runtimeProfile.defaults.output)
    reject("WORLD_BUNDLE_INCOMPATIBLE", "missing or incompatible source/build profile");
  if (manifest.source.dependency?.inventorySha256 !== runtimeProfile.boundary.inventorySha256 ||
      manifest.build.toolchain?.version !== runtimeProfile.zig ||
      !/^[a-f0-9]{64}$/.test(manifest.build.toolchain?.executableIdentity?.sha256 ?? "") ||
      !/^[a-f0-9]{64}$/.test(manifest.build.toolchain?.libraryInventorySha256 ?? "") ||
      JSON.stringify(manifest.build.features) !== JSON.stringify(runtimeProfile.features))
    reject("WORLD_BUNDLE_INCOMPATIBLE", "missing toolchain or consumed-package identity");
  const pkg = JSON.parse(await readVerifiedFile(root, manifest, "runtime/package.json", 65536));
  if (pkg.name !== "@tkersey/world" || pkg.version !== packageVersion || pkg.type !== "module" ||
      pkg.exports?.["."] !== "./src/embedding/index.mjs" || pkg.bin?.world !== "./bin/world.mjs")
    reject("WORLD_BUNDLE_INCOMPATIBLE", "package metadata differs from its embedding");
  const qualification = JSON.parse(await readVerifiedFile(root, manifest, "qualification.json", 1 << 20));
  if (JSON.stringify(manifest.requiredChecks) !== JSON.stringify(requiredChecks) ||
      !Array.isArray(qualification.checks) || requiredChecks.some(name =>
        qualification.checks.filter(check => check.name === name).length !== 1 ||
        qualification.checks.find(check => check.name === name)?.status !== "passed"))
    reject("WORLD_BUNDLE_INCOMPLETE", "required qualification has not passed");
  const bytes = await readVerifiedFile(root, manifest, manifest.kernel.path);
  if (bytes.length !== manifest.kernel.bytes || sha256(bytes) !== manifest.kernel.sha256)
    reject("WORLD_BUNDLE_IDENTITY_INVALID", "kernel identity mismatch");
  const profile = inspectKernelWasm(bytes);
  if (profile.importCount !== 0 || profile.memory.maximumPages !== runtimeProfile.maximumMemoryBytes / 65536 || profile.memory.shared ||
      JSON.stringify(profile) !== JSON.stringify(manifest.build.wasm))
    reject("WORLD_BUNDLE_INCOMPATIBLE", "unsupported memory/import profile");
  await Kernel.create({ bytes, expectedSha256: manifest.kernel.sha256 });
  if (smoke) {
    const { runSmoke } = await import("./runtime-smoke.mjs");
    await useInventoryCopy(root, manifest, expected,
      copy => runSmoke(copy, manifest.kernel.sha256));
  }
  return { manifestSha256: expected, kernelSha256: manifest.kernel.sha256, files: manifest.files.length, smoke };
}
