# Fixtures cover the modern Amazon shipment email format (rio-card / rexMultiOrderCard):
#   50638 - Shipped, single item, "Arriving overnight 4 AM – 8 AM"
#   50641 - Delivered, grocery (no quoted name in subject)
#   50684 - Shipped, multi-item, "Arriving today 5 PM – 10 PM"
#   50685 - Ordered, single item, "Arriving tomorrow"
#   50687 - Delivered, multi-item (transition partner for 50684)
#   50688 - Delivered, multi-item, "and 1 more item" subject
#   50695 - Shipped, single item, "Arriving tomorrow"
RSpec.describe AmazonEmailParser do
  include ActiveSupport::Testing::TimeHelpers

  CASES = [
    {id: 50_638, subject: 'Shipped: "GOXAWEE Metal Stand Up Weed..."',                       order: "111-4126442-3377044", asins: ["B0GF24P6J3"],                    delivered: false, date_offset: 1, time_range: "4-8AM"},
    {id: 50_641, subject: "Delivered: Your Amazon grocery items | Order: ⁦#111-5515311-2607449⁩", order: "111-5515311-2607449", asins: ["B000P6G12U"],                    delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_684, subject: 'Shipped: ⁦2⁩ "Red Raspberries, 6 oz" and ⁦1⁩ more item',          order: "114-5001928-1633007", asins: ["B000P6G12U", "B000P717MI"],      delivered: false, date_offset: 0, time_range: "5-10PM"},
    {id: 50_685, subject: 'Ordered: "Amazon Basics Multipurpose..."',                         order: "111-0453665-0021069", asins: ["B01FV0F75G"],                    delivered: false, date_offset: 1, time_range: nil},
    {id: 50_687, subject: "Delivered: Your Amazon grocery items | Order: ⁦#114-5001928-1633007⁩", order: "114-5001928-1633007", asins: ["B000P6G12U", "B000P717MI"],      delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_688, subject: 'Delivered: "Pet Botanics 10 oz. Pouch..." and ⁦1⁩ more item',     order: "114-3328324-3906607", asins: ["B00065VGWK", "B0144BMLFM"],      delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_695, subject: 'Shipped: "Romeda 90 Pcs Ceiling Hooks..."',                        order: "111-3078388-1633869", asins: ["B0CJR8TQFT"],                    delivered: false, date_offset: 1, time_range: nil},
  ]

  def parse(email_id, subject)
    email = double(
      "Email",
      id:      email_id,
      to_html: html_fixture("email_body_#{email_id}", raw: true),
      subject: subject,
    )
    AmazonEmailParser.parse(email)
  end

  before do
    AmazonOrder.clear
    allow(AmazonOrder).to receive(:broadcast).and_return(nil)
    allow(AmazonOrder).to receive(:save).and_return(nil)
    allow(RestClient).to receive(:get).and_return(nil)
    allow(Jarvis).to receive(:cmd).and_return(nil)
    allow(ChatGPT).to receive(:short_name_from_order).and_return("ShortName")
    allow(SlackNotifier).to receive(:err).and_return(nil)
    allow(SlackNotifier).to receive(:notify).and_return(nil)
    allow_any_instance_of(AmazonEmailParser).to receive(:retrieve_full_name).and_return(nil)
  end

  around do |example|
    travel_to(DateTime.new(2026, 6, 8, 12, 0, 0)) { example.run }
  end

  CASES.each do |c|
    context "email #{c[:id]} (#{c[:subject][0..40]})" do
      before { parse(c[:id], c[:subject]) }

      it "creates one AmazonOrder per ASIN with correct order_id" do
        orders = AmazonOrder.by_order(c[:order])
        expect(orders.map(&:item_id)).to match_array(c[:asins])
        orders.each do |item|
          expect(item.order_id).to eq(c[:order])
          expect(item.email_ids).to include(c[:id])
          expect(item.errors).to be_none
        end
      end

      it "sets delivered=#{c[:delivered]} based on email status" do
        AmazonOrder.by_order(c[:order]).each do |item|
          expect(!!item.delivered).to eq(c[:delivered])
        end
      end

      it "sets delivery_date to #{c[:date_offset]} day(s) from now" do
        expected = (Date.current + c[:date_offset]).iso8601
        AmazonOrder.by_order(c[:order]).each do |item|
          expect(item.delivery_date).to eq(expected)
        end
      end

      it "sets time_range=#{c[:time_range].inspect}" do
        AmazonOrder.by_order(c[:order]).each do |item|
          expect(item.time_range).to eq(c[:time_range])
        end
      end
    end
  end

  describe "idempotency and state transitions" do
    it "does not duplicate orders when same email is parsed twice" do
      c = CASES.find { |row| row[:id] == 50_684 }
      parse(c[:id], c[:subject])
      parse(c[:id], c[:subject])
      expect(AmazonOrder.by_order(c[:order]).map(&:item_id)).to match_array(c[:asins])
    end

    it "flips an existing shipped order to delivered when its delivery email arrives" do
      shipped = CASES.find { |row| row[:id] == 50_684 }
      delivered = CASES.find { |row| row[:id] == 50_687 }
      parse(shipped[:id], shipped[:subject])
      AmazonOrder.by_order(shipped[:order]).each { |item| expect(item.delivered).to be_falsey }

      parse(delivered[:id], delivered[:subject])
      AmazonOrder.by_order(delivered[:order]).each do |item|
        expect(item.delivered).to eq(true)
        expect(item.email_ids).to include(shipped[:id], delivered[:id])
      end
    end
  end
end
