/**
 * Immutable receiver-native trace sink.
 *
 * This layer writes bytes and records caller-declared frame boundaries. It does
 * not parse, normalize, classify, or coerce native data.
 */

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const SAFE_KEY = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const WINDOWS_DEVICE = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i;
const OMISSION_CODE = /^[A-Z][A-Z0-9_]*$/;

export class RawTraceError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = "RawTraceError";
    this.code = code;
    if (details !== undefined) this.details = details;
  }
}

function nonEmptyString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", `${label} must be a non-empty string`);
  }
  return value;
}

function safeKey(value, label) {
  nonEmptyString(value, label);
  if (!SAFE_KEY.test(value) || value === "." || value === ".." || value.endsWith(".") || WINDOWS_DEVICE.test(value)) {
    throw new RawTraceError("RAW_TRACE_ID_UNSAFE", `${label} is not a safe store-generated identifier`, { value });
  }
  return value;
}

function adapterBinding(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "adapter must be an object");
  }
  const keys = Object.keys(value);
  if (keys.some((key) => !["id", "version", "profile_id"].includes(key))) {
    throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "adapter contains an undeclared property");
  }
  const result = {
    id: nonEmptyString(value.id, "adapter.id"),
    version: nonEmptyString(value.version, "adapter.version"),
  };
  if (value.profile_id !== undefined) result.profile_id = nonEmptyString(value.profile_id, "adapter.profile_id");
  return Object.freeze(result);
}

function applicationObservation(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "application must be an object when supplied");
  }
  const keys = Object.keys(value);
  if (keys.some((key) => !["id", "version"].includes(key))) {
    throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "application contains an undeclared property");
  }
  const result = { id: nonEmptyString(value.id, "application.id") };
  if (!/^[a-z][a-z0-9_.-]*$/.test(result.id)) {
    throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "application.id is not portable", { value: result.id });
  }
  if (value.version !== undefined) result.version = nonEmptyString(value.version, "application.version");
  return Object.freeze(result);
}

function omissionList(value, complete) {
  if (!Array.isArray(value)) {
    throw new RawTraceError("RAW_TRACE_OMISSIONS_INVALID", "omissions must be an array");
  }
  const result = value.map((item, index) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new RawTraceError("RAW_TRACE_OMISSIONS_INVALID", `omissions[${index}] must be an object`);
    }
    const keys = Object.keys(item);
    if (keys.some((key) => !["code", "detail", "source_ref"].includes(key))) {
      throw new RawTraceError("RAW_TRACE_OMISSIONS_INVALID", `omissions[${index}] contains an undeclared property`);
    }
    const code = nonEmptyString(item.code, `omissions[${index}].code`);
    if (!OMISSION_CODE.test(code)) {
      throw new RawTraceError("RAW_TRACE_OMISSIONS_INVALID", `omissions[${index}].code is invalid`);
    }
    const copy = { code, detail: nonEmptyString(item.detail, `omissions[${index}].detail`) };
    if (item.source_ref !== undefined) copy.source_ref = nonEmptyString(item.source_ref, `omissions[${index}].source_ref`);
    return Object.freeze(copy);
  });
  if (!complete && result.length === 0) {
    throw new RawTraceError("RAW_TRACE_OMISSIONS_REQUIRED", "an incomplete trace requires at least one explicit omission");
  }
  return Object.freeze(result);
}

function assertBuffer(value) {
  if (!Buffer.isBuffer(value)) {
    throw new RawTraceError("RAW_TRACE_BUFFER_REQUIRED", "raw trace writes accept Buffer values only");
  }
  return Buffer.from(value);
}

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

export class RawTraceSink {
  constructor({ traceDir, sessionKey, exchangeId, format, adapter, application = undefined }) {
    if (typeof traceDir !== "string" || !path.isAbsolute(traceDir)) {
      throw new RawTraceError("RAW_TRACE_DIRECTORY_INVALID", "traceDir must be an absolute store-provided path");
    }
    this.traceDir = path.resolve(traceDir);
    this.sessionKey = safeKey(sessionKey, "sessionKey");
    this.exchangeId = safeKey(exchangeId, "exchangeId");
    this.format = nonEmptyString(format, "format");
    this.adapter = adapterBinding(adapter);
    this.application = applicationObservation(application);

    this.sessionDir = path.resolve(this.traceDir, this.sessionKey);
    this.filePath = path.resolve(this.sessionDir, `${this.exchangeId}.trace`);
    const relativeFile = path.relative(this.sessionDir, this.filePath);
    if (relativeFile.startsWith("..") || path.isAbsolute(relativeFile) || path.dirname(this.filePath) !== this.sessionDir) {
      throw new RawTraceError("RAW_TRACE_PATH_ESCAPE", "resolved trace path escapes its session directory");
    }
    this.relativeRef = path.posix.join("traces", this.sessionKey, `${this.exchangeId}.trace`);

    this.state = "new";
    this.handle = null;
    this.hash = null;
    this.bytes = 0;
    this.frameCount = 0;
    this.malformedFrameCount = 0;
    this.lane = Promise.resolve();
    this.failure = null;
    this.finalizePromise = null;
    this.descriptor = null;
  }

