# Compiles pages/byte.scss and reports how each message-surface rule sizes its
# text, as JSON for byte_font_scale_spec.rb.
#
# A separate process on purpose: SassC segfaults compiling this stylesheet
# inside RSpec (libsass in the loaded test process), while the identical call
# is fine standalone. Shelling out matches how the JS specs run their node
# runners, and keeps the assertion on the REAL compiled cascade rather than on
# a regex over the source, which is what let this drift in the first place.
require "sassc"
require "json"

ROOT  = File.expand_path("../..", __dir__)
SHEET = File.join(ROOT, "app/assets/stylesheets/pages/byte.scss")

css = SassC::Engine.new(
  File.read(SHEET),
  style:      :expanded,
  load_paths: [File.join(ROOT, "app/assets/stylesheets")],
).render

rules = css.scan(/^([^{}\n]+)\{([^}]*)\}/m).map { |selector, body|
  { "selector" => selector.strip, "font_size" => body[/font-size:\s*([^;]+)/, 1]&.strip }
}

puts JSON.generate(rules.reject { |r| r["font_size"].nil? })
