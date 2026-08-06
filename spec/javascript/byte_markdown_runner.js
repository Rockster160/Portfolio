// Feeds fixtures through the thread's markdown-lite renderer and prints the
// results as JSON for byte_markdown_spec.rb. No DOM — renderMarkdown is a pure
// string function.
import { renderMarkdown } from "../../app/javascript/src/pages/byte/markdown.js";

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
};

const out = {};
for (const [name, input] of Object.entries(cases)) out[name] = renderMarkdown(input);
process.stdout.write(JSON.stringify(out));
