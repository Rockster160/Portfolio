require "rails_helper"

# The auto-reload holds off while anything is open over the thread, and it
# recognises those surfaces by selector. A selector that stops matching fails
# SILENTLY and in the worst direction: the page reloads out from under an open
# drawer, a half-edited reminder, a photo being read, and nothing anywhere says
# why. So each one has to still find something.
RSpec.describe "Byte idle reload overlays" do
  let(:index) { Rails.root.join("app/javascript/src/pages/byte/index.js").read }
  let(:block) { index[/const OVERLAYS = \[(.*?)\];/m, 1] }
  let(:selectors) { block.to_s.scan(/"([^"]+)"/).flatten }

  # Everywhere a Byte surface can be declared: the shell, and the modules that
  # build the ones that don't exist until they're opened. index.js minus the
  # list itself, so the list can't satisfy the check by quoting itself.
  let(:haystack) {
    files = Dir[Rails.root.join("app/javascript/src/pages/byte/**/*.js").to_s]
    files.map { |f| Rails.root.join(f).read }.join("\n")
      .sub(block.to_s, "") + Rails.root.join("app/views/byte/show.html.erb").read
  }

  it "watches for every kind of surface that covers the thread" do
    expect(selectors.length).to be >= 6
    expect(selectors).to include("dialog[open]", ".byte-drawer.open")
  end

  it "names something that still exists, for every one of them" do
    selectors.each do |selector|
      base   = selector.sub(/:not\(.+\)\z/, "").sub(/\[open\]\z/, "")
      needle = base.delete_prefix(".").delete_prefix("[").delete_suffix("]").split(".").first
      expect(haystack).to include(needle), "#{selector} matches nothing in Byte any more"
    end
  end

  # The drawer is the one whose open state is a plain class rather than an
  # attribute the browser maintains, so it's the one that can drift apart.
  it "uses the class the drawer is actually opened with" do
    conversations = Rails.root.join("app/javascript/src/pages/byte/conversations.js").read

    expect(conversations).to include('drawer.classList.add("open")')
  end
end
