/**
 * Every word in the film looks reel, from its plan (plans/2026-10-11-film-looks-reel.md in the private
 * redlamp-social repository), written to the social room's copy rules: at most two lines on screen and
 * 17 characters a line. The hook is the composition's `hook` prop, so each can be rendered as its own
 * variant. The films' names are in looks.json.
 */
export const hooks = {
  looks: ["36 FILM LOOKS", "IN REDLAMP"],
  stocks: ["36 LOOKS FROM", "30 FILM STOCKS"],
  datasheets: ["FILM LOOKS BUILT", "FROM DATASHEETS"],
  raws: ["36 FILM LOOKS", "FOR YOUR RAWS"],
  every: ["EVERY FILM LOOK", "IN REDLAMP"],
} as const;

export type Hook = keyof typeof hooks;

export const DEFAULT_HOOK: Hook = "looks";

export const copy = {
  endLine: ["RAW PHOTO EDITOR", "FOR THE MAC"],
  endCard: ["DOWNLOAD FREE", "REDLAMP.APP"],
} as const;
