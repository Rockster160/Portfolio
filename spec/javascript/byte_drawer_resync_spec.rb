require "rails_helper"

# The hamburger said 1 and the drawer showed nothing unread, which is a number
# with no way to answer it: the row that would clear it by being opened is
# exactly the row that isn't there.
#
# Conversation 43 is archived standup-prep plumbing that a scheduled job still
# posts into. `list_conversations` is `.active`, so it has no row and the
# server's own total leaves it out — but the page counted anything that wasn't
# the thread on screen, and once it had, nothing took it off again. Seeding only
# ever added.
#
# So the list is refetched when the drawer is opened, and a seed is now the
# whole truth about which threads exist rather than a set of numbers to merge.
# Opening the drawer is the one moment the counts are about to be read and the
# one moment the person can act on them, which makes it the right place to ask.
RSpec.describe "Byte drawer resync" do
  let(:result) { JsRunner.output("spec/javascript/byte_drawer_resync_runner.js") }

  it "asks the server for the list every time the drawer is opened" do
    expect(result["requests_at_open"]).to eq(["GET /byte/conversations"])
  end

  # Not something to wait behind. The drawer slides in on the cached list and
  # the numbers correct themselves underneath when the answer lands.
  it "opens on what it already has rather than on the answer" do
    expect(result["open_before_fetch"]).to be(true)
    expect(result["still_open"]).to be(true)
  end

  # The point of the refetch: a thread the page has been counting is simply
  # gone from the answer, and that has to reach the counter as a fact rather
  # than as an absence it can ignore.
  it "hands the counter the smaller world it got back" do
    expect(result["seeded"]).to eq([[[21, 0], [37, 2]], [[21, 0]]])
  end

  it "still refreshes once on its own at boot" do
    expect(result["on_boot"]).to eq(["GET /byte/conversations"])
  end
end
