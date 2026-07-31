require "rails_helper"

# Buddy refuses a listener naming a scope that isn't in KNOWN_SCOPES, because
# one that doesn't exist can never fire and the person would never find out.
# That only holds while the list matches reality, so this greps the app for
# every scope actually triggered and fails when one is missing.
#
# If this fails after you add a trigger: add the scope to KNOWN_SCOPES, and add
# a row to docs/jil_listener_syntax.md so Buddy knows what its payload carries.
RSpec.describe Jil::ListenerMatch do
  # `Jil.trigger(user, :scope, ...)` and the `jil_trigger(:scope, ...)`
  # controller helper. Interpolated and variable scopes are skipped - they can't
  # be read statically, and every one in the app today is a literal.
  def triggered_scopes
    # `[^,\n]` rather than `[^,]`: a negated class matches newlines in Ruby, so
    # the greedy version happily spans from a `Jil.trigger(` on one line to a
    # symbol fifty lines below and reports scopes that don't exist.
    patterns = [
      /Jil\.trigger\([^,\n]+,\s*:(\w+)/,
      /jil_trigger\(:(\w+)/,
    ]
    Rails.root.glob("app/**/*.rb").flat_map { |path|
      body = File.read(path)
      patterns.flat_map { |rx| body.scan(rx).flatten }
    }.uniq.sort
  end

  it "lists every scope the app actually triggers" do
    missing = triggered_scopes - described_class::KNOWN_SCOPES

    expect(missing).to be_empty,
      "these scopes are triggered but not in KNOWN_SCOPES, so Buddy would refuse " \
      "a valid listener for them: #{missing.inspect}"
  end

  it "documents every scope it claims to know" do
    documented = Rails.root.join("docs/jil_listener_syntax.md").read
    undocumented = described_class::KNOWN_SCOPES.reject { |s| documented.include?("`#{s}`") }

    expect(undocumented).to be_empty,
      "Buddy is told these scopes are valid but the guide doesn't say what they " \
      "carry, so it would be guessing at keys: #{undocumented.inspect}"
  end
end
