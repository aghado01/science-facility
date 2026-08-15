import { ClientIntegrationError } from "./errors.js";
import { deepFreeze, semanticSha256 } from "./semantic-json.js";

const POLICY_DIGEST_VERSION = 1;
const OWN = (value, key) => Object.hasOwn(value, key);
const POLICY_FIELD = /^[a-z][a-z0-9_.-]*$/;

function fail(code) {
  throw new ClientIntegrationError(code);
}

function assertRecord(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail("CLIENT_POLICY_UNSUPPORTED", `${label} must be an object`);
  }
  return value;
}

function uniqueStrings(values, label, { allowEmpty = false } = {}) {
  if (!Array.isArray(values) || (!allowEmpty && values.length === 0)) {
    fail("CLIENT_POLICY_UNSUPPORTED", `${label} must be a string array`);
  }
  const result = [];
  const seen = new Set();
  for (const value of values) {
    if (typeof value !== "string" || value.length === 0 || seen.has(value)) {
      fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains an invalid or duplicate value`);
    }
    seen.add(value);
    result.push(value);
  }
  return result;
}

function assertDefinitionKeys(definition, allowed, label) {
  if (Object.keys(definition).some((key) => !allowed.includes(key))) {
    fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains unknown fields`);
  }
}

function relationForOrdered(definition, label) {
  assertDefinitionKeys(definition, ["kind", "values"], label);
  const values = uniqueStrings(definition.values, `${label}.values`);
  return {
    semantic: { kind: "ordered", values },
    normalize(value) {
      if (!values.includes(value)) {
        fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains an unsupported value`);
      }
      return value;
    },
    narrowerOrEqual(left, right) {
      return values.indexOf(left) <= values.indexOf(right);
    },
    intersect(left, right) {
      return values[Math.min(values.indexOf(left), values.indexOf(right))];
    },
  };
}

function relationForBoolean(definition, label) {
  assertDefinitionKeys(definition, ["kind", "narrower"], label);
  if (typeof definition.narrower !== "boolean") {
    fail("CLIENT_POLICY_UNSUPPORTED", `${label}.narrower must be boolean`);
  }
  const narrower = definition.narrower;
  return {
    semantic: { kind: "boolean", narrower },
    normalize(value) {
      if (typeof value !== "boolean") {
        fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains a non-boolean value`);
      }
      return value;
    },
    narrowerOrEqual(left, right) {
      return left === right || left === narrower;
    },
    intersect(left, right) {
      return left === right ? left : narrower;
    },
  };
}

