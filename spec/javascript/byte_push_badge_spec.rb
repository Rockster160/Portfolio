require "rails_helper"
require "json"
require "open3"

# The home-screen badge kept a number while the app was open and showing
# nothing unread.
#
# Two halves, and both had to be wrong for it to stick:
#
#   * The service worker wrote the badge from the push BEFORE the foreground
#     check that everything else in the handler respects. A message that
#     correctly skipped its banner because the app was open still stamped the
#     icon — with a server count that includes the conversation being read.
#   * The page couldn't undo it. The badge painter was wired to the unread
#     tracker, which by design only tracks conversations the person ISN'T in, so
#     it never fired for the thread on screen.
#
# And underneath both: `POST .../read` only ran when a conversation was OPENED,
# so a message arriving in the thread already in front of you was read by the
# person and never by the record. Prod conversation 21 was holding six of those.
#
# This file covers the worker half — the half with no UI, where being wrong is
# invisible until an icon won't come clean. The page half is now unconditional
# and lives in `app_badge_spec.rb`: opening the app clears the badge whatever
# anything else believes, which is what finally made a stuck number impossible
# rather than merely unlikely.
RSpec.describe "Byte push badge" do
  let(:acted) {
    runner = Rails.root.join("spec/javascript/byte_push_badge_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  # The reported bug.
  describe "while the app is open and being looked at" do
    subject(:result) { acted["app_open"] }

    it "leaves the badge alone, because the page owns it" do
      expect(result["badgeSet"]).to be_nil
      expect(result["badgeCleared"]).to be(false)
    end

    it "still suppresses the banner, as it always did" do
      expect(result["notified"]).to be_nil
    end
  end

  # A window that exists but isn't being looked at has seen nothing. This is the
  # case that makes "is a client open?" the wrong question and "can they see
  # it?" the right one.
  describe "while the app is backgrounded" do
    it "sets the badge from the push count" do
      expect(acted["app_backgrounded"]["badgeSet"]).to eq(6)
    end

    it "shows the banner" do
      expect(acted["app_backgrounded"]["notified"]).to include("title" => "Kettle's done")
    end
  end

  # Closed is the whole reason the count rides on the push: nothing else is
  # running that could set it.
  describe "while the app is closed" do
    it "sets the badge from the push count" do
      expect(acted["app_closed"]["badgeSet"]).to eq(6)
    end
  end

  describe "when the count says there's nothing left" do
    it "clears the badge rather than leaving the old number" do
      expect(acted["cleared_when_zero"]["badgeCleared"]).to be(true)
      expect(acted["cleared_when_zero"]["badgeSet"]).to be_nil
    end

    # A push with no count at all (an older payload, a path that forgot it)
    # must read as zero. `parseInt(undefined)` is NaN, and NaN > 0 is false,
    # so this falls to the clear — asserted because it's load-bearing and not
    # obvious from reading it.
    it "treats a missing count as nothing rather than as NaN" do
      expect(acted["no_count"]["badgeCleared"]).to be(true)
    end
  end
end
