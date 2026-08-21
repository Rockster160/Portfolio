require "rails_helper"

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
  # Every rule that can flip the hero sideways.
  let(:triggers) {
    CompiledCss.rules.select { |r|
      r["selector"].include?(".byte-buddy-hero") && r["body"].include?("flex-direction: row")
    }
  }

  def trigger_matching(pattern)
    triggers.find { |t| t["selector"].match?(pattern) }
  end

  # The bug in one line. Anything that can flip the hero sideways has to say
  # WHEN, or it flips it on every screen there is — and both spellings
  # deliberately skip the kiosk, whose premise is a fixed half/half split that
  # the compact row would swap the character out of.
  it "never collapses the hero unconditionally, and never on the kiosk wall" do
    expect(triggers.select { |t| t["conditions"].empty? }.pluck("selector")).to eq([])
    expect(triggers.pluck("selector")).to all(include('not([data-kiosk="true"])'))
  end

  # The two triggers, which are the same fact from both ends: room for a
  # keyboard belongs to devices that have one, and a genuinely short window
  # collapses whatever is pointing at it.
  it "makes room for a keyboard only where there is one, and still collapses a short window" do
    focus_rule = trigger_matching(/data-byte-input\]:focus/)
    short_rule = trigger_matching(/data-active-mode="buddy"/)

    expect(focus_rule).not_to be_nil, "the keyboard-up trigger is gone entirely"
    expect(focus_rule["conditions"]).to include("@media (pointer: coarse)")

    expect(short_rule).not_to be_nil, "the short-window trigger is gone entirely"
    expect(short_rule["conditions"]).to eq(["@media (max-height: 560px)"])
  end
end
