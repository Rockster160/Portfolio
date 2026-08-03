require "rails_helper"

# How big the thread's text renders, per person.
#
# Stored on the user rather than in localStorage because the ask was explicitly
# that Buddy can change it too ("make the text bigger"), and a preference that
# only exists in one browser is not reachable from a tool.
RSpec.describe "Byte text size" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def run(payload)
    markers = [{ tool_name: :set_font_size, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last

  describe User do
    it "defaults to the design size" do
      expect(user.byte_font_scale).to eq(100)
    end

    it "round-trips a set value" do
      user.update!(byte_font_scale: 130)

      expect(user.reload.byte_font_scale).to eq(130)
    end

    # Clamped rather than validated: it's written from a stepper and from a
    # tool, and neither is a place to raise.
    it "clamps rather than rejecting" do
      user.update!(byte_font_scale: 500)
      expect(user.reload.byte_font_scale).to eq(User::FONT_SCALE_RANGE.max)

      user.update!(byte_font_scale: 10)
      expect(user.reload.byte_font_scale).to eq(User::FONT_SCALE_RANGE.min)
    end

    it "leaves room for the next preference beside it" do
      user.update!(byte_font_scale: 120)
      user.update!(byte_prefs: user.byte_prefs.merge("something_else" => true))

      expect(user.reload.byte_font_scale).to eq(120)
    end
  end

  describe "set_font_size" do
    it "steps up from wherever they are" do
      run(direction: :bigger)

      expect(user.reload.byte_font_scale).to eq(100 + User::FONT_SCALE_STEP)
    end

    it "steps down" do
      user.update!(byte_font_scale: 120)

      run(direction: :smaller)

      expect(user.reload.byte_font_scale).to eq(120 - User::FONT_SCALE_STEP)
    end

    it "goes back to the default on reset" do
      user.update!(byte_font_scale: 170)

      run(direction: :reset)

      expect(user.reload.byte_font_scale).to eq(100)
    end

    it "takes an outright percentage when they name one" do
      run(percent: 150)

      expect(user.reload.byte_font_scale).to eq(150)
    end

    it "says where it landed" do
      run(direction: :bigger)

      expect(chip.body).to include("110%")
    end

    # "Done" on a change that didn't happen is a reading they'd only catch by
    # squinting at text that looks the same.
    it "says so when it's already at the end of the range" do
      user.update!(byte_font_scale: User::FONT_SCALE_RANGE.max)

      run(direction: :bigger)

      expect(chip.body).to match(/already as big as it goes/i)
    end

    # The page is already open; a preference change they have to reload to see
    # is not the thing they asked for.
    it "pushes the change to the open app" do
      run(direction: :bigger)

      expect(MonitorChannel).to have_received(:broadcast_to).with(
        user, hash_including(data: hash_including(kind: :font_scale, scale: 110))
      )
    end
  end
end
