import { readFileSync } from "node:fs";
import { Script } from "node:vm";

const files = [
  "digital-library.html",
  "academy.html",
  "knowledge-product.html",
  "knowledge-checkout.html",
  "knowledge-library.html",
  "academy-course.html",
  "admin/knowledge-center.html",
];

let failures = 0;
for (const file of files) {
  const html = readFileSync(file, "utf8");
  const tags = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  let inlineCount = 0;
  for (const tag of tags) {
    if (/\bsrc\s*=/.test(tag[1])) continue;
    const source = tag[2].trim();
    if (!source) continue;
    inlineCount++;
    try {
      new Script(source, { filename: file + "#inline-script-" + inlineCount });
    } catch (error) {
      failures++;
      console.error(file + " inline script " + inlineCount + ": " + error.message);
    }
  }
  console.log(file + ": checked " + inlineCount + " inline script(s)");
}
if (failures) {
  console.error("Inline JavaScript syntax checks failed: " + failures);
  process.exit(1);
}
console.log("All inline JavaScript syntax checks passed.");
