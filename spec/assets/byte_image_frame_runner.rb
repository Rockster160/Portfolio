# Compiles pages/byte.scss and reports every rule that touches a thread image
# attachment, each with the @media condition it was emitted under and its
# declaration body — as JSON for byte_image_frame_spec.rb.
#
# A separate process for the same reason as byte_hero_compact_runner.rb: SassC
# segfaults compiling this stylesheet inside the loaded RSpec process, while the
# identical call is fine standalone.
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
    rules << { "conditions" => conditions.dup, "selector" => selector, "body" => body }
    selector = nil
  else
    body << " #{line}"
  end
}

frames = rules.select { |r| r["selector"].include?(".byte-attachment-image") }

puts JSON.generate(frames.map { |r| r.merge("body" => r["body"].strip) })
