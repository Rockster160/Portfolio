require "rails_helper"

# On-demand historical daily-chore progress (a TOOL, not preloaded context).
RSpec.describe "Buddy chore history" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

  before do
    user.update!(chore_household_id: household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    allow(::Jil).to receive(:trigger)
  end

  def daily(name)
    chore = household.chores.create!(created_by_user: user, name: name)
    ChoreDaily.create!(user: user, chore: chore, sort_order: 0)
    chore
  end

  def complete(chore, day)
    ChoreCompletion.create!(user: user, chore: chore, completed_at: day.to_time.change(hour: 9), day_key: day)
  end

  describe Buddy::ChoreHistory do
    it "reports per-day done/total/missed against the daily list" do
      water = daily("Water")
      teeth = daily("Teeth")
      today = user.perceived_today

      complete(water, today)
      complete(teeth, today)      # today: both done
      complete(water, today - 1)  # yesterday: only Water

      rows = described_class.progress(user, days: 2)
      yesterday = rows.find { |r| r[:date] == today - 1 }
      now       = rows.find { |r| r[:date] == today }

      expect(yesterday).to include(done: 1, total: 2, missed: ["Teeth"])
      expect(now).to include(done: 2, total: 2, missed: [])
    end

    it "returns empty when there are no daily chores" do
      expect(described_class.progress(user, days: 7)).to eq([])
    end
  end

  describe "chore_progress tool" do
    it "hands the per-day summary back in the same turn, with no chip" do
      water = daily("Water")
      complete(water, user.perceived_today)
      convo = user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)

      result = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:chore_progress],
        { call_id: "call_1", name: :chore_progress, arguments: { days: 3 } },
        user: user, conversation: convo,
      )

      expect(result[:status]).to eq(:answered)
      expect(result[:progress].join("\n")).to include("all 1 done")
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
      expect(convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").count).to eq(0)
    end
  end
end
