require "rails_helper"

# The compact hero row (character and chips side by side) is for a short window
# or an on-screen keyboard. The keyboard trigger keys on composer focus, which a
# mouse click also causes, so it has to be gated to coarse pointers. Asserted
# against the COMPILED cascade: the conditions a rule sits under are the point.
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
