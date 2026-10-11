import { AbsoluteFill, Easing, getStaticFiles, Html5Audio, Img, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { Words } from "../components/Kinetic";
import { type Framing, framing } from "../kit/camera";
import { type CueSheet, grid, onBeats } from "../kit/grid";
import { textWidth } from "../kit/measure";
import { SafeZones } from "../kit/SafeZones";
import { springs } from "../layout";
import { color, easeOut, font } from "../theme";
import { copy, DEFAULT_HOOK, type Hook, hooks } from "./copy";
import cueSheet from "./cues.json";
import catalogue from "./looks.json";

/**
 * The film looks reel: Redlamp's 36 film looks, each on a photo with its film icon and name, cut on the
 * music's grid faster and faster (a look a bar, then every two beats, every beat and every half beat);
 * then, on the drop, a pull back from the last look to the contact sheet of all 36, and the end card.
 * The renders are made by scripts/films-renders.py and the score by scripts/films-score.py, from the same
 * cue sheet.
 */
type Look = { slug: string; name: string; kind: string; photo: string };
const sheet = cueSheet as unknown as CueSheet & { looks: number[] };
const looks = catalogue.looks as Look[];
const g = grid(sheet);
const b = (beat: number) => Math.round(g.at(beat));
const cue = (name: string) => Math.round(g.cue(name));

export const FILM_LOOKS_FRAMES = g.frames;

export type FilmLooksProps = {
  hook: Hook;
  /** The score in public/, played if it's there. */
  musicSrc: string | null;
  /** The 9:16 safe zones over the frame, for review. */
  guides: boolean;
};

export const filmLooksDefaults: FilmLooksProps = { hook: DEFAULT_HOOK, musicSrc: "films/score.wav", guides: false };

const W = 1080;
const H = 1920;
/** Words start here, inside the side that tall phones crop, and stay left of the apps' buttons. */
const LEFT = 110;
const TEXT_WIDTH = 920 - LEFT;
const LABEL_TOP = 880;
/** The hook and the mark sit low in the frame, below the opening photo's face and above the apps' controls. */
const HOOK_BOTTOM = 1450;
/** The mark spans the hook's two lines. */
const MARK_LINES = 2 * 1.04;
const ICON = 280;

/** The contact sheet in world units, a tile the size of the frame, so the pull back starts sharp. */
const COLUMNS = 6;
const GUTTER = 62;
const SHEET = { w: COLUMNS * W + (COLUMNS - 1) * GUTTER, h: 6 * H + 5 * GUTTER };
/** The sheet 880 px wide on screen, clear of the sides tall phones crop. */
const WIDE: Framing = { x: SHEET.w / 2, y: SHEET.h / 2, zoom: 880 / SHEET.w };
const TILE_ICON = 430;

function tileAt(i: number) {
  const row = Math.floor(i / COLUMNS);
  const column = i % COLUMNS;
  return { row, column, x: column * (W + GUTTER), y: row * (H + GUTTER) };
}

const last = tileAt(looks.length - 1);
const lastFraming: Framing = { x: last.x + W / 2, y: last.y + H / 2, zoom: 1 };

/** The world camera, from the last look full frame to the sheet. */
function cameraAt(frame: number): Framing {
  return framing(frame, [
    [cue("last"), lastFraming],
    [cue("drop"), { ...lastFraming, zoom: 1.06 }, (k) => k],
    [cue("sheet"), WIDE, easeOut],
    [cue("end"), WIDE],
    [cue("end") + g.beat * 2, { ...WIDE, zoom: WIDE.zoom * 0.94 }, easeOut],
  ]);
}

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const ramp = (frame: number, from: number, to: number) => clamp01((frame - from) / Math.max(1, to - from));
const src = (slug: string) => staticFile(`films/looks/${slug}.jpg`);
const icon = (slug: string) => staticFile(`synced/film/icon-${slug}.png`);

/** The look on screen at `frame`, and when it came in and goes; -1 under the hook. */
function lookAt(frame: number) {
  let index = -1;
  for (let i = 0; i < looks.length; i += 1) if (frame >= b(sheet.looks[i])) index = i;
  const start = index < 0 ? 0 : b(sheet.looks[index]);
  const end = index < 0 ? b(sheet.looks[0]) : index + 1 < looks.length ? b(sheet.looks[index + 1]) : cue("drop");
  return { index, start, end };
}

/** A size for every line in `lines` that fits them all in `width`, at most `max`. */
function fitted(lines: readonly string[], width: number, max: number) {
  const widest = Math.max(...lines.map((line) => textWidth(line, 100)));
  return Math.min(max, Math.floor((width / widest) * 100));
}

const text = {
  fontFamily: font.family,
  ...font.display,
  color: color.paper,
  lineHeight: 1.04,
  whiteSpace: "nowrap" as const,
  textShadow: "0 2px 22px rgba(10,7,7,0.6)",
};

/** A full-frame photo that pushes in slowly while it's held and lands each cut with a small punch. */
function Photo({ frame, look, start, end, punch }: { frame: number; look: string; start: number; end: number; punch: boolean }) {
  const held = ramp(frame, start, Math.max(end, start + g.bar));
  const hit = punch ? 0.045 * Math.exp(-(frame - start) / 3) : 0;
  return (
    <AbsoluteFill style={{ transform: `scale(${1 + 0.03 * held + hit})` }}>
      <Img src={look} style={{ width: W, height: H }} />
    </AbsoluteFill>
  );
}

/** The film's icon, name and process, popping in when there's time to and switching when there isn't. */
function Label({ frame, look, start, end, size }: { frame: number; look: Look; start: number; end: number; size: number }) {
  const { fps } = useVideoConfig();
  const slow = end - start >= g.beat;
  const s = slow ? spring({ frame: frame - start, fps, config: { damping: 14, stiffness: 220, mass: 0.6 } }) : 1;
  const flash = slow ? 0 : 0.06 * Math.exp(-(frame - start) / 2.5);
  const out = look === looks[looks.length - 1] ? ramp(frame, cue("drop"), cue("drop") + 6) : 0;
  return (
    <div style={{ position: "absolute", left: LEFT, top: LABEL_TOP, opacity: 1 - out, transform: `translateY(${out * 60}px)` }}>
      <Img
        src={icon(look.slug)}
        style={{ width: ICON, height: ICON, display: "block", marginLeft: -ICON * 0.06, transformOrigin: "30% 80%", transform: `scale(${(0.6 + 0.4 * s) * (1 + flash)})`, opacity: Math.min(1, s * 2), filter: "drop-shadow(0 6px 14px rgba(10,7,7,0.5))" }}
      />
      <div style={{ ...text, fontSize: size, marginTop: 14, transform: `translateY(${(1 - s) * 24}px)`, opacity: Math.min(1, s * 2) }}>{look.name}</div>
      <div style={{ ...text, fontSize: 60, fontWeight: 500, letterSpacing: "0.02em", color: color.ring, marginTop: 10, opacity: Math.min(1, s * 2) }}>{look.kind}</div>
    </div>
  );
}

/** The contact sheet: every look on its photo with its film's icon, under the world camera. */
function ContactSheet({ frame }: { frame: number }) {
  const { fps } = useVideoConfig();
  const icons = cue("drop") + g.beat;
  return (
    <AbsoluteFill style={{ width: SHEET.w, height: SHEET.h }}>
      {looks.map((look, i) => {
        const t = tileAt(i);
        const delay = (COLUMNS - 1 - t.column + (5 - t.row)) * 1.5;
        const s = spring({ frame: frame - icons - delay, fps, config: { damping: 12, stiffness: 200, mass: 0.6 } });
        return (
          <div key={look.slug} style={{ position: "absolute", left: t.x, top: t.y, width: W, height: H, overflow: "hidden" }}>
            <Img src={src(look.slug)} style={{ width: W, height: H }} />
            {s > 0.001 ? (
              <Img
                src={icon(look.slug)}
                style={{ position: "absolute", left: 60, bottom: 70, width: TILE_ICON, height: TILE_ICON, transformOrigin: "30% 80%", transform: `scale(${s})`, filter: "drop-shadow(0 20px 40px rgba(10,7,7,0.6))" }}
              />
            ) : null}
          </div>
        );
      })}
    </AbsoluteFill>
  );
}

export function FilmLooks({ hook, musicSrc, guides }: FilmLooksProps) {
  const frame = useCurrentFrame();
  const { width, height, durationInFrames } = useVideoConfig();
  const music = musicSrc && getStaticFiles().some((file) => file.name === musicSrc) ? musicSrc : null;
  const { index, start, end } = lookAt(frame);
  const world = frame >= cue("last");
  // The first look develops across the plain photo, left to right, over the half beat after it lands.
  const wipe = ramp(frame, b(sheet.looks[0]), b(sheet.looks[0]) + g.beat / 2);
  const hookLines = hooks[hook];
  const roughMark = MARK_LINES * fitted(hookLines, TEXT_WIDTH, 104);
  const hookSize = fitted(hookLines, TEXT_WIDTH - roughMark * 1.25, 104);
  const markSize = MARK_LINES * hookSize;
  const nameSize = fitted(
    looks.map((look) => look.name),
    TEXT_WIDTH,
    92,
  );
  const endSize = fitted(copy.endLine, TEXT_WIDTH, 96);
  const cardSize = fitted(copy.endCard, 720, 96);

  // The sheet bumps a little on each kick from the moment it's laid out until the end card.
  const kicks: number[] = [];
  for (let beat = 42; beat < 48; beat += 1) kicks.push(b(beat));
  const camera = cameraAt(frame);
  const zoom = camera.zoom * (1 + 0.012 * onBeats(frame, kicks, 5));
  const transform = `translate(${width / 2 - camera.x * zoom}px, ${height / 2 - camera.y * zoom}px) scale(${zoom})`;

  const shade = 1 - ramp(frame, cue("drop"), cue("drop") + 8);
  const dim =
    0.62 * ramp(frame, cue("endLine") - 4, cue("endLine") + 4) +
    0.26 * ramp(frame, cue("end") - 4, cue("end") + 6) +
    0.12 * ramp(frame, cue("lastHit"), cue("lastHit") + g.beat * 2);
  const fade = Easing.inOut(Easing.quad)(ramp(frame, cue("fade"), durationInFrames));

  return (
    <AbsoluteFill style={{ background: color.wall, overflow: "hidden" }}>
      {world ? (
        <AbsoluteFill style={{ transform, transformOrigin: "0 0" }}>
          <ContactSheet frame={frame} />
        </AbsoluteFill>
      ) : index <= 0 ? (
        <>
          <Photo frame={frame} look={staticFile(`films/plain/${looks[0].photo}.jpg`)} start={0} end={b(sheet.looks[1])} punch={false} />
          {index === 0 ? (
            <AbsoluteFill style={{ maskImage: `linear-gradient(90deg, #000 ${wipe * 120 - 10}%, transparent ${wipe * 120 + 10}%)` }}>
              <Photo frame={frame} look={src(looks[0].slug)} start={0} end={b(sheet.looks[1])} punch={false} />
            </AbsoluteFill>
          ) : null}
        </>
      ) : (
        <Photo frame={frame} look={src(looks[index].slug)} start={start} end={end} punch />
      )}

      <AbsoluteFill
        style={{
          opacity: shade,
          background: "linear-gradient(180deg, transparent 0%, transparent 44%, rgba(10,7,7,0.42) 60%, rgba(10,7,7,0.62) 78%, rgba(10,7,7,0.7) 100%)",
        }}
      />

      <div style={{ position: "absolute", left: LEFT, bottom: H - HOOK_BOTTOM, display: "flex", alignItems: "center", gap: markSize * 0.25 }}>
        <HookMark frame={frame} out={b(sheet.looks[0]) - 6} size={markSize} />
        <div>
          <Words text={hookLines[0]} start={-18} size={hookSize} stagger={2} mode="pop" align="left" out={b(sheet.looks[0]) - 6} style={{ textShadow: text.textShadow }} />
          <Words text={hookLines[1]} start={-14} size={hookSize} stagger={2} mode="pop" align="left" out={b(sheet.looks[0]) - 5} style={{ textShadow: text.textShadow }} />
        </div>
      </div>
      {index >= 0 && frame < cue("drop") + 8 ? <Label frame={frame} look={looks[index]} start={start} end={end} size={nameSize} /> : null}

      <AbsoluteFill style={{ background: color.wall, opacity: dim }} />
      <div style={{ position: "absolute", left: LEFT, top: 830 }}>
        <Words text={copy.endLine[0]} start={cue("endLine")} size={endSize} stagger={2} mode="pop" align="left" out={cue("end") - 6} />
        <Words text={copy.endLine[1]} start={cue("endLine") + 4} size={endSize} stagger={2} mode="pop" align="left" out={cue("end") - 5} />
      </div>
      <EndCard frame={frame} size={cardSize} />

      <AbsoluteFill style={{ background: color.wall, opacity: fade }} />
      {guides ? <SafeZones /> : null}
      {music ? <Html5Audio src={staticFile(music)} /> : null}
    </AbsoluteFill>
  );
}

/**
 * Redlamp's flat mark beside the hook from the first frame, so the brand is there before anything moves: the
 * one-colour white version, for photographic backgrounds, unaltered, a quarter of its height from the words,
 * leaving with the hook's lines.
 */
function HookMark({ frame, out, size }: { frame: number; out: number; size: number }) {
  const { fps } = useVideoConfig();
  const o = spring({ frame: frame - out, fps, config: springs.snap });
  if (o > 0.999) return null;
  return (
    <Img
      src={staticFile("synced/brand/logo/redlamp-mark-white.svg")}
      style={{ display: "block", flex: "none", height: size, width: size, opacity: 1 - o, transform: `translateY(${-o * size * 0.2}px)` }}
    />
  );
}

/** Redlamp's stacked lockup over DOWNLOAD FREE / REDLAMP.APP, from the last hit. */
function EndCard({ frame, size }: { frame: number; size: number }) {
  const { fps } = useVideoConfig();
  const start = cue("end");
  if (frame < start - 2) return null;
  const s = spring({ frame: frame - start, fps, config: { damping: 15, stiffness: 160, mass: 0.7 } });
  const lockup = 420;
  return (
    <AbsoluteFill>
      <Img
        src={staticFile("synced/brand/logo/redlamp-lockup-stacked.svg")}
        style={{ position: "absolute", left: (W - lockup) / 2, top: 400, width: lockup, height: (lockup * 103.83) / 116.8, transform: `scale(${0.7 + 0.3 * s})`, opacity: Math.min(1, s * 1.6) }}
      />
      <div style={{ position: "absolute", left: 0, right: 0, top: 930 }}>
        <Words text={copy.endCard[0]} start={start + 4} size={size} stagger={2} mode="pop" />
        <Words text={copy.endCard[1]} start={start + 8} size={size} stagger={2} mode="pop" weight={500} style={{ marginTop: size * 0.18, color: color.ring }} />
      </div>
    </AbsoluteFill>
  );
}