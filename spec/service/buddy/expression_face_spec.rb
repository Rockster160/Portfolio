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

  it "drives server events to faces both themes share" do
    %i[byte moss].each do |theme|
      user = create(:user, buddy_theme: theme.to_s)
      described_class.transition!(user, :proposals_awaiting)
      expect(Buddy::Faces.valid?(theme, user.reload.buddy_expression)).to be(true)
    end
  end

  it "only rests on thinking transitionally (turn_started), never a settled state" do
    user = create(:user, buddy_theme: "byte")

    described_class.transition!(user, :turn_started)
    expect(user.reload.buddy_expression).to eq("thinking")   # transitional — reply in flight

    # Settled outcomes must move off thinking, so the pet never looks stuck mid-thought.
    %i[turn_ended_clean proposals_awaiting proposals_executed proposals_cancelled tool_failed idle_long].each do |event|
      described_class.set(user, "thinking")
      described_class.transition!(user, event)
      expect(user.reload.buddy_expression).not_to eq("thinking"), "#{event} left the pet on thinking"
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
