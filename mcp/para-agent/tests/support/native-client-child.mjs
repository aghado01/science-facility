const mode = process.argv[2];
const input = [];

process.stdin.on("data", (chunk) => input.push(Buffer.from(chunk)));
process.stdin.on("end", () => {
  const prompt = Buffer.concat(input);
  switch (mode) {
    case "echo":
      process.stdout.write(prompt);
      break;
    case "separate":
      process.stdout.write(Buffer.from("stdout-one", "utf8"));
      setTimeout(() => {
        process.stderr.write(Buffer.from("stderr-one", "utf8"));
        setTimeout(() => process.stdout.write(Buffer.from("stdout-two", "utf8")), 15);
      }, 15);
      break;
    case "nonzero":
      process.stdout.write(Buffer.from("partial-output", "utf8"));
      process.stderr.write(Buffer.from("native-failure", "utf8"));
      process.exitCode = 23;
      break;
    case "hang":
      setInterval(() => {}, 10_000);
      break;
    case "flood": {
      const block = Buffer.alloc(4096, 0x78);
      for (let i = 0; i < 64; i++) process.stdout.write(block);
      setInterval(() => {}, 10_000);
      break;
    }
    default:
      process.stderr.write(Buffer.from(`unknown mode: ${mode}`, "utf8"));
      process.exitCode = 64;
      break;
  }
});
