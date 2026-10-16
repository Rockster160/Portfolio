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

// The face a pet rests on when nothing has moved it (Buddy::Faces.default). A
// dream's face only shows over this one.
export const IDLE_FACE = "neutral";
