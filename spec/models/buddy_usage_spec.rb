# == Schema Information
#
# Table name: buddy_usages
#
#  id                   :bigint           not null, primary key
#  user_id              :bigint           not null
#  byte_conversation_id :bigint
#  byte_message_id      :bigint
#  kind                 :integer          default("turn"), not null
#  model                :string           not null
#  input_tokens         :integer          default(0), not null
#  cached_input_tokens  :integer          default(0), not null
#  output_tokens        :integer          default(0), not null
#  reasoning_tokens     :integer          default(0), not null
#  cost_micros          :bigint           default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#
require "rails_helper"

RSpec.describe BuddyUsage do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:message) {
    convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi")
  }

  def result(usage: FakeBuddyClient::DEFAULT_USAGE, model: "gpt-5.4-mini")
    { ok: true, text: "hi", tool_calls: [], model: model, usage: usage }
  end

  describe ".record!" do
    it "stores the token breakdown and the computed cost" do
      row = described_class.record!(result, user: user, conversation: convo, message: message)

      expect(row).to have_attributes(
        kind:                "turn",
        model:               "gpt-5.4-mini",
        input_tokens:        1_000,
        cached_input_tokens: 800,
        output_tokens:       100,
        reasoning_tokens:    20,
      )
      # 200 fresh @ $0.75/M + 800 cached @ $0.075/M + 100 out @ $4.50/M
      expect(row.cost_micros).to eq(
        Buddy::GPT::Pricing.cost_micros(FakeBuddyClient::DEFAULT_USAGE, model: "gpt-5.4-mini"),
      )
    end

    it "records nothing when the call reported no usage" do
      expect {
        described_class.record!(result(usage: nil), user: user, message: message)
      }.not_to change(described_class, :count)
    end

    it "allows a compaction row with no message attached" do
      row = described_class.record!(result, user: user, kind: :compaction, conversation: convo)

      expect(row).to be_compaction
      expect(row.byte_message_id).to be_nil
    end
  end

  describe ".rollup_for_message" do
    it "sums every call made while producing one reply" do
      2.times { described_class.record!(result, user: user, conversation: convo, message: message) }

      rollup = described_class.rollup_for_message(message)

      expect(rollup["calls"]).to eq(2)
      expect(rollup["input_tokens"]).to eq(2_000)
      expect(rollup["output_tokens"]).to eq(200)
      expect(rollup["cost_micros"]).to eq(described_class.where(byte_message: message).sum(:cost_micros))
    end

    it "is nil for a message with no recorded calls" do
      expect(described_class.rollup_for_message(message)).to be_nil
    end
  end

  describe "reporting" do
    it "sums spend over a window, counting turns and compactions together" do
      described_class.record!(result, user: user, conversation: convo, message: message)
      described_class.record!(result, user: user, kind: :compaction, conversation: convo)
      old = described_class.record!(result, user: user, conversation: convo, message: message)
      old.update_column(:created_at, 40.days.ago)

      recent = described_class.where(user: user).since(30.days.ago)

      expect(recent.count).to eq(2)
      expect(recent.spend_micros).to eq(recent.sum(:cost_micros))
      expect(described_class.where(user: user).spend_micros).to be > recent.spend_micros
    end
  end

  describe "#cache_hit_rate" do
    it "reports the share of input served from the prompt cache" do
      row = described_class.record!(result, user: user, message: message)

      expect(row.cache_hit_rate).to eq(0.8)
    end

    it "is zero rather than dividing by zero when nothing was sent" do
      row = described_class.record!(
        result(usage: { input_tokens: 0, cached_input_tokens: 0, output_tokens: 5, reasoning_tokens: 0 }),
        user: user, message: message,
      )

      expect(row.cache_hit_rate).to eq(0.0)
    end
  end
end
