require "rails_helper"
require "json"
require "open3"

# The slash popover used to offer all 21 commands in every thread, so a Buddy
# conversation advertised eight ways to manage a Claude session and a shell it
# can't reach, and a non-owner was offered `/mode` in a thread that's pinned to
# buddy. None of them would have worked - ByteController and ByteMessageIntake
# refuse each one - but a menu full of dead entries is its own bug.
#
# This runs the real module rather than re-deriving the list, so a command added
# without a `modes:` key fails here instead of quietly showing up everywhere.
RSpec.describe "Slash command scoping" do
  let(:mac_only) { %w[sessions switch adopt join new watch unwatch watches wait waits abort pwd help] }

  def offered(mode:, owner:)
    script = <<~JS
      import { available } from "#{Rails.root.join("app/javascript/src/pages/byte/slash_commands.js")}";
      console.log(JSON.stringify(available({ mode: #{mode.to_s.inspect}, owner: #{owner} })));
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", stdin_data: script)
    raise "node failed: #{err}" unless status.success?

    JSON.parse(out).map { |c| c["name"] }
  end

  describe "a Buddy thread" do
    it "offers nothing that lives on the Mac" do
      expect(offered(mode: :buddy, owner: true)).not_to include(*mac_only)
    end

    it "keeps the Buddy commands and the ones that work in any thread" do
      expect(offered(mode: :buddy, owner: true)).to include(
        "buddy", "reset", "rename", "archive", "fork", "clear"
      )
    end
  end

  describe "a Claude thread" do
    it "still offers the whole Mac surface" do
      expect(offered(mode: :claude, owner: true)).to include(*mac_only)
    end

    it "leaves out the Buddy-only ones" do
      expect(offered(mode: :claude, owner: true)).not_to include("buddy", "reset", "compact")
    end
  end

  # Non-owners are pinned to buddy mode (ByteController#buddy_only?), so mode is
  # the only command that's theirs to lose - everything else in a Buddy thread
  # acts on their own conversation.
  describe "a non-owner" do
    it "isn't offered a mode switch they can't make" do
      expect(offered(mode: :buddy, owner: false)).not_to include("mode")
      expect(offered(mode: :buddy, owner: true)).to include("mode")
    end

    it "keeps everything else about their own thread" do
      expect(offered(mode: :buddy, owner: false)).to include("buddy", "reset", "rename", "archive")
    end
  end

  it "gives every command a home, so a new one can't default to showing everywhere" do
    everywhere = %w[rename archive fork clear mode]
    scoped     = offered(mode: :claude, owner: true) | offered(mode: :buddy, owner: true)
    jarvis     = offered(mode: :jarvis, owner: true)

    # A jarvis thread reaches neither the Mac's meta handler nor Buddy, so what
    # it offers is exactly the always-available set.
    expect(jarvis).to match_array(everywhere)
    expect(scoped).to include(*everywhere)
  end
end
