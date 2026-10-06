# Builds every stylesheet production precompiles and runs the result through
# the same SassC compressor `assets:precompile` uses, printing a JSON map of
# logical path => error message for each one that fails.
#
# The compressor re-parses the COMPILED CSS as SCSS. Anything the first pass
# emits verbatim — an interpolated `#{"min(100%, 360px)"}`, a raw `min()` or
# `max()` mixing units — is read the second time as a Sass function and aborts
# the deploy. Development never runs the compressor, so only this sees it.
#
# A separate process for the same reason as byte_css_runner.rb: SassC is not
# safe to drive from inside the loaded RSpec process.
ENV["RAILS_ENV"] = "test"
require File.expand_path("../../config/environment", __dir__)
require "json"

root = Rails.root.join("app/assets/stylesheets")
entries = [
  "application.scss",
  "jil.scss",
  "quick_actions.scss",
  *Dir.glob("support/*.{scss,css}", base: root),
  *Dir.glob("individual/**/*.{scss,css}", base: root),
].reject { |path| File.basename(path).start_with?("_") }

failures = entries.each_with_object({}) { |entry, out|
  logical = entry.sub(/\.scss\z/, ".css")
  begin
    css = Rails.application.assets.find_asset(logical).to_s
    SassC::Engine.new(css, style: :compressed).render
  rescue StandardError => e
    out[logical] = e.message.lines.first.strip
  end
}

puts({ checked: entries.size, failures: failures }.to_json)
