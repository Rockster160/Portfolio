require "rails_helper"
require "json"
require "open3"

# On a full-height desktop window, clicking anywhere in the message thread
# reshuffled Buddy and his chips into the phone layout — character and buttons
# side by side — and clicking off the page put them back.
#
# The compact row has two triggers, and the second one had no condition on it
# beyond `[data-byte-input]:focus`. It exists to make room for the on-screen
# keyboard, but a mouse doesn't have one, and index.js focuses the composer on
# any click in empty thread space (deliberately, and only for a fine pointer).
# So the two behaviors met in the middle: a click meant as "focus the box" was
# read as "the keyboard just opened."
#
# Asserted against the COMPILED cascade, like byte_font_scale_spec: what went
# wrong isn't in any declaration, it's in the conditions a rule does or doesn't
# sit under, which is the part a diff of the rule body cannot show.
RSpec.describe "Byte Buddy hero compact layout" do
  let(:triggers) {
    runner = Rails.root.join("spec/assets/byte_hero_compact_runner.rb").to_s
    stdout, stderr, status = Open3.capture3("bundle", "exec", "ruby", runner, chdir: Rails.root.to_s)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  def trigger_matching(pattern)
    triggers.find { |t| t["selector"].match?(pattern) }
  end

  # The bug in one line. Anything that can flip the hero sideways has to say
  # WHEN, or it flips it on every screen there is.
  it "never collapses the hero unconditionally" do
    unconditional = triggers.select { |t| t["conditions"].empty? }

    expect(unconditional.pluck("selector")).to eq([])
  end

  it "only makes room for a keyboard on a device that has one" do
    focus_rule = trigger_matching(/data-byte-input\]:focus/)

    expect(focus_rule).not_to be_nil, "the keyboard-up trigger is gone entirely"
    expect(focus_rule["conditions"]).to include("@media (pointer: coarse)")
  end

  # The other trigger, which is the one that should be doing the work on a
  # desktop: a window genuinely too short to stack them.
  it "still collapses a short window regardless of pointer" do
    short_rule = trigger_matching(/data-active-mode="buddy"/)

    expect(short_rule).not_to be_nil
    expect(short_rule["conditions"]).to eq(["@media (max-height: 560px)"])
  end

  # Both spellings deliberately skip the kiosk: its premise is a fixed half/half
  # split, and the compact row swaps the character out for chips it never shows.
  it "leaves the kiosk wall alone" do
    expect(triggers.pluck("selector")).to all(include('not([data-kiosk="true"])'))
  end
end
