require "rails_helper"

RSpec.describe Buddy::ExpressionState do
  before { allow(MonitorChannel).to receive(:broadcast_to) }

  # Pet state (theme + expression) now lives on the buddy-mode conversation,
  # not the user — so every case runs against a buddy conversation.
  def buddy_convo(user, theme)
    convo = user.byte_conversations.create!(mode: :buddy)
    convo.update!(buddy_theme: theme)
    convo
  end

  it "accepts only faces the conversation's theme actually has" do
    byte = buddy_convo(User.me, "byte")
    moss = buddy_convo(create(:user), "moss")

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
    convo = buddy_convo(create(:user), "byte")
    convo.update_column(:buddy_expression, "happy")

    # turn_started broadcasts a transient overlay but must NOT write the column
    # (the persistent mood stays put underneath the thinking face).
    described_class.transition!(convo, :turn_started)
    expect(convo.reload.buddy_expression).to eq("happy")
    expect(MonitorChannel).to have_received(:broadcast_to).with(
      convo.user, hash_including(data: hash_including(expression: "thinking", transient: true))
    )
  end

  it "keeps the mood put on settle — no drifting back to a default" do
    convo = buddy_convo(create(:user), "byte")
    convo.update_column(:buddy_expression, "nerd")

    # Every non-turn-start event just settles: re-broadcasts the STORED mood
    # (clearing any thinking overlay) without changing it. This is the fix for
    # "the face changed for a second then reverted".
    %i[turn_ended_clean proposals_awaiting proposals_executed proposals_cancelled tool_failed idle_long].each do |event|
      described_class.transition!(convo, event)
      expect(convo.reload.buddy_expression).to eq("nerd"), "#{event} moved the mood"
    end
  end

  it "refuses a delivered [[mood: thinking]] — thinking is not a selectable face" do
    convo = buddy_convo(User.me, "byte")
    convo.update_column(:buddy_expression, "happy")

    Buddy::SideEffects.apply_mood(convo, "thinking")

    expect(convo.reload.buddy_expression).to eq("happy")   # unchanged — rejected
  end
end
