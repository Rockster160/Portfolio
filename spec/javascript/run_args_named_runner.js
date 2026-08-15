// Feeds arg labels through the binding rules and prints the result as JSON for
// run_args_named_spec.rb. arg_binding.js is dependency-free by design — the
// modal it was split out of imports the whole editor and won't load in node.
import {
  argKey,
  bindingFor,
  collectValues,
} from "../../app/javascript/jil/arg_binding.js";

// Enough of a wrapper for findInput/readInputValue to read a value off.
const node = (value) => ({
  querySelector: () => ({ type: "text", value: value, dataset: {} }),
});

const out = {};

out.keys = {
  simple: argKey("Camera"),
  spaced: argKey("Start Time"),
  padded: argKey("  When  "),
  mixed_case: argKey("EventType"),
};

out.bindings = {
  labeled: bindingFor("When"),
  multiword: bindingFor("Start Time"),
  unlabeled: bindingFor(null),
  empty: bindingFor(""),
};

// The whole point: a labeled arg lands under BOTH its name and its position.
out.labeled_posts_both = collectValues([
  { ...bindingFor("Camera"), node: node("driveway") },
  { ...bindingFor("When"), node: node("") },
  { ...bindingFor("Event"), node: node("vehicle") },
]);

// Unlabeled args still post positionally and add no keys of their own.
out.unlabeled_posts_positionally = collectValues([
  { ...bindingFor(null), node: node("a") },
  { ...bindingFor(null), node: node("b") },
]);

// An arg literally labeled "Params" must not clobber the positional array.
out.params_label_does_not_clobber = collectValues([
  { ...bindingFor("Params"), node: node("mine") },
]);

process.stdout.write(JSON.stringify(out));
