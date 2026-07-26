#!/usr/bin/env node
/**
 * Validate contracts/fixtures/mihomo-config/cases structure and case.json fields.
 * No external deps — runs on any Node 18+.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const monorepoRoot = path.resolve(__dirname, "../../..");
const casesRoot = path.join(
  monorepoRoot,
  "contracts/fixtures/mihomo-config/cases",
);

const ROUTING = new Set(["rule", "global", "direct"]);
const PROJECTION = new Set(["user", "privilegedTun"]);
const ERROR_CODES = new Set([
  "selectedNodeMustBeIPv6",
  "ipv6ManagedProfileRequired",
  "missingTunConfiguration",
  "unsupportedProfileExtension",
]);

function fail(msg) {
  console.error(`ERROR: ${msg}`);
  process.exitCode = 1;
}

function main() {
  if (!fs.existsSync(casesRoot)) {
    fail(`missing cases root: ${casesRoot}`);
    return;
  }

  const dirs = fs
    .readdirSync(casesRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  if (dirs.length === 0) {
    fail("no fixture cases found");
    return;
  }

  let ok = 0;
  for (const name of dirs) {
    const dir = path.join(casesRoot, name);
    const casePath = path.join(dir, "case.json");
    const inputPath = path.join(dir, "input.yaml");
    if (!fs.existsSync(casePath)) {
      fail(`${name}: missing case.json`);
      continue;
    }
    if (!fs.existsSync(inputPath)) {
      fail(`${name}: missing input.yaml`);
      continue;
    }

    let raw;
    try {
      raw = JSON.parse(fs.readFileSync(casePath, "utf8"));
    } catch (e) {
      fail(`${name}: invalid JSON: ${e.message}`);
      continue;
    }

    if (raw.id !== name) {
      fail(`${name}: id "${raw.id}" must match directory name`);
    }
    if (!ROUTING.has(raw.routingMode)) {
      fail(`${name}: invalid routingMode ${raw.routingMode}`);
    }
    if (!PROJECTION.has(raw.projection)) {
      fail(`${name}: invalid projection ${raw.projection}`);
    }
    if (!raw.expect || typeof raw.expect.success !== "boolean") {
      fail(`${name}: expect.success required`);
      continue;
    }

    if (raw.expect.success) {
      if (raw.routingMode !== "direct" && !raw.selectedAddress) {
        fail(`${name}: success cases (non-direct) need selectedAddress`);
      }
      if (raw.expect.errorCode) {
        fail(`${name}: success case must not set errorCode`);
      }
    } else {
      if (!raw.expect.errorCode || !ERROR_CODES.has(raw.expect.errorCode)) {
        fail(
          `${name}: failure case needs known errorCode, got ${raw.expect.errorCode}`,
        );
      }
    }

    if (process.exitCode) continue;
    ok += 1;
    console.log(`OK  ${name}`);
  }

  if (!process.exitCode) {
    console.log(`validate-cases: ${ok}/${dirs.length} cases OK`);
  } else {
    console.error(`validate-cases: failed (saw ${ok} clean cases before errors)`);
  }
}

main();
