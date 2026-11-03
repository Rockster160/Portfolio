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

  describe User do
    # Clamped rather than validated: it's written from a stepper and from a
    # tool, and neither is a place to raise.
    it "clamps rather than rejecting" do
      user.update!(byte_font_scale: 500)
      expect(user.reload.byte_font_scale).to eq(User::FONT_SCALE_RANGE.max)

      user.update!(byte_font_scale: 10)
      expect(user.reload.byte_font_scale).to eq(User::FONT_SCALE_RANGE.min)
    end

    it "defaults to the design size and survives another preference beside it" do
      expect(user.byte_font_scale).to eq(100)

      user.update!(byte_font_scale: 120)
      user.update!(byte_prefs: user.byte_prefs.merge("something_else" => true))

      expect(user.reload.byte_font_scale).to eq(120)
    end
  end

  describe "set_font_size" do
    it "steps, resets, or takes an outright percentage", :aggregate_failures do
      [
        [100, { direction: :bigger }, 100 + User::FONT_SCALE_STEP],
        [120, { direction: :smaller }, 120 - User::FONT_SCALE_STEP],
        [170, { direction: :reset }, 100],
        [100, { percent: 150 }, 150],
      ].each do |from, payload, expected|
        user.update!(byte_font_scale: from)
        run(payload)
        expect(user.reload.byte_font_scale).to eq(expected), payload.inspect
      end
    end

    it "stays put at the end of the range" do
      user.update!(byte_font_scale: User::FONT_SCALE_RANGE.max)

      run(direction: :bigger)

      expect(user.reload.byte_font_scale).to eq(User::FONT_SCALE_RANGE.max)
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
