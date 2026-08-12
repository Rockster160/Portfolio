require "rails_helper"
require "json"
require "open3"

# The home-screen badge showed a 1 that no message anywhere accounted for: every
# conversation the icon counts was read, the server's total was 0, and the
# number sat there anyway.
#
# Nothing was writing it wrongly. Nothing was writing it at all. Four service
# workers call `setAppBadge(data.count)` on a push and that was the only code in
# the app that ever touched the icon; the one page-side painter (Byte's) ran off
# its unread tracker's `onChange`, and opening the app with nothing unread is
# not a change from nothing unread. So a badge a push left behind had no path
# back to zero — not opening the app, not reading the thread, not anything the
# person could do.
#
# A badge is a claim that something is waiting, and opening the app is the only
# answer to it available to them. One that survives being opened can't be got
# rid of, and stops meaning anything the first time it lies.
RSpec.describe "PWA home-screen badge" do
  let(:result) {
    runner = Rails.root.join("spec/javascript/app_badge_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  describe "any page at all" do
    # Importing the module is the app being opened. No count, no fetch, no
    # condition — the clear is the first thing that happens.
    it "clears the badge on open" do
      expect(result["on_import"]).to eq(["clear"])
    end

    # The one that matters on a phone. A PWA is almost never loaded fresh; it's
    # swiped back to, and that fires neither load nor pageshow.
    it "clears it again on every return to the foreground" do
      expect(result["on_return_to_foreground"]).to eq(["clear"])
    end

    it "clears it on a back/forward restore, which fires no load event" do
      expect(result["on_pageshow"]).to eq(["clear"])
    end

    it "leaves it alone on the way out" do
      expect(result["on_going_to_background"]).to be_empty
    end
  end

  describe "a page that knows the real number" do
    it "takes the badge over and paints its count immediately" do
      expect(result["on_claim"]).to eq([["set", 3]])
    end

    # Asked for the number each time rather than handed it once: a thread that
    # filled up while the app was backgrounded has to be able to push the badge
    # UP on the way back in, not only clear it.
    it "re-reads the count on every return rather than replaying a stale one" do
      expect(result["claimed_returns_fresh"]).to eq([["set", 5]])
    end

    it "clears when its own count reaches zero" do
      expect(result["claimed_at_zero"]).to eq([["clear"]])
    end
  end

  it "never sets a zero or negative badge, which some platforms render as a dot" do
    expect(result["direct"]).to eq([["clear"], ["set", 2], ["clear"]])
  end
end
