require "rails_helper"

RSpec.describe Buddy::MarkerParser do
  it "extracts a single marker with quoted args" do
    text = %(Sure — [[propose: log_event name="Coffee" notes="oat milk"]] done)
    result = described_class.extract(text)

    expect(result[:markers]).to eq([
      { tool_name: :log_event,
        payload:   { name: "Coffee", notes: "oat milk" },
        span:      result[:markers].first[:span] },
    ])
    expect(result[:display_text]).to eq("Sure — done")
  end

  it "extracts multiple markers with mixed arg quoting" do
    text = "[[propose: complete_chore chore=\"kitchen counter\"]] [[propose: log_event name=Coffee]]"
    markers = described_class.extract(text)[:markers]

    expect(markers.length).to eq(2)
    expect(markers[0][:tool_name]).to eq(:complete_chore)
    expect(markers[0][:payload]).to eq(chore: "kitchen counter")
    expect(markers[1][:tool_name]).to eq(:log_event)
    expect(markers[1][:payload]).to eq(name: "Coffee")
  end

  it "handles count as a top-level arg" do
    result = described_class.extract('[[propose: log_event name="Water" count=5]]')
    expect(result[:markers].first[:payload]).to include(count: "5")
  end

  it "returns empty markers when body has none" do
    result = described_class.extract("Just talking, no markers here.")
    expect(result[:markers]).to be_empty
    expect(result[:display_text]).to eq("Just talking, no markers here.")
  end

  it "returns empty markers on blank input" do
    expect(described_class.extract("")).to eq(markers: [], display_text: "")
    expect(described_class.extract(nil)).to eq(markers: [], display_text: "")
  end
end
