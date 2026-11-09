// Writes the licenses of everything bundled into the page next to the bundle.
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const output = join(root, "../boringNotch/Lyrics/LyricsWeb/THIRD_PARTY_LICENSES.txt");

const direct = Object.keys(JSON.parse(readFileSync(join(root, "package.json"), "utf8")).dependencies);
const seen = new Set();
const sections = [];

function visit(name) {
  if (seen.has(name)) return;
  seen.add(name);
  const dir = join(root, "node_modules", name);
  if (!existsSync(join(dir, "package.json"))) return;

  const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const file = readdirSync(dir).find((entry) => /^(licen[sc]e|copying)/i.test(entry));
  const text = file ? readFileSync(join(dir, file), "utf8").trim() : `License: ${manifest.license ?? "unknown"}`;
  sections.push(`${"=".repeat(78)}\n${name} ${manifest.version} (${manifest.license ?? "unknown"})\n${"=".repeat(78)}\n\n${text}\n`);

  // vitest is listed as a runtime dependency of the core package but never imported.
  for (const dep of Object.keys(manifest.dependencies ?? {})) {
    if (dep !== "vitest") visit(dep);
  }
}

direct.forEach(visit);
sections.sort();
writeFileSync(output, sections.join("\n"));
console.log(`wrote licenses for ${sections.length} packages`);
