class MemoryTransport {
  constructor() {
    this.peer = null;
    this.started = false;
    this.closed = false;
    this.pending = [];
  }

  async start() {
    if (this.started) throw new Error("memory transport already started");
    this.started = true;
    for (const message of this.pending.splice(0)) this.#deliver(message);
  }

  async send(message) {
    if (this.closed) throw new Error("memory transport is closed");
    const copy = structuredClone(message);
    if (!this.peer?.started) {
      this.peer?.pending.push(copy);
      return;
    }
    queueMicrotask(() => this.peer.#deliver(copy));
  }

  #deliver(message) {
    if (!this.closed) this.onmessage?.(message);
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.onclose?.();
  }
}

export function memoryTransportPair() {
  const client = new MemoryTransport();
  const server = new MemoryTransport();
  client.peer = server;
  server.peer = client;
  return { client, server };
}
