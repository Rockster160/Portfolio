// Feeds fixtures through the thread's markdown-lite renderer and prints the
// results as JSON for byte_markdown_spec.rb. No DOM — renderMarkdown is a pure
// string function.
import { renderMarkdown, renderIconRefs } from "../../app/javascript/src/pages/byte/markdown.js";

const cases = {
  underscore_em: "Mostly the household stuff I’d want more of is the _glue_.",
  underscore_mid_sentence: "a little more _structured_ at the edges",
  snake_case_left_alone: "printing game_tray-vase now",
  two_snake_case_words: "laundry_gate and front_door are both closed",
  underscore_in_parens: "(_maybe_) later",
  bullet_list: "Like:\n- one thing\n- two thing\n\nThe big win",
  bullet_then_text: "- only item\nafter",
  asterisk_em_still_works: "that is *very* good",
  bold_still_works: "Sent **game_tray-vase** to the printer",
  inline_code_untouched: "the listener is `item:name:/Permission/` there",
  dash_midline_not_a_list: "it went out - and she has it now",
  md_link: "it's on [your links page](https://ardesian.com/chores/links) now",
  bare_url: "see https://ardesian.com/chores for that",
  url_with_underscores: "https://ardesian.com/a_b_c/d_e",
  url_trailing_period: "it's at https://ardesian.com/chores.",
  javascript_href: "[tap me](javascript:alert(1))",
  data_href: "[tap me](data:text/html,<script>alert(1)</script>)",
  url_in_code_untouched: "run `curl https://ardesian.com/chores` first",
  link_text_escaped: "[<b>x</b>](https://ardesian.com)",
  url_query_amp: "https://ardesian.com/s?a=1&b=2",

  // The daily audit writes `## Counts` and pipe tables — both arrived as
  // literal punctuation before these were added.
  heading_h2: "## Counts\nByte had 40 messages.",
  heading_h1: "# Daily Audit",
  heading_h3: "### Backfills\nnothing to do",
  heading_with_bold: "## **Counts** for today",
  heading_closing_hashes: "## Counts ##\nafter",
  hash_no_space_not_a_heading: "#nothashtag stays",
  hash_midline_not_a_heading: "the count is #4 today",
  table_basic: "| Thread | In | Out |\n|---|---|---|\n| Byte | 40 | 21 |\n| Moss | 6 | 4 |",
  table_aligned: "| Thread | Count |\n|:--|--:|\n| Byte | 40 |",
  table_with_inline: "| Thread | Note |\n|---|---|\n| **Byte** | see `turn.rb` |",
  table_then_text: "| a | b |\n|---|---|\n| 1 | 2 |\nafter the table",
  pipes_without_separator: "a | b\nc | d",
  table_after_heading: "## Counts\n| a | b |\n|---|---|\n| 1 | 2 |",

  // Icon references. The id form turns up hand-typed with a space in it, and
  // `[hicon X](...)` would parse as a markdown link without ordering care.
  hicon_by_id: "sent [hicon:24] over",
  hicon_id_spaced: "sent [hicon: 21] over",
  hicon_by_name: "feeding [hicon Fae] now",
  hicon_name_with_spaces: "grabbing a [hicon Mtn Dew Can]",
  ticon: "sweeping [ticon:ti-broom] up",
  hicon_three_in_a_row: "[hicon:21] [hicon:24] [hicon:22]",
  hicon_then_parens: "[hicon Fae](not a link)",
  hicon_in_code_untouched: "write `[hicon Fae]` for that",
  hicon_unknown_shape_left_alone: "[hicon]",
};

// The narrow pass, for text that is not markdown - a tool-argument preview.
const refCases = {
  ref_id: "Custom.Notify [hicon:24]",
  ref_id_spaced: "Custom.Notify [hicon: 21]",
  ref_name: "chore: [hicon Fae] litter",
  ref_escapes_html: "<b>x</b> [hicon:24]",
  ref_leaves_markdown_alone: "a _b_ c **d** [hicon:24]",
  ref_none: "just plain text",
};

const out = {};
for (const [name, input] of Object.entries(cases)) out[name] = renderMarkdown(input);
for (const [name, input] of Object.entries(refCases)) out[name] = renderIconRefs(input);
process.stdout.write(JSON.stringify(out));
