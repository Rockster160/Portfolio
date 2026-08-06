// The markdown-lite the Byte thread renders.
//
// Deliberately not a markdown library: bubbles are short, the input is trusted
// only as far as escaping makes it, and a full parser would bring block
// semantics (headings, tables, nested lists) that don't belong in a chat line.
// What's here is what companions and Claude actually emit.
//
// Extracted from index.js so the regexes can be tested. They have real edge
// cases — `_glue_` is emphasis and `game_tray-vase` is a filename — and that
// distinction is not something to eyeball.

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export function escapeAttr(s) {
  return escapeHtml(String(s ?? "")).replace(/"/g, "&quot;");
}

// Only these become anchors. `renderMarkdown` writes to innerHTML and the body
// it renders is model output, so a `javascript:` or `data:` href would be a
// script the model got to choose. Anything else falls through as plain text.
const SAFE_URL = /^https?:\/\/[^\s<>"']+$/i;

// Punctuation that ends the sentence rather than the address. "see https://x.com."
// should link the site, not a URL with a full stop welded on.
const TRAILING_PUNCT = /[.,;:!?]+$/;

export function renderMarkdown(raw) {
  const stash = [];
  let t = String(raw ?? "");
  t = t.replace(/```([^\n`]*)\n?([\s\S]*?)```/g, (_m, lang, code) => {
    const i = stash.push({ kind: "fence", lang: (lang || "").trim(), code }) - 1;
    return `@FENCE@${i}@FENCE@`;
  });
  t = t.replace(/`([^`\n]+)`/g, (_m, code) => {
    const i = stash.push({ kind: "inline", code }) - 1;
    return `@INLINE@${i}@INLINE@`;
  });
  // Strip Buddy side-effect / proposal markers from prose. They're processed
  // server-side and must never be visible — including a LEADING [[mood:]]
  // that would otherwise flash at the very start of a streaming reply. Code
  // spans are stashed above, so genuine code containing "[[" is protected,
  // and these four verbs are Buddy-only vocabulary so stripping is safe for
  // every mode.
  t = t.replace(/\[\[\s*(?:propose|mood|remember|forget|stash)\s*:[^\]]*\]\]/gi, "");
  // Links, stashed alongside the code spans and BEFORE the escape below.
  // The underscore-emphasis rule further down would otherwise italicise the
  // middle of any URL carrying one — the same trap its own comment describes
  // for `laundry_gate`. An unsafe scheme returns null and the match is left as
  // the literal text it was.
  const stashLink = (url, text) => {
    if (!SAFE_URL.test(url)) return null;
    return `@LINK@${stash.push({ kind: "link", url, text }) - 1}@LINK@`;
  };
  t = t.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, text, url) => stashLink(url, text) ?? m);
  // Bare URLs. Runs second, so a URL already stashed as a markdown link is a
  // token by now and can't match twice.
  t = t.replace(/(^|[\s(])(https?:\/\/[^\s<>"')\]]+)/g, (m, pre, url) => {
    const trimmed = url.replace(TRAILING_PUNCT, "");
    const token = stashLink(trimmed, trimmed);
    return token ? `${pre}${token}${url.slice(trimmed.length)}` : m;
  });
  t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  t = t.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  t = t.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
  // Underscore emphasis. Anchored to a word boundary at both ends so it can't
  // eat a snake_case identifier — `game_tray-vase` and `laundry_gate` come up
  // constantly here, and the naive pattern italicises the middle of them.
  // Bold runs first so `__both__` doesn't half-match.
  t = t.replace(/(^|[\s(])_([^_\n]+)_(?=[\s).,!?;:]|$)/g, "$1<em>$2</em>");
  // Bullet lists, grouped BEFORE newlines become <br>: a <ul> brings its own
  // line breaks, and leaving the surrounding ones in stacks a blank gap on
  // either side of every list.
  t = t.replace(/(?:^|\n)((?:[ \t]*[-•][ \t]+[^\n]*(?:\n|$))+)/g, (_m, block) => {
    const items = block
      .trimEnd()
      .split("\n")
      .map((line) => `<li>${line.replace(/^[ \t]*[-•][ \t]+/, "")}</li>`)
      .join("");
    return `<ul class="byte-md-list">${items}</ul>`;
  });
  t = t.replace(/<\/ul>\n+/g, "</ul>");
  t = t.replace(/\n/g, "<br>");
  t = t.replace(/@FENCE@(\d+)@FENCE@/g, (_m, i) => {
    const b = stash[Number(i)];
    return `<pre class="byte-md-code"><code>${escapeHtml(b.code)}</code></pre>`;
  });
  t = t.replace(/@INLINE@(\d+)@INLINE@/g, (_m, i) => {
    const b = stash[Number(i)];
    return `<code class="byte-md-inline">${escapeHtml(b.code)}</code>`;
  });
  // `_blank` because Byte is an installed PWA (display: standalone). Without
  // it a tap replaces the conversation with a page that has no back button and
  // no way home.
  t = t.replace(/@LINK@(\d+)@LINK@/g, (_m, i) => {
    const b = stash[Number(i)];
    return `<a class="byte-md-link" href="${escapeAttr(b.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(b.text)}</a>`;
  });
  return t;
}
