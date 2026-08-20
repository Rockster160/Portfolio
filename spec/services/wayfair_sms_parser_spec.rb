# Forwarded Wayfair SMS shapes (see also Shipments::SmsRouter).
RSpec.describe WayfairSmsParser do
  include ActiveSupport::Testing::TimeHelpers

  before do
    AmazonOrder.clear
    allow(MeCache).to receive(:get).and_call_original
    allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
    allow(AmazonOrder).to receive(:save)
    allow(AmazonOrder).to receive(:broadcast)
  end

  # Noon UTC → midday in Denver, so "today" doesn't straddle the UTC-midnight
  # boundary the way a bare Date would.
  around { |ex| travel_to(DateTime.new(2026, 8, 20, 18, 0, 0)) { ex.run } }

  wayfair_cases = [
    {
      desc:      "out for delivery",
      text:      "Wayfair: Exciting news! Your order is out for delivery. Track your desk here: https://www.wayfair.com/pXJxCqyzBM",
      name:      "desk",
      url:       "https://www.wayfair.com/pXJxCqyzBM",
      delivered: false,
      date:      Date.new(2026, 8, 20),
    },
    {
      desc:      "shipped with an arrival date",
      text:      "Wayfair: Your order has shipped and is arriving Aug 26. Track your nightstand here: https://www.wayfair.com/aB3xQ9zLm.",
      name:      "nightstand",
      url:       "https://www.wayfair.com/aB3xQ9zLm",
      delivered: false,
      date:      Date.new(2026, 8, 26),
    },
    {
      desc:      "delivered",
      text:      "Wayfair: Your desk was delivered. View your order here: https://www.wayfair.com/pXJxCqyzBM",
      name:      "desk",
      url:       "https://www.wayfair.com/pXJxCqyzBM",
      delivered: true,
      date:      Date.new(2026, 8, 20),
    },
  ]

  wayfair_cases.each do |c|
    context c[:desc] do
      subject(:item) { described_class.parse(c[:text]) }

      it "creates one Wayfair item with the parsed fields" do
        expect { item }.to change { AmazonOrder.all.size }.by(1)
        expect(item.carrier).to eq(:wayfair)
        expect(item.source).to eq("Wayfair")
        expect(item.name).to eq(c[:name])
        expect(item.custom_url).to eq(c[:url])
        expect(item.tracking_number).to be_nil
        expect(item.delivered).to eq(c[:delivered] || nil)
        expect(item.delivery_date).to eq(c[:date].iso8601)
      end
    end
  end

  it "ignores a marketing text that carries a wayfair link but no shipment status" do
    promo = "Wayfair: Way Day starts now! Up to 70% off. Track your favorites here: https://www.wayfair.com/zzQ1Ab2Cd"
    expect(described_class.parse(promo)).to eq(false)
    expect(AmazonOrder.all).to be_empty
  end

  it "connects a follow-up 'delivered' text to the active item for the same product" do
    described_class.parse(wayfair_cases[0][:text]) # desk, out for delivery
    expect { described_class.parse(wayfair_cases[2][:text]) }.not_to(change { AmazonOrder.all.size })
    expect(AmazonOrder.all.first.delivered).to be(true)
  end

  it "keeps two Wayfair products apart even though both say Wayfair" do
    described_class.parse(wayfair_cases[0][:text]) # desk
    expect { described_class.parse(wayfair_cases[1][:text]) }.to change { AmazonOrder.all.size }.by(1)
    expect(AmazonOrder.all.map(&:name)).to contain_exactly("desk", "nightstand")
  end

  it "connects an unnamed follow-up to the one active Wayfair item" do
    described_class.parse(wayfair_cases[0][:text]) # desk
    followup = "Wayfair: Your order is out for delivery today. https://www.wayfair.com/qQ7yZ2vNn"

    expect { described_class.parse(followup) }.not_to(change { AmazonOrder.all.size })
    item = AmazonOrder.all.first
    expect(item.name).to eq("desk")
    expect(item.custom_url).to eq("https://www.wayfair.com/qQ7yZ2vNn")
  end

  it "does not read a date out of the short link" do
    dated_link = "Wayfair: Your order is on its way. Track your rug here: https://www.wayfair.com/8/12/2020xYz"
    item = described_class.parse(dated_link)

    expect(item.delivery_date).to be_nil
  end
end
