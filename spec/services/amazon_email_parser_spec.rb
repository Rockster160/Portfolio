# Test emails:
# 3563 - multiple items with different delivery dates (fixture)
# 3550 - different format (basic info card - Out for delivery "Today")
# 3545 - different format (last info card - Order delayed "tomorrow by...")
# 3465 - multiple items
# 3458, 3455, 3454, 3450, 3393, 3392, 3347, 3346, 3344, 3342, 3338, 3336, 3335, 3334,
# 3332, 3330, 3329, 3328, 3327, 3325, 3324, 3323, 3321, 3318, 3317, 3312, 3311, 3311, 3310, 3280,
# 3275, 3274, 3271, 3270, 3264, 3261, 3258, 3255, 3254, 3253

RSpec.describe AmazonEmailParser do
  include ActiveSupport::Testing::TimeHelpers
  def parse(email_id)
    email = double(
      "Email",
      id: email_id,
      to_html: html_fixture("email_body_#{email_id}", raw: true),
      subject: "Whatever"
    )
    AmazonEmailParser.parse(email)
  end
  let(:name_mapping) { {} }

  around do |example|
    AmazonOrder.clear
    travel_to(DateTime.new(2024, 4, 26)) do
      example.run
    end
  end

  before do
    allow(AmazonOrder).to receive(:broadcast) do |*args| # Stub websockets
    end
    allow(RestClient).to receive(:get) do |*args| # Stub external requests
    end
    allow(Jarvis).to receive(:cmd) do |*args| # Stub external requests
    end
    allow(ChatGPT).to receive(:short_name_from_order) do |*args| # Stub GPT requests
      name_mapping.dig(args.second&.item_id&.to_sym, :short)
    end
    allow(SlackNotifier).to receive(:err) do |*args| # Stub Slack messages
    end
    allow_any_instance_of(AmazonEmailParser).to receive(:retrieve_full_name) do |instance, *args|
      # TODO: Fix this stub
    end
  end

  context "standard item" do
    before { parse(3564) }
    let(:name_mapping) {
      {
        B07F19DK3S: {
          date: "2024-04-28",
          listed: "WYNNsky Low Pressure Pencil...",
          full: "WYNNsky Low Pressure Pencil Tire Gauge 1-20 PSI for Golf Carts, ATV'S and Air Springs",
          short: "Tire Gauge",
        },
      }
    }

    it "extracts all of the expected data" do
      orders = AmazonOrder.all
      expect(orders.length).to eq(1)

      order_id = orders.first.order_id
      name_mapping.each do |item_id, names|
        item = AmazonOrder.find(order_id, item_id.to_s)
        expect(item.item_id).to eq(item_id.to_s)
        expect(item.listed_name).to eq(names[:listed])
        # expect(item.full_name).to eq(names[:full]) -- Broken because `allow_any_instance_of`
        expect(item.name).to eq(names[:short])
        expect(item.delivery_date).to eq(names[:date])

        expect(item.errors).to be_none
      end
    end
  end

  # Don't work because they need an item to update
  # context "delivery today" do
  #   before { parse(3550) }
  #   let(:name_mapping) {
  #     {
  #       # B00AV283TC: {
  #       #   date: "2024-05-02",
  #       #   listed: "Bath & Body Works Signature...",
  #       #   full: "Bath & Body Works Signature Collection Body Lotion Dark Kiss, 8 Fl Oz (Pack of 3)",
  #       #   short: "Body Lotion",
  #       # },
  #     }
  #   }
  #
  #   it "updates the order to the current day" do
  #     orders = AmazonOrder.all
  #     expect(orders.length).to eq(1)
  #
  #     order_id = orders.first.order_id
  #     name_mapping.each do |item_id, names|
  #       item = AmazonOrder.find(order_id, item_id.to_s)
  #       expect(item.item_id).to eq(item_id.to_s)
  #       expect(item.listed_name).to eq(names[:listed])
  #       # expect(item.full_name).to eq(names[:full]) -- Broken because `allow_any_instance_of`
  #       expect(item.name).to eq(names[:short])
  #       expect(item.delivery_date).to eq(names[:date])
  #
  #       expect(item.errors).to be_none
  #     end
  #   end
  # end
  #
  # context "delivery tomorrow" do
  #   before { parse(3545) }
  #   let(:name_mapping) {
  #     {
  #       # B00AV283TC: {
  #       #   date: "2024-05-02",
  #       #   listed: "Bath & Body Works Signature...",
  #       #   full: "Bath & Body Works Signature Collection Body Lotion Dark Kiss, 8 Fl Oz (Pack of 3)",
  #       #   short: "Body Lotion",
  #       # },
  #     }
  #   }
  #
  #   it "updates the order to the current day" do
  #     orders = AmazonOrder.all
  #     expect(orders.length).to eq(1)
  #
  #     order_id = orders.first.order_id
  #     name_mapping.each do |item_id, names|
  #       item = AmazonOrder.find(order_id, item_id.to_s)
  #       expect(item.item_id).to eq(item_id.to_s)
  #       expect(item.listed_name).to eq(names[:listed])
  #       # expect(item.full_name).to eq(names[:full]) -- Broken because `allow_any_instance_of`
  #       expect(item.name).to eq(names[:short])
  #       expect(item.delivery_date).to eq(names[:date])
  #
  #       expect(item.errors).to be_none
  #     end
  #   end
  # end

  context "with an email including multiple items" do
    before { parse(3563) }
    let(:name_mapping) {
      {
        B00AV283TC: {
          date: "2024-05-02",
          listed: "Bath & Body Works Signature...",
          full: "Bath & Body Works Signature Collection Body Lotion Dark Kiss, 8 Fl Oz (Pack of 3)",
          short: "Body Lotion",
        },
        B014UJIIQY: {
          date: "2024-04-28",
          listed: "Bath & Body Works Dark Kiss...",
          full: "Bath & Body Works Dark Kiss Ultra Shea Body Cream, 8 Ounce",
          short: "Shea Body Cream",
        },
        B0090U7O00: {
          date: "2024-04-28",
          listed: "Bath & Body Works Dark Kiss...",
          full: "Bath & Body Works Dark Kiss Shower Gel, 10 Ounce",
          short: "Shower Gel",
        },
        B0090U6RK8: {
          date: "2024-04-30",
          listed: "Bath & Body Works Dark Kiss...",
          full: "Bath & Body Works Dark Kiss Fine Fragrance Mist, 8 Ounce",
          short: "Fragrance Mist",
        },
      }
    }

    it "creates 4 separate orders" do
      orders = AmazonOrder.all
      expect(orders.length).to eq(4)

      order_id = orders.first.order_id
      name_mapping.each do |item_id, names|
        item = AmazonOrder.find(order_id, item_id.to_s)
        expect(item.item_id).to eq(item_id.to_s)
        expect(item.listed_name).to eq(names[:listed])
        # expect(item.full_name).to eq(names[:full]) -- Broken because `allow_any_instance_of`
        expect(item.name).to eq(names[:short])
        expect(item.delivery_date).to eq(names[:date])

        expect(item.errors).to be_none
      end
    end
  end
end
