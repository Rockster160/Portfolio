require "rails_helper"

RSpec.describe Buddy::CompanionDelivery do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def fire(seed)
    described_class.deliver_prompt(
      user:         user,
      conversation: convo,
      seed:         seed,
      metadata:     { kind: "buddy_trigger", hidden: true, source: "watch" },
    )
  end

  describe "the frame on a self-initiated seed" do
    # Prod 1315 and 1318 were the same watch firing 45 minutes apart, and their
    # bodies were byte-for-byte identical. The model saw its own announcement of
    # the first one sitting in history and answered the second with "Already
    # handled that one just now" - which went out as the push, so the deploy it
    # fired for was never mentioned. Two firings have to LOOK like two.
    it "makes two firings of the same seed distinguishable" do
      first  = travel_to(Time.zone.parse("2026-07-31 02:08")) { fire("The deploy just finished successfully.") }
      second = travel_to(Time.zone.parse("2026-07-31 02:54")) { fire("The deploy just finished successfully.") }

      expect(first.body).not_to eq(second.body)
      expect(second.body).to include("The deploy just finished successfully.")
    end

    it "stamps the clock in the person's own zone, not UTC" do
      message = travel_to(Time.zone.parse("2026-07-31 02:54 UTC")) { fire("put your Loops away") }

      expect(message.body).to include("8:54 pm")
    end

    it "says the reply is the notification, since nobody is waiting on a conversation" do
      expect(fire("put your Loops away").body).to include("nothing was said to you").and include("notification")
    end

    it "hands the turn off to Sidekiq rather than running it on the firing thread" do
      expect { fire("put your Loops away") }.to change(BuddyDeliverWorker.jobs, :size).by(1)
    end
  end
end
