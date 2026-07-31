# Real forwarded UPS SMS shapes (see also Shipments::SmsRouter).
RSpec.describe UpsSmsParser do
  include ActiveSupport::Testing::TimeHelpers

  before do
    AmazonOrder.clear
    allow(MeCache).to receive(:get).and_call_original
    allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
    allow(AmazonOrder).to receive(:save)
    allow(AmazonOrder).to receive(:broadcast)
  end

  # Noon UTC → midday in Denver, so "today"/"tomorrow" don't straddle the
  # UTC-midnight boundary the way a bare Date would.
  around { |ex| travel_to(DateTime.new(2026, 7, 30, 18, 0, 0)) { ex.run } }

  ups_cases = [
    {
      desc:      "On the Way, single deadline",
      text:      "UPS: On the Way. ups.com/su/WmNiNXMx Expect your NINGBO DEYI SAM package on 08/03/2026 by 9:00 PM. Reply STOP to cancel msgs",
      source:    "NINGBO DEYI SAM",
      tracking:  nil,
      delivered: false,
      date:      Date.new(2026, 8, 3),
      time_range: "9PM",
    },
    {
      desc:      "Delivered",
      text:      "UPS: Delivered your NINGBO DEYI SAM package on 07/20/2026 at 5:35 PM. Reply STOP to cancel msgs",
      source:    "NINGBO DEYI SAM",
      tracking:  nil,
      delivered: true,
      date:      Date.new(2026, 7, 20),
      time_range: nil,
    },
    {
      desc:      "Delivery Update, window",
      text:      "UPS: Delivery Update. ups.com/su/eUhCR3Vs Expect your NINGBO DEYI SAM package on 07/20/2026 between 5:45 PM and 7:45 PM. Reply STOP to cancel msgs",
      source:    "NINGBO DEYI SAM",
      tracking:  nil,
      delivered: false,
      date:      Date.new(2026, 7, 20),
      time_range: "5-7PM",
    },
    {
      desc:      "Tracking-only, delivering tomorrow",
      text:      "UPS: 1Z16D56V0310080972 delivering tomorrow by 9:00 PM. Change Delivery: ups.com/su/dXpqUWxp. Reply STOP to cancel msgs",
      source:    nil,
      tracking:  "1Z16D56V0310080972",
      delivered: false,
      date:      Date.new(2026, 7, 31),
      time_range: "9PM",
    },
  ]

  ups_cases.each do |c|
    context c[:desc] do
      subject(:item) { described_class.parse(c[:text]) }

      it "creates one UPS item with the parsed fields" do
        expect { item }.to change { AmazonOrder.all.size }.by(1)
        expect(item.carrier).to eq(:ups)
        expect(item.source).to eq(c[:source])
        expect(item.tracking_number).to eq(c[:tracking])
        expect(item.delivered).to eq(c[:delivered] || nil)
        expect(item.delivery_date).to eq(c[:date].iso8601)
        expect(item.time_range).to eq(c[:time_range])
      end
    end
  end

  it "ignores a delivery-count digest text (no item created)" do
    digest = "UPS: You have 2 packages estimated for delivery today. Manage your deliveries: ups.com/su/NXVpbnNV. Reply STOP to cancel msgs"
    expect(described_class.parse(digest)).to eq(false)
    expect(AmazonOrder.all).to be_empty
  end

  it "connects a follow-up 'Delivered' update to the active item of the same source" do
    described_class.parse(ups_cases[0][:text]) # On the Way for NINGBO DEYI SAM
    expect { described_class.parse(ups_cases[1][:text]) }.not_to(change { AmazonOrder.all.size })
    expect(AmazonOrder.all.first.delivered).to be(true)
  end
end
