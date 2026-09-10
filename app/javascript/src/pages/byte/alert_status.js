// The line under an alert bubble, and nothing more than that.
//
// An alert is a message that stands for something OUTSTANDING until it's dealt
// with (Buddy::Alerts). Open versus resolved is carried VISUALLY - the tint and
// the marker on the corner - so this deliberately writes nothing for the
// ordinary open case: a bubble that already looks outstanding does not need a
// word saying so underneath it.
//
// What it does write is the part the bubble cannot show on its own:
//
//   * how many times the condition has been seen since, and when it was last
//     seen - because the message keeps ONE bubble across every occurrence, and
//     without this the second and third times would be invisible
//   * when it was resolved - which is not the bubble's own timestamp; that one
//     is when the thing was first noticed, and the two are often days apart
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
