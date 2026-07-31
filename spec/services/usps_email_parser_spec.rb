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

  def email(subject:, body_html:, id: 900)
    double("Email", id: id, subject: subject, to_html: body_html)
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
    expect(item.email_ids).to include(900) # so the dashboard can open the email
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

  it "parses packages out of an Informed-Delivery digest, skipping mailpieces" do
    described_class.parse(email(
      subject:   "Your Daily Digest for Thu, 7/16 is ready to view",
      body_html: <<~HTML,
        <p>You have 1 mailpiece(s) and 1 inbound package(s) arriving soon.</p>
        <div>MAIL</div>
        <div>Expected Today</div>
        <div>PACKAGES</div>
        <div>Expected Today</div>
        <div>FROM: SHOPIFY <span>9200190267338000065163052</span></div>
        <div>Expected 1-2 Days</div>
        <div>FROM: NINGBO DEYI SAM <span>9405511899560000000000</span></div>
        <div>Outbound</div>
        <div>FROM: ME <span>9111111111111111111111</span></div>
      HTML
    ))

    shopify = AmazonOrder.all.find { |o| o.tracking_number == "9200190267338000065163052" }
    ninbo   = AmazonOrder.all.find { |o| o.tracking_number == "9405511899560000000000" }

    expect(shopify.carrier).to eq(:usps)
    expect(shopify.source).to eq("SHOPIFY")
    expect(shopify.delivery_date).to eq(Date.new(2026, 7, 16).iso8601)   # Expected Today
    expect(ninbo.source).to eq("NINGBO DEYI SAM")
    expect(ninbo.delivery_date).to eq(Date.new(2026, 7, 17).iso8601)     # Expected 1-2 Days
    # Outbound package is skipped:
    expect(AmazonOrder.all.map(&:tracking_number)).not_to include("9111111111111111111111")
  end

  it "does not create an item for a digest with only mailpieces (no packages)" do
    result = described_class.parse(email(
      subject:   "Your Daily Digest for Thu, 7/16 is ready to view",
      body_html: "<p>You have 2 mailpiece(s) and 0 inbound package(s) arriving soon.</p>",
    ))

    expect(result).to be_falsey
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
