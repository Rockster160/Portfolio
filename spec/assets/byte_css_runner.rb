# Compiles pages/byte.scss and reports every rule in it — the @media
# conditions it sits under, its selector, its declaration body, and the
# font-size it sets if it sets one — as JSON.
#
# A separate process on purpose: SassC segfaults compiling this stylesheet
# inside the loaded RSpec process, while the identical call is fine standalone.
# Shelling out matches how the JS specs run their node runners, and keeps the
# assertions on the REAL compiled cascade rather than on a regex over the
# source, which is what let the font-scale drift happen in the first place.
#
# One runner for every asset spec that reads this sheet. There were three, each
# compiling the same stylesheet for its own slice of the answer, and each `let`
# re-ran its own on every example — fifteen compiles of one file per suite run.
require "sassc"
require "json"

ROOT  = File.expand_path("../..", __dir__)
SHEET = File.join(ROOT, "app/assets/stylesheets/pages/byte.scss")

css = SassC::Engine.new(
  File.read(SHEET),
  style:      :expanded,
  load_paths: [File.join(ROOT, "app/assets/stylesheets")],
).render

# Walk the compiled sheet tracking brace depth, so each rule carries the @media
# it sits inside (empty at top level). Selectors are buffered because a
# comma-separated list is emitted one selector per line.
conditions = []
buffer     = +""
selector   = nil
body       = nil
rules      = []

css.each_line { |raw|
  line = raw.strip
  next if line.empty? || line.start_with?("/*")

  if selector.nil?
    if line == "}"
      conditions.pop
      next
    end

    buffer = buffer.empty? ? line.dup : "#{buffer} #{line}"
    next unless line.end_with?("{")

    head   = buffer.sub(/\s*\{\z/, "").strip
    buffer = +""
    if head.start_with?("@")
      conditions.push(head)
    else
      selector = head
      body     = +""
    end
  elsif line == "}"
    rules << {
      "conditions" => conditions.dup,
      "selector"   => selector,
      "body"       => body.strip,
      "font_size"  => body[/font-size:\s*([^;]+)/, 1]&.strip,
    }
    selector = nil
  else
    body << " #{line}"
  end
}

puts JSON.generate(rules)
