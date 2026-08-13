// The markdown-lite the Byte thread renders.
//
// Deliberately not a markdown library: bubbles are short, the input is trusted
// only as far as escaping makes it, and a full parser would bring semantics
// nobody here emits. What's here is what companions and Claude actually write.
//
// Headings and tables were on the "doesn't belong in a chat line" list, and the
// daily audit made that wrong: it's a structured report delivered into a
// thread, and it writes `## Counts` and pipe tables because that IS the right
// shape for one. Unrendered, they arrived as literal `##` and rows of pipes.
// Nested lists stay out — nothing writes them.
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

// A GFM pipe table: one header row, a separator row of dashes (with optional
// alignment colons), then any number of body rows. The separator is what
// distinguishes a table from a sentence containing pipes, so it's mandatory —
// without it, `a | b` in ordinary prose would start eating lines.
const TABLE_ROW = String.raw`[ \t]*\|[^\n]*\|[ \t]*`;
const TABLE_SEP = String.raw`[ \t]*\|(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*`;
const TABLE_RX = new RegExp(
  String.raw`(?:^|\n)(${TABLE_ROW}\n${TABLE_SEP}(?:\n${TABLE_ROW})*)(?:\n|$)`,
  "g",
);

// `| a | b |` -> ["a", "b"]. The outer pipes are framing, not cells.
function splitRow(row) {
  return row
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

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
  // `[hicon Fae]` / `[hicon:12]` — one of the household's own uploaded icons,
  // dropped inline in the prose. Same syntax the server-side Markdown service
  // has always understood; Byte renders its own markdown, so it had to learn it
  // separately. Stashed alongside links and BEFORE the link rule, or
  // `[hicon Fae]` followed by a parenthetical would be read as a link.
  //
  // The span comes out EMPTY, carrying only the reference: resolving a name to
  // a picture needs the custom icon pool, which is fetched on demand and can't
  // be awaited from a synchronous render. `hydrateInlineIcons` fills it in.
  const stashIcon = (ref) =>
    `@HICON@${stash.push({ kind: "hicon", ref: ref.trim() }) - 1}@HICON@`;
  t = t.replace(/\[hicon:(\d+)\]/gi, (_m, id) => stashIcon(`hicon:${id}`));
  t = t.replace(/\[hicon[ \t]+([^\]\n]+)\]/gi, (_m, name) => stashIcon(name));
  // `[ticon:ti-broom]` — a Tabler icon. Same three shapes the picker deals in,
  // and what the `:name` autocomplete inserts for a non-emoji, non-custom hit.
  t = t.replace(/\[ticon:(ti-[a-z0-9-]+)\]/gi, (_m, cls) => stashIcon(cls));
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
  // Tables, before the bullet grouping and well before newlines become <br>:
  // every block construct here has to consume its own line breaks or it ends up
  // wrapped in stray <br>s.
  //
  // A table is a header row, a separator row, then body rows — the separator is
  // what makes it a table rather than a line that happens to contain pipes, so
  // it's required. Cell contents have already been through escaping and the
  // inline rules above, so **bold** and `code` inside a cell just work.
  t = t.replace(TABLE_RX, (_m, block) => {
    const rows = block.trim().split("\n");
    const aligns = splitRow(rows[1]).map((spec) => {
      const left = spec.startsWith(":");
      const right = spec.endsWith(":");
      if (left && right) return " class=\"is-center\"";
      return right ? " class=\"is-right\"" : "";
    });
    const cells = (row, tag) =>
      splitRow(row)
        .map((cell, i) => `<${tag}${aligns[i] || ""}>${cell}</${tag}>`)
        .join("");

    const head = `<thead><tr>${cells(rows[0], "th")}</tr></thead>`;
    const body = rows
      .slice(2)
      .map((row) => `<tr>${cells(row, "td")}</tr>`)
      .join("");

    // The wrapper is what scrolls. A wide table must never make the whole
    // thread scroll sideways.
    return `<div class="byte-md-table-wrap"><table class="byte-md-table">${head}<tbody>${body}</tbody></table></div>`;
  });
  t = t.replace(/<\/div>\n+/g, "</div>");

  // Headings. `#` through `######`, collapsed onto three visual levels — a
  // chat bubble has no use for six, and the report only writes two.
  //
  // The tags start at h3 because a message is nested inside a page that owns
  // its own h1/h2; the CLASS carries the visual level. Trailing newlines are
  // eaten with the match: a heading is a block and doesn't want a <br> after it.
  t = t.replace(/(?:^|\n)[ \t]*(#{1,6})[ \t]+([^\n]+?)[ \t]*#*[ \t]*(?:\n+|$)/g, (_m, hashes, text) => {
    const level = Math.min(hashes.length, 3);
    const tag = ["h3", "h4", "h5"][level - 1];
    return `<${tag} class="byte-md-h byte-md-h${level}">${text}</${tag}>`;
  });

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
  t = t.replace(/@HICON@(\d+)@HICON@/g, (_m, i) => {
    const b = stash[Number(i)];
    return `<span class="hicon" data-icon-ref="${escapeAttr(b.ref)}"></span>`;
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
