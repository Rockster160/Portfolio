// A pet's face image for an expression name, off one entry of the themes table
// (ByteHelper#buddy_themes_json). Its own drawing when it has one; otherwise the
// face the server resolved as nearest on the mood axes (`aliases`), so asking a
// pet for a face it was never drawn with shows the closest one it has; neutral
// only for a name no pet knows.
export function faceUrlFor(theme, expression) {
  const faces = theme?.faces || {};
  const aliases = theme?.aliases || {};
  return faces[expression] || faces[aliases[expression]] || faces.neutral || null;
}

// The first of `expressions` this pet was actually drawn with, for a moment
// that names its faces in order of preference. A pet drawn with none of them
// gets the first, which then resolves to its nearest face like any other ask.
export function drawnFace(theme, expressions) {
  const faces = theme?.faces || {};
  return expressions.find((expression) => faces[expression]) || expressions[0];
}

// The face a pet rests on when nothing has moved it (Buddy::Faces.default). A
// dream's face only shows over this one.
export const IDLE_FACE = "neutral";
