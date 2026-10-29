// Finding a line in a conversation.
//
// Half an hour of talking is 120 turns, and what gets asked of it afterwards
// is nearly always a lookup: what did they ask about testing, what did I say
// about money, where did Casey come into it. Scrolling for that is what this
// replaces, in both the places a transcript is read — its own page, and the
// beat it hangs off in the timeline.
//
// NON-MATCHING TURNS GO AWAY RATHER THAN BEING JUMPED TO. The list is already
// a scroller in both places, so what is wanted is the four lines that mention
// the thing, next to each other, with the words lit up in them.
//
// Mount on a container: every `[data-transcript-search]` inside is wired. The
// markup it asks for is a query input, the turns, and a line to count them in:
//
//   [data-transcript-search]
//     input[data-transcript-query]
//     [data-transcript-count]
//     [data-turn] …          — one per turn, hidden when it does not match
//       [data-turn-text] …   — the parts searched and lit up: who, and what
//
// The speaker's name is searched along with the words, because "what did the
// recruiter say" is the same question as "what was said about the salary".

const UNMATCHED = "is-unmatched";
const SEARCHING = "is-searching";

function escaped(said) {
  return said.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// The words with every hit wrapped. Built as escaped HTML rather than as text
// nodes because the turn's own markup is replaced wholesale on each keystroke,
// and `<mark>` is the only tag going back in.
function marked(said, query) {
  if (!query) { return escaped(said); }

  const lower = said.toLowerCase();
  let out = "";
  let at = 0;
  for (;;) {
    const found = lower.indexOf(query, at);
    if (found === -1) { break; }

    out += escaped(said.slice(at, found));
    out += "<mark>" + escaped(said.slice(found, found + query.length)) + "</mark>";
    at = found + query.length;
  }
  return out + escaped(said.slice(at));
}

// What the part said before anything was lit up in it. Held on the element,
// because after the first keystroke its own text is full of marks and reading
// the words back out of it would compound.
function said(part) {
  if (part.transcriptSaid === undefined) { part.transcriptSaid = part.textContent; }
  return part.transcriptSaid;
}

function wireSearch(pane) {
  const box = pane.querySelector("[data-transcript-query]");
  const turns = Array.from(pane.querySelectorAll("[data-turn]"));
  if (!box || !turns.length) { return false; }

  const counter = pane.querySelector("[data-transcript-count]");
  const resting = counter ? counter.textContent : "";

  const look = function () {
    const query = box.value.trim().toLowerCase();
    let hits = 0;

    turns.forEach(function (turn) {
      const parts = Array.from(turn.querySelectorAll("[data-turn-text]"));
      let here = false;
      parts.forEach(function (part) {
        const words = said(part);
        if (query && words.toLowerCase().indexOf(query) !== -1) { here = true; }
        part.innerHTML = marked(words, query);
      });

      const show = !query || here;
      turn.classList.toggle(UNMATCHED, !show);
      if (show && query) { hits += 1; }
    });

    pane.classList.toggle(SEARCHING, !!query);
    if (!counter) { return; }

    if (!query) {
      counter.textContent = resting;
    } else {
      counter.textContent = hits ? hits + " of " + turns.length : "nothing says that";
    }
  };

  box.addEventListener("input", look);

  // Escape empties it. A filtered list with the box scrolled out of sight
  // looks like a transcript that lost most of itself.
  box.addEventListener("keydown", function (event) {
    if (event.key !== "Escape" || !box.value) { return; }

    box.value = "";
    look();
  });

  // A query typed, then the page reloaded - which this one does to itself
  // while the speakers are being worked out - comes back in the box.
  if (box.value.trim()) { look(); }

  return true;
}

export function bindTranscriptSearch(root) {
  if (!root) { return 0; }

  const panes = Array.from(root.querySelectorAll("[data-transcript-search]"));
  panes.forEach(wireSearch);
  return panes.length;
}

export default bindTranscriptSearch;
