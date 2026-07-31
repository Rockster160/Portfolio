# USPS tracking emails are HTML. These fixtures are synthetic but mirror the
# real "Expected Delivery / out for delivery" and Informed-Delivery digest
# content (see the forwarded samples). Built as inline HTML through an Email
# double, same style as spec/services/amazon_email_parser_spec.rb.
RSpec.describe UspsEmailParser do
  include ActiveSupport::Testing::TimeHelpers

  before do
    AmazonOrder.clear
    allow(MeCache).to receive(:get).and_call_original
    allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
    allow(AmazonOrder).to receive(:save)
    allow(AmazonOrder).to receive(:broadcast)
  end

  around { |ex| travel_to(DateTime.new(2026, 7, 16, 18, 0, 0)) { ex.run } }

  def email(subject:, body_html:)
    double("Email", subject: subject, to_html: body_html)
  end

  it "parses an out-for-delivery tracking email" do
    item = described_class.parse(email(
      subject:   "USPS® Expected Delivery by Thursday, July 16, 2026 arriving by 9:00pm 9200190267338000065163052",
      body_html: <<~HTML,
        <p>Your item is out for delivery on July 16, 2026 at 7:18 am in HERRIMAN, UT 84096.</p>
        <p>USPS expects to deliver your package today by 9:00pm.</p>
        <p>Tracking Number: 9200190267338000065163052</p>
        <p>Package Shipped from: SHOPIFY</p>
        <div>Out for Delivery</div>
      HTML
    ))

    expect(item.carrier).to eq(:usps)
    expect(item.tracking_number).to eq("9200190267338000065163052")
    expect(item.source).to eq("SHOPIFY")
    expect(item.name).to eq("SHOPIFY")
    expect(item.delivered).to be_nil
    expect(item.delivery_date).to eq(Date.new(2026, 7, 16).iso8601)
    expect(item.time_range).to eq("9PM")
    expect(item.item_id).to eq("9200190267338000065163052")
  end

  it "flips delivered on a delivered email and connects by tracking number" do
    described_class.parse(email(
      subject:   "USPS® Expected Delivery by Thursday, July 16, 2026",
      body_html: "<p>Tracking Number: 9200190267338000065163052</p><p>Package Shipped from: SHOPIFY</p>",
    ))

    expect {
      described_class.parse(email(
        subject:   "USPS® Your item was delivered",
        body_html: "<p>Your item was delivered at 2:14 pm on July 16, 2026.</p><p>Tracking Number: 9200190267338000065163052</p>",
      ))
    }.not_to(change { AmazonOrder.all.size })

    expect(AmazonOrder.all.first.delivered).to be(true)
  end

  it "skips an Informed-Delivery digest (mailpieces) — no item created" do
    result = described_class.parse(email(
      subject:   "Your Daily Digest for Thu, 7/16 is ready to view",
      body_html: "<p>You have 1 mailpiece(s) and 1 inbound package(s) arriving soon.</p>",
    ))

    expect(result).to eq(false)
    expect(AmazonOrder.all).to be_empty
  end

  it "skips a tracking email with no tracking number" do
    result = described_class.parse(email(
      subject:   "USPS® Expected Delivery",
      body_html: "<p>Your package is on its way.</p>",
    ))

    expect(result).to eq(false)
    expect(AmazonOrder.all).to be_empty
  end
end
