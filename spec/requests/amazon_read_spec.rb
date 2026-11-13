require "rails_helper"

RSpec.describe "Reading Amazon orders on the Mini" do
  before {
    AmazonOrder.clear
    allow(ByteLocal).to receive(:valid_secret?).and_return(false)
    allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
  }

  describe "POST /webhooks/byte/amazon_orders", type: :request do
    let(:payload) {
      { read_at: "2026-11-13T01:34:55Z", orders: [{ order_id: "111-4653427-0102644", shipments: [] }] }
    }

    it "applies what the Mini read in a job of its own" do
      allow(AmazonReadResultWorker).to receive(:perform_async)

      post "/webhooks/byte/amazon_orders", params: payload, as: :json, headers: { "X-Byte-Secret" => "shh" }

      expect(response).to have_http_status(:ok)
      expect(AmazonReadResultWorker).to have_received(:perform_async).with(payload.deep_stringify_keys)
    end

    it "turns away a request without the secret" do
      post "/webhooks/byte/amazon_orders", params: payload, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe AmazonReadWorker do
    before {
      AmazonOrder.create(order_id: "114-2148205-6820263", item_id: "B01ICAI44S")
      AmazonOrder.create(order_id: "111-5215763-6396260", item_id: "B0BJDWR3BC", delivered: true)
      AmazonOrder.create(order_id: "111-2623925-6598667", item_id: "B0CC6G586V", status: :cancelled)
      AmazonOrder.create(order_id: "UPS", item_id: "1Z16D56V0310080972", carrier: :ups)
      allow(AmazonOrder).to receive(:broadcast)
      allow(DeliveryEvents).to receive(:fire!)
      AmazonOrder.save
      allow(described_class).to receive(:perform_in)
    }

    it "asks for the orders an email named and every order still on the way" do
      allow(ByteLocal).to receive(:amazon_read).and_return(true)

      described_class.new.perform(["111-4653427-0102644"])

      expect(ByteLocal).to have_received(:amazon_read).with(["111-4653427-0102644", "114-2148205-6820263"])
      expect(described_class).not_to have_received(:perform_in)
    end

    it "tries again a little later when the Mini doesn't answer, and then leaves it" do
      allow(ByteLocal).to receive(:amazon_read).and_return(false)

      described_class.new.perform([], 1)
      described_class.new.perform([], 3)

      expect(described_class).to have_received(:perform_in).with(30.seconds, [], 2).once
    end
  end

  describe AmazonFriendlyName do
    it "gives one name per title, and nothing for one the model skipped" do
      allow_any_instance_of(Buddy::GPT::Client).to receive(:stream).and_return(
        { ok: true, text: %({"names": ["Kitty Litter", ""]}) },
      )
      allow(BuddyUsage).to receive(:record!)

      names = described_class.call(["Precious Cat Litter, 40 lb", "INBIKE Gloves", "Third"])

      expect(names).to eq(["Kitty Litter", nil, nil])
    end

    it "gives nothing when the call fails, so the caller falls back" do
      allow_any_instance_of(Buddy::GPT::Client).to receive(:stream).and_raise(Faraday::TimeoutError)

      expect(described_class.call(["Precious Cat Litter, 40 lb"])).to eq([nil])
    end
  end
end
