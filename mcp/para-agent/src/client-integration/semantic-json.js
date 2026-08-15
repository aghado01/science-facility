import { createHash } from "node:crypto";

export const SEMANTIC_JSON_VERSION = 1;

function compareCodeUnits(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function assertWellFormedString(value) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        throw new TypeError("semantic JSON strings must be well-formed Unicode");
      }
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      throw new TypeError("semantic JSON strings must be well-formed Unicode");
    }
  }
}

function serialize(value, ancestors) {
  if (value === null) return "null";

  switch (typeof value) {
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) {
        throw new TypeError("semantic JSON numbers must be finite");
      }
      return Object.is(value, -0) ? "0" : JSON.stringify(value);
    case "string":
      assertWellFormedString(value);
      return JSON.stringify(value);
    case "object":
      break;
    default:
      throw new TypeError(`semantic JSON does not support ${typeof value}`);
  }

  if (ancestors.has(value)) {
    throw new TypeError("semantic JSON does not support cycles");
  }
  ancestors.add(value);
  try {
    if (Array.isArray(value)) {
      for (let index = 0; index < value.length; index += 1) {
        if (!Object.hasOwn(value, index)) {
          throw new TypeError("semantic JSON does not support sparse arrays");
        }
      }
      return `[${value.map((item) => serialize(item, ancestors)).join(",")}]`;
    }

    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw new TypeError("semantic JSON accepts only plain objects and arrays");
    }
    if (Object.getOwnPropertySymbols(value).length > 0) {
      throw new TypeError("semantic JSON does not support symbol keys");
    }

    const keys = Object.keys(value).sort(compareCodeUnits);
    const properties = keys.map((key) => {
      assertWellFormedString(key);
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (!descriptor || !("value" in descriptor)) {
        throw new TypeError("semantic JSON does not support accessor properties");
      }
      return `${JSON.stringify(key)}:${serialize(descriptor.value, ancestors)}`;
    });
    return `{${properties.join(",")}}`;
  } finally {
    ancestors.delete(value);
  }
}

export function canonicalSemanticJson(value, { version = SEMANTIC_JSON_VERSION } = {}) {
  if (version !== SEMANTIC_JSON_VERSION) {
    throw new RangeError(`unsupported semantic JSON version: ${version}`);
  }
  return serialize({ semantic_json_version: version, value }, new Set());
}

export function semanticSha256(value, options) {
  return createHash("sha256").update(canonicalSemanticJson(value, options), "utf8").digest("hex");
}

export function deepFreeze(value, seen = new Set()) {
  if (value === null || (typeof value !== "object" && typeof value !== "function")) {
    return value;
  }
  if (seen.has(value)) return value;
  seen.add(value);
  for (const key of Reflect.ownKeys(value)) {
    deepFreeze(value[key], seen);
  }
  return Object.freeze(value);
}
