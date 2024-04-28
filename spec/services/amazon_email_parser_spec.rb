# Test emails:
# 3563 - multiple items with different delivery dates (fixture)
# 3550 - different format (basic info card - Out for delivery "Today")
# 3545 - different format (last info card - Order delayed "tomorrow by...")
# 3465 - multiple items
# 3458, 3455, 3454, 3450, 3393, 3392, 3347, 3346, 3344, 3342, 3338, 3336, 3335, 3334,
# 3332, 3330, 3329, 3328, 3327, 3325, 3324, 3323, 3321, 3318, 3317, 3312, 3311, 3311, 3310, 3280,
# 3275, 3274, 3271, 3270, 3264, 3261, 3258, 3255, 3254, 3253

RSpec.describe AmazonEmailParser do
  def parse(email_id)
    email = double(
      "Email",
      id: email_id,
      html_body: html_fixture("email_body_#{email_id}", raw: true)
    )
    AmazonEmailParser.parse(email)
  end
  let(:name_mapping) { {} }

  before do
    allow(AmazonOrder).to receive(:broadcast) do |*args| # Stub websockets
    end
    allow(RestClient).to receive(:get) do |*args| # Stub external requests
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

  context "with an email including multiple items" do
    before { parse(3563) }
    let(:name_mapping) {
      {
        B00AV283TC: {
          listed: "Bath & Body Works Signature...",
          full: "Bath & Body Works Signature Collection Body Lotion Dark Kiss, 8 Fl Oz (Pack of 3)",
          short: "Body Lotion",
        },
        B014UJIIQY: {
          listed: "Bath & Body Works Dark Kiss...",
          full: "Bath & Body Works Dark Kiss Ultra Shea Body Cream, 8 Ounce",
          short: "Shea Body Cream",
        },
        B0090U7O00: {
          listed: "Bath & Body Works Dark Kiss...",
          full: "Bath & Body Works Dark Kiss Shower Gel, 10 Ounce",
          short: "Shower Gel",
        },
        B0090U6RK8: {
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
      end
    end
  end
end
