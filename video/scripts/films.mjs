#!/usr/bin/env node
// Renders the film looks reel as an H.264 MP4 with its score, and its cover. Drafts go to the private
// redlamp-social repository's work folder for review; the approved render and its cover go to the reel's
// package there (reels/films/), from which it's posted. Its plan is plans/2026-10-11-film-looks-reel.md.
//   npm run films -- --draft             half size, into work/reels/films/, for a look on a phone
//   npm run films                        the approved render and its cover, into reels/films/
//   npm run films -- --hook=stocks       another hook (files get its name), or --hooks for every one
// The score and the looks' renders are made first if they're missing (films-score.py, films-renders.py).

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderUntilPainted } from "./blank.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const social = process.env.REDLAMP_SOCIAL ?? path.join(os.homedir(), "src/redlamp-social");
const out = path.join(root, "out/films");
const ID = "FilmLooks9x16";
// The cover is the hook over the plain photo, its words settled: they sit in the middle 3:4 that
// Instagram's profile grid shows.
const COVER = 12;

const args = process.argv.slice(2);
const option = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const draft = args.includes("--draft");
const copy = readFileSync(path.join(root, "src/films/copy.ts"), "utf8");
const hookBlock = copy.slice(copy.indexOf("export const hooks"), copy.indexOf("} as const"));
const allHooks = [...hookBlock.matchAll(/^\s+(\w+): \[/gm)].map((m) => m[1]);
const hooks = args.includes("--hooks") ? allHooks : [option("hook") ?? "looks"];
for (const hook of hooks) {
  if (!allHooks.includes(hook)) {
    console.error(`error: no hook named ${hook}; the hooks are ${allHooks.join(", ")}`);
    process.exit(1);
  }
}

const looks = JSON.parse(readFileSync(path.join(root, "src/films/looks.json"), "utf8")).looks;
if (looks.some((look) => !existsSync(path.join(root, `public/films/looks/${look.slug}.jpg`)))) {
  execFileSync("python3", ["scripts/films-renders.py"], { cwd: root, stdio: "inherit" });
}
if (!existsSync(path.join(root, "public/films/score.wav"))) {
  execFileSync("python3", ["scripts/films-score.py"], { cwd: root, stdio: "inherit" });
}

// Remotion fetches from its own server on localhost, which the sandbox's proxy would otherwise take.
const env = { ...process.env };
env.NO_PROXY = env.no_proxy = ["localhost", "127.0.0.1", "::1", env.NO_PROXY].filter(Boolean).join(",");
const remotion = (...a) => execFileSync("npx", ["remotion", ...a], { cwd: root, stdio: "inherit", env });
const target = path.join(social, draft ? "work/reels/films" : "reels/films");
mkdirSync(out, { recursive: true });
mkdirSync(target, { recursive: true });
for (const hook of hooks) {
  const props = JSON.stringify({ hook, musicSrc: "films/score.wav", guides: false });
  const name = `films-9x16${hooks.length > 1 || hook !== "looks" ? `-${hook}` : ""}${draft ? "-draft" : ""}`;
  const scale = draft ? ["--scale=0.5"] : [];
  // CRF 16, limited-range BT.709 4:2:0, which every site and player reads the same way. Every frame is
  // checked for one Chrome captured before painting it, and the reel rendered again if so.
  const video = path.join(out, `${name}.mp4`);
  await renderUntilPainted(video, () =>
    remotion("render", ID, video, `--props=${props}`, "--codec=h264", "--crf=16", "--pixel-format=yuv420p", "--color-space=bt709", "--audio-bitrate=320k", "--audio-codec=aac", ...scale),
  );
  copyFileSync(video, path.join(target, `${name}.mp4`));
  if (!draft) {
    const cover = path.join(out, `${name}-cover.jpg`);
    const coverProps = JSON.stringify({ ...JSON.parse(props), cover: true });
    await renderUntilPainted(cover, () => remotion("still", ID, cover, `--props=${coverProps}`, `--frame=${COVER}`, "--image-format=jpeg", "--jpeg-quality=92"));
    copyFileSync(cover, path.join(target, `${name}-cover.jpg`));
  }
  console.log(`==> ${path.join(target, `${name}.mp4`)}`);
}
