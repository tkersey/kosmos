// Copyright (c) 2026 World contributors. MIT license.
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { kosmosError } from "../embedding/errors.mjs";

/** Read one opened regular-file extent and reject changes during the read. */
export async function readRegularFile(path, validateLength) {
  const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK | (constants.O_CLOEXEC ?? 0));
  try {
    const before = await file.stat({ bigint: true });
    if (!before.isFile()) throw kosmosError("WORLD_FILE_NOT_REGULAR", "Input must resolve to a regular file");
    validateLength?.(before.size);
    if (before.size > BigInt(Number.MAX_SAFE_INTEGER)) throw kosmosError("WORLD_LENGTH_UNSAFE", "Input file is too large to materialize");
    const bytes = Buffer.alloc(Number(before.size));
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesRead } = await file.read(bytes, offset, bytes.length - offset, offset);
      if (bytesRead === 0) throw kosmosError("WORLD_FILE_CHANGED", "Input file changed while reading");
      offset += bytesRead;
    }
    const after = await file.stat({ bigint: true });
    validateLength?.(after.size);
    if (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) {
      throw kosmosError("WORLD_FILE_CHANGED", "Input file changed while reading");
    }
    return bytes;
  } finally { await file.close(); }
}
