import test from "node:test";

test("live fixture reports a skip", { skip: "synthetic unavailable live dependency" }, () => {});
