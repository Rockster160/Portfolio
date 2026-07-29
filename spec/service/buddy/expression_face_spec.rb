require "rails_helper"

RSpec.describe Buddy::ExpressionState do
  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "accepts only faces the user's theme actually has" do
    byte = User.me
    byte.update_column(:buddy_theme, "byte")
    moss = create(:user, buddy_theme: "moss")

    described_class.set(byte, "nerd")            # Byte has nerd
    expect(byte.reload.buddy_expression).to eq("nerd")

    described_class.set(byte, "grin")            # Byte has no grin → refused
    expect(byte.reload.buddy_expression).to eq("nerd")

    described_class.set(moss, "grin")            # Moss has grin
    expect(moss.reload.buddy_expression).to eq("grin")

    described_class.set(moss, "nerd")            # Moss has no nerd → refused
    expect(moss.reload.buddy_expression).to eq("grin")
  end

  it "shows 'thinking' as a transient overlay without persisting it as the mood" do
    user = create(:user, buddy_theme: "byte")
    user.update_column(:buddy_expression, "happy")

    # turn_started broadcasts a transient overlay but must NOT write the column
    # (the persistent mood stays put underneath the thinking face).
    described_class.transition!(user, :turn_started)
    expect(user.reload.buddy_expression).to eq("happy")
    expect(MonitorChannel).to have_received(:broadcast_to).with(
      user, hash_including(data: hash_including(expression: "thinking", transient: true))
    )
  end

  it "keeps the mood put on settle — no drifting back to a default" do
    user = create(:user, buddy_theme: "byte")
    user.update_column(:buddy_expression, "nerd")

    # Every non-turn-start event just settles: re-broadcasts the STORED mood
    # (clearing any thinking overlay) without changing it. This is the fix for
    # "the face changed for a second then reverted".
    %i[turn_ended_clean proposals_awaiting proposals_executed proposals_cancelled tool_failed idle_long].each do |event|
      described_class.transition!(user, event)
      expect(user.reload.buddy_expression).to eq("nerd"), "#{event} moved the mood"
    end
  end

  it "refuses a delivered [[mood: thinking]] — thinking is not a selectable face" do
    user = User.me
    user.update_column(:buddy_theme, "byte")
    user.update_column(:buddy_expression, "happy")

    Buddy::SideEffects.apply_mood(user, "thinking")

    expect(user.reload.buddy_expression).to eq("happy")   # unchanged — rejected
  end
end
