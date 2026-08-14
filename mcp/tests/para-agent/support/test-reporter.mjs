const SUMMARY_PREFIX = "PARA_TEST_SUMMARY ";

export default async function* paraAgentReporter(source) {
  const counts = {
    schema_version: 1,
    discovered: 0,
    completed: 0,
    passed: 0,
    failed: 0,
    cancelled: 0,
    skipped: 0,
  };

  for await (const event of source) {
    if (event.type === "test:start") {
      counts.discovered += 1;
      continue;
    }

    if (event.type === "test:pass" || event.type === "test:fail") {
      counts.completed += 1;
      if (event.type === "test:fail") {
        counts.failed += 1;
        yield `PARA_TEST_FAILURE ${JSON.stringify({
          name: event.data?.name ?? "unknown",
          file: event.data?.file,
          line: event.data?.line,
          column: event.data?.column,
          error: event.data?.details?.error?.message ?? event.data?.details?.error?.failureType,
        })}\n`;
      } else if (event.data?.skip !== undefined) {
        counts.skipped += 1;
      } else {
        counts.passed += 1;
      }
      if (event.data?.details?.error?.failureType === "cancelledByParent") {
        counts.cancelled += 1;
      }
    }
  }

  yield `${SUMMARY_PREFIX}${JSON.stringify(counts)}\n`;
}
