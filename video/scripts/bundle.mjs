// Remotion leaves every bundle, with a copy of public/, in the Mac's temporary folder. `npx remotion render` and
// `still` delete theirs; a script that calls bundle() has to delete its own.

import { bundle as remotionBundle } from "@remotion/bundler";
import { rmSync } from "node:fs";

const bundles = [];
process.on("exit", () => {
  for (const dir of bundles) rmSync(dir, { recursive: true, force: true });
});
process.once("SIGINT", () => process.exit(130));
process.once("SIGTERM", () => process.exit(143));

/** Remotion's bundle(), with the bundle deleted when the script ends. */
export async function bundle(options) {
  const dir = await remotionBundle(options);
  bundles.push(dir);
  return dir;
}
