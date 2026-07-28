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
end
