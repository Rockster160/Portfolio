require "rails_helper"

# A picture in the thread was invisible for as long as the network took, and
# then arrived all at once and shoved everything above it — mid-read, mid-scroll
# — because an <img> with no dimensions of its own is 0px tall until its bytes
# land.
#
# The fix is a frame reserved before the picture exists, and the whole thing
# rests on ONE property: the frame's height is the same empty as it is full.
# That's a fact about the compiled cascade rather than about any single
# declaration, which is why it's asserted here and not in a diff.
RSpec.describe "Byte thread image frame" do
  let(:rules) { CompiledCss.rules.select { |r| r["selector"].include?(".byte-attachment-image") } }

  # The frame itself: not the loaded state, not the <img> inside it.
  let(:frame) {
    rules.find { |r|
      r["selector"].end_with?(".byte-attachment-image") && r["selector"].exclude?("loaded")
    }
  }

  # The load-bearing property, from both sides in one example: a real box
  # reserved up front, and nothing in the loaded state that could change its
  # height afterwards. Either half alone puts the jump back, so a failure in
  # either is the same failure.
  it "reserves a real box, and the picture arriving never changes its height" do
    expect(frame).not_to be_nil, "the image frame rule is gone entirely"
    # Both dimensions, or what's waiting is a sliver rather than something
    # picture-shaped.
    expect(frame["body"]).to match(/height: \d+px/)
    expect(frame["body"]).to match(/width: \d+px/)

    loaded = rules.select { |r| r["selector"].include?("byte-attachment-loaded") }
    expect(loaded).not_to be_empty, "nothing marks the frame as loaded"

    offenders = loaded.select { |r| r["body"].match?(/(^|[; ])(height|max-height|aspect-ratio|padding):/) }
    expect(offenders.pluck("selector")).to eq([])
  end

  # A fixed height only holds for every shape of picture because the picture is
  # fitted inside it. `cover` would crop and a plain stretch would squash.
  it "fits the picture inside the frame rather than cropping it" do
    img = rules.find { |r| r["selector"].match?(/\.byte-attachment-image img\z/) }

    expect(img).not_to be_nil
    expect(img["body"]).to include("object-fit: contain")
    expect(img["body"]).to match(/height: 100%/)
  end

  # The waiting animation runs on an EMPTY frame; once there's a picture in it,
  # pulsing the opacity would be pulsing the picture. Turning motion down stops
  # it the same way, and — the part that matters — without touching the height,
  # or the reserved box goes away for the people least able to absorb a jump.
  it "stops the waiting animation once loaded, and for anyone who asked for less motion" do
    loaded = rules.find { |r| r["selector"].end_with?(".byte-attachment-loaded") }
    still  = rules.find { |r| r["conditions"].include?("@media (prefers-reduced-motion: reduce)") }

    expect(frame["body"]).to match(/animation: byte-attachment-wait/)
    expect(loaded["body"]).to include("animation: none")

    expect(still).not_to be_nil, "the frame breathes even when motion is turned down"
    expect(still["body"]).to include("animation: none")
    expect(still["body"]).not_to match(/height/)
  end
end
