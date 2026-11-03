require "rails_helper"

RSpec.describe GoogleCalendar::EventColors do
  it "maps a Google color id, string or numeric, to its hex and nothing else to anything" do
    expect(described_class.hex_for("11")).to eq("#dc2127")
    expect(described_class.hex_for(7)).to eq("#46d6db")
    expect([described_class.hex_for("99"), described_class.hex_for(nil), described_class.hex_for("")]).to all(be_nil)
  end
end
