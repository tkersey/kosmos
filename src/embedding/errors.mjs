const typedArrayTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;

const CODE_PATTERN = /^WORLD_[A-Z0-9]+(?:_[A-Z0-9]+)*$/;

/** Realm-independent recognition of the exact Uint8Array intrinsic brand. */
export function isUint8Array(value) {
  try { return typedArrayTag.call(value) === "Uint8Array"; } catch { return false; }
}

/**
 * The single public error type produced by the Process host.
 *
 * Messages and details are deliberately metadata-only. Callers must not attach
 * program, state, effect, result, failure, or kernel diagnostic bytes.
 */
export class KosmosHostError extends Error {
  constructor(code, message, details = undefined) {
    if (typeof code !== "string" || !CODE_PATTERN.test(code)) {
      throw new TypeError("KosmosHostError code must be a stable WORLD_* code");
    }
    if (typeof message !== "string" || message.length === 0) {
      throw new TypeError("KosmosHostError message must be a nonempty string");
    }

    super(message);
    this.name = "KosmosHostError";
    Object.defineProperty(this, "code", {
      configurable: false,
      enumerable: true,
      value: code,
      writable: false,
    });
    if (details !== undefined) {
      Object.defineProperty(this, "details", {
        configurable: false,
        enumerable: true,
        value: freezeDetails(details),
        writable: false,
      });
    }
    Object.freeze(this);
  }
}

export function kosmosError(code, message, details = undefined) {
  return new KosmosHostError(code, message, details);
}

function freezeDetails(details) {
  if (details === null || typeof details !== "object" || Array.isArray(details)) {
    throw new TypeError("KosmosHostError details must be a metadata record");
  }

  const copy = Object.create(null);
  for (const [key, value] of Object.entries(details)) {
    if (typeof key !== "string" || !isSafeDetail(value)) {
      throw new TypeError("KosmosHostError details must contain only safe metadata");
    }
    copy[key] = value;
  }
  return Object.freeze(copy);
}

function isSafeDetail(value) {
  return value === null ||
    typeof value === "string" ||
    typeof value === "boolean" ||
    typeof value === "bigint" ||
    (typeof value === "number" && Number.isFinite(value));
}
