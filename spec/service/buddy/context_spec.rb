require "rails_helper"

RSpec.describe Buddy::Context do
  let(:user) { User.me }

  describe ".build" do
    it "returns a hash with the expected top-level keys" do
      ctx = described_class.build(user)

      expect(ctx.keys).to include(
        :now_local, :timezone, :user_first_name,
        :emotional_state,
        :today_agenda,
        :chores_pending_today, :chores_done_today, :chores_hot_picks, :chores_overdue_backlog,
        :recent_events, :active_proposals, :upcoming_reminders,
      )
    end

    it "populates chores_pending_today when the user has uncompleted dailies today" do
      pending = ChoreDaily.for_user(user).pluck(:chore_id)
      done_today = ChoreCompletion.where(user_id: user.id, day_key: user.perceived_today).pluck(:chore_id).to_set
      expected_pending_ids = pending.reject { |id| done_today.include?(id) }

      skip "no dailies configured for #{user.username}" if pending.empty?
      skip "all dailies completed today" if expected_pending_ids.empty?

      ctx = described_class.build(user)

      # Should at least surface some pending dailies (may include additional
      # scheduled-today / hot picks, so we just check overlap, not equality).
      returned_ids = ctx[:chores_pending_today].map { |c| c[:id] }
      expect(returned_ids).not_to be_empty
      expect(returned_ids).to include(*expected_pending_ids.first(3))
    end
  end
end
