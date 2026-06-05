require "rails_helper"

RSpec.describe ChoreNotifier do
  let(:user) { create(:user) }
  let(:other) { create(:user) }

  before { share_chore_household!(user, other) }

  describe ".transfer_received!" do
    let(:chore) { create(:chore, created_by_user: user, reward_pebbles: 100) }

    before { create(:chore_completion, user: user, chore: chore, paid_pebbles: 100) }

    it "pushes to the recipient with the transfer summary" do
      transfer = create(:chore_transfer, from_user: user, to_user: other, amount_pebbles: 12, note: "thx")
      expect(WebPushNotifications).to receive(:send_to).with(
        other,
        a_hash_including(title: include("+12p"), body: "thx"),
        channel: :chores,
      )
      described_class.transfer_received!(transfer)
    end

    it "skips when the recipient has opted out" do
      other.update!(chore_notify_prefs: { transfer_received: false })
      transfer = create(:chore_transfer, from_user: user, to_user: other, amount_pebbles: 1)
      expect(WebPushNotifications).not_to receive(:send_to)
      described_class.transfer_received!(transfer)
    end
  end

  describe ".goal_achieved!" do
    let(:goal) { ChoreGoal.create!(user: user, name: "Lego", kind: :pebbles, target_value: 1, achieved_at: Time.current) }

    it "pushes the owner AND every household peer" do
      sent_to = []
      allow(WebPushNotifications).to receive(:send_to) { |u, *| sent_to << u }
      described_class.goal_achieved!(goal)
      expect(sent_to).to contain_exactly(user, other)
    end

    it "respects per-kind opt-out for the owner and for peers independently" do
      user.update!(chore_notify_prefs: { own_goal_achieved: false })
      other.update!(chore_notify_prefs: { other_goal_achieved: false })
      expect(WebPushNotifications).not_to receive(:send_to)
      described_class.goal_achieved!(goal)
    end
  end

  describe ".chore_assigned!" do
    it "pushes the assignee when a different user did the assignment" do
      chore = create(:chore, created_by_user: user, assigned_to_user_id: other.id, sharing_mode: :household)
      expect(WebPushNotifications).to receive(:send_to).with(
        other, a_hash_including(title: include(user.username)), channel: :chores
      )
      described_class.chore_assigned!(chore, actor: user)
    end

    it "does NOT push when the actor assigned themselves" do
      chore = create(:chore, created_by_user: other, assigned_to_user_id: other.id)
      expect(WebPushNotifications).not_to receive(:send_to)
      described_class.chore_assigned!(chore, actor: other)
    end

    it "is a no-op when nobody is assigned" do
      chore = create(:chore, created_by_user: user, assigned_to_user_id: nil)
      expect(WebPushNotifications).not_to receive(:send_to)
      described_class.chore_assigned!(chore, actor: user)
    end
  end
end
