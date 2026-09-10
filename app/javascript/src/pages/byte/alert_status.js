// The line under an alert bubble.
//
// An alert is a message that stands for something OUTSTANDING until it's dealt
// with (Buddy::Alerts). Open versus dealt-with is carried VISUALLY - the amber
// tint and the bar down the side - so this deliberately writes nothing for the
// ordinary open case. A fixed string under every one of them is a line that
// appears every single time the feature is used and never once says anything
// the reader didn't already have.
//
// (The colour did once read as an ERROR rather than as a job. The fix for that
// was the colour - `--bs-attention` instead of `--bs-danger` - not a word
// underneath explaining it.)
//
// What it does write is what the bubble genuinely cannot show on its own:
//
//   * how many times the condition has been seen since, and when it was last
//     seen - because the message keeps ONE bubble across every occurrence, and
//     without this the second and third times would be invisible
//   * when it stopped standing - which is not the bubble's own timestamp; that
//     one is when the thing was first noticed, and the two are often days apart
export function alertStatusLabel(alert, formatTime = () => "") {
  if (!alert || typeof alert !== "object") return null;

  // Let go of, not resolved, and it must never read as the second one: nobody
  // checked the condition — the person said stop asking. Saying "resolved" here
  // would be a record of something that never happened.
  if (alert.status === "dismissed") {
    const at = formatTime(alert.resolved_at);
    return { state: "resolved", text: at ? `Let go ${at}` : "Let go" };
  }

  if (alert.status === "resolved") {
    const at = formatTime(alert.resolved_at);
    return { state: "resolved", text: at ? `Resolved ${at}` : "Resolved" };
  }

  const count = Number(alert.count || 0);
  if (!(count > 1)) return { state: "open", text: "" };

  const at = formatTime(alert.last_raised_at);
  const seen = `Seen ${count}×`;
  return { state: "open", text: at ? `${seen} · last ${at}` : seen };
}