function relationForSet(definition, label) {
  assertDefinitionKeys(definition, ["kind", "universe"], label);
  const universe = uniqueStrings(definition.universe, `${label}.universe`, { allowEmpty: true }).sort();
  const universeSet = new Set(universe);
  const normalize = (value) => {
    if (!Array.isArray(value)) {
      fail("CLIENT_POLICY_UNSUPPORTED", `${label} must be an array`);
    }
    const seen = new Set();
    for (const item of value) {
      if (typeof item !== "string" || !universeSet.has(item) || seen.has(item)) {
        fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains an unsupported or duplicate set member`);
      }
      seen.add(item);
    }
    return [...seen].sort();
  };
  return {
    semantic: { kind: "set", universe },
    normalize,
    narrowerOrEqual(left, right) {
      const rightSet = new Set(right);
      return left.every((item) => rightSet.has(item));
    },
    intersect(left, right) {
      const rightSet = new Set(right);
      return left.filter((item) => rightSet.has(item));
    },
  };
}

function relationForPartialOrder(definition, label) {
  assertDefinitionKeys(definition, ["kind", "values", "narrower_or_equal"], label);
  const values = uniqueStrings(definition.values, `${label}.values`);
  if (!Array.isArray(definition.narrower_or_equal)) {
    fail("CLIENT_POLICY_UNSUPPORTED", `${label}.narrower_or_equal must be an array`);
  }
  const indices = new Map(values.map((value, index) => [value, index]));
  const reachability = values.map((_, row) => values.map((__, column) => row === column));
  for (const edge of definition.narrower_or_equal) {
    if (!Array.isArray(edge) || edge.length !== 2 || !indices.has(edge[0]) || !indices.has(edge[1])) {
      fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains an invalid partial-order edge`);
    }
    reachability[indices.get(edge[0])][indices.get(edge[1])] = true;
  }
  for (let middle = 0; middle < values.length; middle += 1) {
    for (let left = 0; left < values.length; left += 1) {
      for (let right = 0; right < values.length; right += 1) {
        reachability[left][right] ||= reachability[left][middle] && reachability[middle][right];
      }
    }
  }
  for (let left = 0; left < values.length; left += 1) {
    for (let right = left + 1; right < values.length; right += 1) {
      if (reachability[left][right] && reachability[right][left]) {
        fail("CLIENT_POLICY_AMBIGUOUS", `${label} is not an antisymmetric partial order`);
      }
    }
  }

  const normalize = (value) => {
    if (!indices.has(value)) {
      fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains an unsupported value`);
    }
    return value;
  };
  const narrowerOrEqual = (left, right) => reachability[indices.get(left)][indices.get(right)];
  const semanticValues = [...values].sort();
  const semanticEdges = [];
  for (const left of semanticValues) {
    for (const right of semanticValues) {
      if (left !== right && reachability[indices.get(left)][indices.get(right)]) {
        semanticEdges.push([left, right]);
      }
    }
  }
  return {
    semantic: {
      kind: "partial_order",
      values: semanticValues,
      narrower_or_equal: semanticEdges,
    },
    normalize,
    narrowerOrEqual,
    intersect(left, right) {
      const lowerBounds = values.filter((candidate) => (
        narrowerOrEqual(candidate, left) && narrowerOrEqual(candidate, right)
      ));
      const maximal = lowerBounds.filter((candidate) => !lowerBounds.some((other) => (
        other !== candidate
          && narrowerOrEqual(candidate, other)
          && !narrowerOrEqual(other, candidate)
      )));
      if (maximal.length !== 1) {
        fail("CLIENT_POLICY_AMBIGUOUS", `${label} ceilings have no unique intersection`);
      }
      return maximal[0];
    },
  };
}

function compileDimensions(dimensions) {
  assertRecord(dimensions, "policy dimensions");
  const names = Object.keys(dimensions).sort();
  if (names.length === 0) {
    fail("CLIENT_POLICY_UNSUPPORTED", "policy dimensions must not be empty");
  }
  const relations = {};
  for (const name of names) {
    if (!POLICY_FIELD.test(name)) {
      fail("CLIENT_POLICY_UNSUPPORTED", "policy dimension names must be non-empty strings");
    }
    const definition = assertRecord(dimensions[name], `policy dimension ${name}`);
    switch (definition.kind) {
      case "ordered":
        relations[name] = relationForOrdered(definition, name);
        break;
      case "boolean":
        relations[name] = relationForBoolean(definition, name);
        break;
      case "set":
        relations[name] = relationForSet(definition, name);
        break;
      case "partial_order":
        relations[name] = relationForPartialOrder(definition, name);
        break;
      default:
        fail("CLIENT_POLICY_UNSUPPORTED", `${name} has an unsupported policy relation`);
    }
  }
  return { names, relations };
}

function assertKnownFields(value, names, label, { complete = false } = {}) {
  assertRecord(value, label);
  const allowed = new Set(names);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      fail("CLIENT_POLICY_UNSUPPORTED", `${label} contains an undeclared dimension`);
    }
  }
  if (complete && names.some((name) => !OWN(value, name))) {
    fail("CLIENT_POLICY_UNSUPPORTED", `${label} must define every policy dimension`);
  }
}

function normalizePolicy(value, compiled, label, options) {
  assertKnownFields(value, compiled.names, label, options);
  const result = {};
  for (const name of compiled.names) {
    if (OWN(value, name)) result[name] = compiled.relations[name].normalize(value[name]);
  }
  return result;
}

function narrowOverlay(baseline, overlay, compiled, label) {
  const result = { ...baseline };
  for (const name of compiled.names) {
    if (!OWN(overlay, name)) continue;
    if (!compiled.relations[name].narrowerOrEqual(overlay[name], baseline[name])) {
      fail("CLIENT_POLICY_WIDENING", `${label} widens a policy dimension`);
    }
    result[name] = overlay[name];
  }
  return result;
}

function digestPolicy(compiled, ceiling, values) {
  const dimensions = {};
  for (const name of compiled.names) dimensions[name] = compiled.relations[name].semantic;
  return semanticSha256({
    policy_digest_version: POLICY_DIGEST_VERSION,
    dimensions,
    ceiling,
    values,
  });
}

export function intersectPolicyCeilings(dimensions, packageCeiling, hostCeiling) {
  const compiled = compileDimensions(dimensions);
  const packageValues = normalizePolicy(packageCeiling, compiled, "package ceiling", { complete: true });
  const hostValues = normalizePolicy(hostCeiling, compiled, "host ceiling", { complete: true });
  const ceiling = {};
  for (const name of compiled.names) {
    ceiling[name] = compiled.relations[name].intersect(packageValues[name], hostValues[name]);
  }
  return deepFreeze(ceiling);
}

export function assertPolicyNarrowing(dimensions, baseline, candidate, label = "policy") {
  const compiled = compileDimensions(dimensions);
  const base = normalizePolicy(baseline, compiled, "baseline policy", { complete: true });
  const next = normalizePolicy(candidate, compiled, label, { complete: false });
  return deepFreeze(narrowOverlay(base, next, compiled, label));
}

export function compilePolicy({
  dimensions,
  packageCeiling,
  hostCeiling,
  packageDefaults = {},
  hostDefaults = {},
  sessionPolicy = {},
  operationPolicy = {},
}) {
  const compiled = compileDimensions(dimensions);
  const packageCeilingValues = normalizePolicy(packageCeiling, compiled, "package ceiling", { complete: true });
  const hostCeilingValues = normalizePolicy(hostCeiling, compiled, "host ceiling", { complete: true });
  const packageDefaultValues = normalizePolicy(packageDefaults, compiled, "package defaults", { complete: false });
  const hostDefaultValues = normalizePolicy(hostDefaults, compiled, "host defaults", { complete: false });
  const sessionValues = normalizePolicy(sessionPolicy, compiled, "session policy", { complete: false });
  const operationValues = normalizePolicy(operationPolicy, compiled, "operation policy", { complete: false });

  const ceiling = {};
  for (const name of compiled.names) {
    ceiling[name] = compiled.relations[name].intersect(packageCeilingValues[name], hostCeilingValues[name]);
  }

  const selectedDefaults = {};
  for (const name of compiled.names) {
    selectedDefaults[name] = OWN(hostDefaultValues, name)
      ? hostDefaultValues[name]
      : OWN(packageDefaultValues, name)
        ? packageDefaultValues[name]
        : ceiling[name];
    if (!compiled.relations[name].narrowerOrEqual(selectedDefaults[name], ceiling[name])) {
      fail("CLIENT_POLICY_WIDENING", "configured defaults exceed the effective policy ceiling");
    }
  }

  const session = narrowOverlay(selectedDefaults, sessionValues, compiled, "session policy");
  const effective = narrowOverlay(session, operationValues, compiled, "operation policy");
  const sessionSha256 = digestPolicy(compiled, ceiling, session);
  const effectiveSha256 = digestPolicy(compiled, ceiling, effective);

  return deepFreeze({
    ceiling,
    session,
    effective,
    session_sha256: sessionSha256,
    effective_sha256: effectiveSha256,
    descriptor: {
      policy: {
        session_sha256: sessionSha256,
        effective_sha256: effectiveSha256,
      },
    },
  });
}

export function compileClientPolicy({
  integrationPolicy,
  hostPolicy,
  sessionPolicy,
  operationPolicy = {},
}) {
  if (
    integrationPolicy === null
    || typeof integrationPolicy !== "object"
    || hostPolicy === null
    || typeof hostPolicy !== "object"
    || sessionPolicy === null
    || typeof sessionPolicy !== "object"
  ) {
    fail("CLIENT_POLICY_UNSUPPORTED", "resolved policy profiles are invalid");
  }
  return compilePolicy({
    dimensions: integrationPolicy.dimensions,
    packageCeiling: integrationPolicy.ceiling,
    hostCeiling: hostPolicy.ceiling,
    packageDefaults: integrationPolicy.defaults,
    hostDefaults: hostPolicy.defaults,
    sessionPolicy: sessionPolicy.values,
    operationPolicy,
  });
}
