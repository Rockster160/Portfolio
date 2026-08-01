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

  # KNOWN_SCOPES can only ever cover what the app triggers itself. /jil/webhook
  # takes the scope off the request, so Home Assistant and anything else posting
  # in names its own, and no grep of app code will ever find those. A task
  # already listening to one is what proves it fires.
  describe "scopes an integration fires" do
    let(:user) { create(:user) }

    def task!(listener, enabled: true, owner: user)
      Task.create!(
        user: owner, name: "T#{listener.object_id}", listener: listener,
        code: "// noop", enabled: enabled
      )
    end

    before { Rails.cache.clear }

    it "accepts one the person has a task listening on" do
      task!("hass-sensor:location:doorbell")

      expect(described_class.known_scope?("hass-sensor", user: user)).to be(true)
    end

    it "refuses one nothing listens on" do
      expect(described_class.known_scope?("hass-sensor", user: user)).to be(false)
    end

    it "still refuses without a user to check against" do
      task!("hass-sensor:location:doorbell")

      expect(described_class.known_scope?("hass-sensor")).to be(false)
    end

    it "doesn't leak another person's integrations" do
      task!("hass-sensor", owner: create(:user))

      expect(described_class.known_scope?("hass-sensor", user: user)).to be(false)
    end

    it "ignores a disabled task, which is no evidence the scope still fires" do
      task!("hass-sensor", enabled: false)

      expect(described_class.known_scope?("hass-sensor", user: user)).to be(false)
    end

    # A function's "listener" is a type signature, and its leading segment
    # (`function(...`) is not a scope anything triggers.
    it "ignores function signatures" do
      task!('function("Temp" TAB Numeric)::Boolean')

      expect(described_class.wired_scopes(user)).to be_empty
    end

    it "keeps accepting the app's own scopes with no task at all" do
      expect(described_class.known_scope?("chore_completion", user: user)).to be(true)
    end
  end
end
