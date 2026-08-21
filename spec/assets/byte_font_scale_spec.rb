require "rails_helper"

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

  # The surfaces most likely to be re-added with a hard size, each named so a
  # failure says WHICH one went back rather than only that something did.
  named = {
    ".byte-msg.byte-msg-kind-buddy_activity [data-body]" => "the ✓ receipt for a tool that ran",
    ".byte-msg.byte-msg-kind-action_chip [data-body]"    => "the chip for a quick-action tap",
    ".byte-msg-action-row"                               => "a tool-use row waiting to be checked",
    ".byte-msg .byte-msg-meta"                           => "the timestamp under a message",
  }

  let(:rules) { CompiledCss.sized }

  it "sizes everything in a bubble relative to the one scaled anchor" do
    offenders = rules.select { |r|
      r["selector"].match?(in_bubble) &&
        !r["selector"].match?(terminal) &&
        !r["selector"].match?(fixed_box) &&
        r["font_size"].match?(/\A[\d.]+px\z/)
    }

    expect(offenders.map { |r| "#{r["selector"]} { font-size: #{r["font_size"]} }" }).to eq([])
  end

  # The anchor and the four surfaces hanging off it, in one example: they are
  # one fact — the multiplication happens once and everything under it is a
  # percentage — and splitting them into five cost five compiles of the sheet
  # to assert five halves of the same sentence. The failure still names the
  # surface, which is the only thing the split was buying.
  it "multiplies the anchor by the reader's scale, and sizes each surface off it" do
    expect(rules.find { |r| r["selector"] == ".byte-msg" }&.fetch("font_size")).to match(
      /\Acalc\(14px \* var\(--byte-font-scale/,
    )

    broken = named.filter_map { |selector, what|
      size = rules.find { |r| r["selector"] == selector }&.fetch("font_size")
      next if size&.match?(/\A[\d.]+%\z/)

      "#{what} (#{selector}): #{size || "no longer sets a font-size"}"
    }

    expect(broken).to eq([])
  end
end
