require "rails_helper"

# "I want to be able to drag-drop the file. If I can, it's not clear that I can
# or where I should drop it."
RSpec.describe "Drop zone (JS-side)" do
  let(:result) {
    JsRunner.output("spec/javascript/drop_zone_runner.js", symbolize: true)
  }

  it "wires the zone the page actually has" do
    expect(result[:wired]).to eq(1)
  end

  # The transcripts section is collapsed on an application with no recordings,
  # which is every application the first time. You cannot drop onto something
  # you cannot see, so a file arriving over the window opens it.
  it "opens the section holding the zone when a file comes over the page" do
    expect(result[:detailsOpenBefore]).to be(false)
    expect(result[:afterDragEnter][:detailsOpen]).to be(true)
  end

  it "lights the zone up so there is somewhere to aim at" do
    expect(result[:afterDragEnter][:zone]).to include("ready")
  end

  # Dragging across a child element fires `dragleave` on the parent. Counted
  # rather than toggled, or the zone flickers the whole time the file is moving.
  it "stays lit while the file moves across the page" do
    expect(result[:stillLitWhileMoving]).to include("ready")
  end

  # Without this the browser navigates away to the file, losing the page and
  # anything typed into it.
  it "does nothing when the drop misses" do
    expect(result[:missedDropPrevented]).to be(true)
    expect(result[:afterMiss]).not_to include("ready")
  end

  it "puts the dropped file on the real input and names it" do
    expect(result[:dropped][:files]).to eq(1)
    expect(result[:dropped][:name]).to eq("call.txt")
    expect(result[:dropped][:got]).to eq("call.txt")
    expect(result[:dropped][:zone]).to include("got")
  end

  # Selected text and links get dragged around a page all the time, and
  # cancelling those would break ordinary dragging on the rest of the page.
  it "leaves a drag that is not a file alone" do
    expect(result[:textDragPrevented]).to be(false)
  end
end