  async init() {
    if (this.state !== "new") {
      throw new RawTraceError("RAW_TRACE_STATE_INVALID", `cannot initialize trace while state is '${this.state}'`);
    }
    this.state = "opening";
    try {
      await fs.mkdir(this.traceDir, { recursive: true });
      const realRoot = await fs.realpath(this.traceDir);
      await fs.mkdir(this.sessionDir, { recursive: true });
      const realSession = await fs.realpath(this.sessionDir);
      const relativeSession = path.relative(realRoot, realSession);
      if (relativeSession.startsWith("..") || path.isAbsolute(relativeSession)) {
        throw new RawTraceError("RAW_TRACE_PATH_ESCAPE", "resolved session trace directory escapes traceDir");
      }
      this.handle = await fs.open(this.filePath, "wx", 0o600);
      this.hash = createHash("sha256");
      this.state = "open";
      return this;
    } catch (error) {
      this.state = "failed";
      if (error instanceof RawTraceError) throw error;
      if (error?.code === "EEXIST") {
        throw new RawTraceError("RAW_TRACE_EXISTS", `refusing to overwrite existing trace '${this.relativeRef}'`);
      }
      throw new RawTraceError("RAW_TRACE_OPEN_FAILED", `could not create trace '${this.relativeRef}': ${error.message}`);
    }
  }

  _assertOpen() {
    if (this.state === "finalizing" || this.state === "finalized") {
      throw new RawTraceError("RAW_TRACE_ALREADY_FINALIZED", "raw trace is already finalizing or finalized");
    }
    if (this.state !== "open") {
      throw new RawTraceError("RAW_TRACE_STATE_INVALID", `raw trace is not writable while state is '${this.state}'`);
    }
  }

  _enqueueWrite(buffer, commit) {
    this._assertOpen();
    const bytes = assertBuffer(buffer);
    const operation = this.lane.then(async () => {
      if (this.failure) throw this.failure;
      let written = 0;
      try {
        while (written < bytes.length) {
          const result = await this.handle.write(bytes, written, bytes.length - written, this.bytes + written);
          if (!result || result.bytesWritten <= 0) throw new Error("write made no progress");
          written += result.bytesWritten;
        }
        this.hash.update(bytes);
        const result = commit(this.bytes, bytes.length);
        this.bytes += bytes.length;
        return result;
      } catch (error) {
        const failure = error instanceof RawTraceError
          ? error
          : new RawTraceError("RAW_TRACE_WRITE_FAILED", `raw trace write failed: ${error.message}`);
        if (!this.failure) this.failure = failure;
        this.state = "failed";
        if (this.handle) {
          try {
            await this.handle.close();
          } catch {
            // The first write failure remains authoritative.
          }
          this.handle = null;
        }
        throw this.failure;
      }
    });
    this.lane = operation.then(() => undefined, () => undefined);
    return operation;
  }

  /** Append one caller-delimited native frame and return its exact frame source. */
  appendFrame(buffer, { malformed = false, nativeEventId = undefined } = {}) {
    if (typeof malformed !== "boolean") {
      throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "malformed must be boolean");
    }
    if (nativeEventId !== undefined) nonEmptyString(nativeEventId, "nativeEventId");
    return this._enqueueWrite(buffer, () => {
      const frameIndex = this.frameCount++;
      if (malformed) this.malformedFrameCount++;
      return deepFreeze({
        kind: "receiver_native",
        trace_ref: this.relativeRef,
        frame_index: frameIndex,
        ...(nativeEventId !== undefined ? { native_event_id: nativeEventId } : {}),
      });
    });
  }

  /** Append an unframed byte chunk and return its exact non-empty byte span. */
  appendBytes(buffer) {
    if (Buffer.isBuffer(buffer) && buffer.length === 0) {
      throw new RawTraceError("RAW_TRACE_EMPTY_SPAN", "a byte-span write must contain at least one byte");
    }
    return this._enqueueWrite(buffer, (start, length) => deepFreeze({
      kind: "receiver_native",
      trace_ref: this.relativeRef,
      byte_span: { start, length },
    }));
  }

  /** Fsync and close once, returning the immutable transcript trace state. */
  finalize({ complete = true, omissions = [] } = {}) {
    this._assertOpen();
    if (typeof complete !== "boolean") {
      throw new RawTraceError("RAW_TRACE_ARGUMENT_INVALID", "complete must be boolean");
    }
    const frozenOmissions = omissionList(omissions, complete);
    this.state = "finalizing";
    this.finalizePromise = this.lane.then(async () => {
      if (this.failure) throw this.failure;
      let syncError = null;
      try {
        await this.handle.sync();
      } catch (error) {
        syncError = error;
      }
      try {
        await this.handle.close();
      } catch (error) {
        if (!syncError) syncError = error;
      } finally {
        this.handle = null;
      }
      if (syncError) {
        this.state = "failed";
        throw new RawTraceError("RAW_TRACE_FINALIZE_FAILED", `could not durably finalize raw trace: ${syncError.message}`);
      }

      const raw = {
        relative_ref: this.relativeRef,
        sha256: this.hash.digest("hex"),
        bytes: this.bytes,
        format: this.format,
        adapter: { ...this.adapter },
        frame_count: this.frameCount,
        malformed_frame_count: this.malformedFrameCount,
      };
      if (this.application) {
        raw.application_id = this.application.id;
        if (this.application.version !== undefined) raw.application_version = this.application.version;
      }
      this.descriptor = deepFreeze({ complete, raw, omissions: frozenOmissions });
      this.state = "finalized";
      return this.descriptor;
    });
    return this.finalizePromise;
  }
}
