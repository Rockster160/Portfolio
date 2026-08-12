require "rails_helper"
require "json"
require "open3"

# Eve turned Suki's text up and the messages grew, but the receipts, the
# tool-use rows and the timestamps stayed exactly as small as they were.
#
# `--byte-font-scale` is applied in ONE place — `font-size` on `.byte-msg` —
# and the comment there states the invariant the whole feature rests on:
# "Everything inside a bubble either inherits this or is expressed as a
# percentage of it." Nothing enforced that, so anything added later carrying a
# plain `font-size: 11.5px` silently opted itself out. Ten rules had.
#
# Asserted against the COMPILED cascade rather than the source, because the bug
# isn't visible in any single edit. It's a property of the whole sheet, which is
# the one thing a person reading a diff cannot see.
RSpec.describe "Byte thread font scaling" do
  # The parts of a message bubble a reader reads. The pet's own chrome (hero,
  # drawer, kiosk pad, header) is deliberately not in scope, and neither is the
  # composer: iOS Safari zooms the whole layout viewport for a focused field
  # under 16px, so that one has a hard floor and can't ride a scale below 100.
  in_bubble = /
    byte-msg-kind-buddy_activity | byte-msg-kind-action_chip |
    byte-msg-action- | byte-msg-manage- | byte-msg-meta | byte-msg-peer |
    byte-msg-activity-detail | multi-select-submit
  /x

  # Terminal output has its own sizing for its own reasons, and a non-owner —
  # which is everyone this preference was built for — never sees one.
  terminal = /kind-claude|kind-shell/

  # A ✕ centered in a fixed 26px square doesn't get to grow.
  fixed_box = /is-remove/

  let(:rules) {
    runner = Rails.root.join("spec/assets/byte_font_scale_runner.rb").to_s
    stdout, stderr, status = Open3.capture3("bundle", "exec", "ruby", runner, chdir: Rails.root.to_s)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  def rule_for(selector)
    rules.find { |r| r["selector"] == selector }
  end

  it "sizes everything in a bubble relative to the one scaled anchor" do
    offenders = rules.select { |r|
      r["selector"].match?(in_bubble) &&
        !r["selector"].match?(terminal) &&
        !r["selector"].match?(fixed_box) &&
        r["font_size"].match?(/\A[\d.]+px\z/)
    }

    expect(offenders.map { |r| "#{r["selector"]} { font-size: #{r["font_size"]} }" }).to eq([])
  end

  # The anchor itself. If this stops multiplying, every percentage underneath
  # becomes a percentage of a constant and the whole preference goes dead
  # without a single rule looking wrong.
  it "still multiplies the anchor by the reader's scale" do
    expect(rule_for(".byte-msg")&.fetch("font_size")).to match(
      /\Acalc\(14px \* var\(--byte-font-scale/,
    )
  end

  # Named individually so a regression says WHICH surface went back to a fixed
  # size rather than only that something did.
  {
    ".byte-msg.byte-msg-kind-buddy_activity [data-body]" => "the ✓ receipt for a tool that ran",
    ".byte-msg.byte-msg-kind-action_chip [data-body]"    => "the chip for a quick-action tap",
    ".byte-msg-action-row"                               => "a tool-use row waiting to be checked",
    ".byte-msg .byte-msg-meta"                           => "the timestamp under a message",
  }.each do |selector, what|
    it "scales #{what}" do
      rule = rule_for(selector)

      expect(rule).not_to be_nil, "#{selector} no longer sets a font-size"
      expect(rule["font_size"]).to match(/\A[\d.]+%\z/)
    end
  end
end
