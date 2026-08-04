require "rails_helper"

# What a reminder DOES when it comes due. Most say something; some are an
# instruction and should carry it out instead of reading it back.
RSpec.describe Buddy::ReminderFirer do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::Jil).to receive(:trigger).and_return(true)
    user.update!(chore_household_id: household.id)
  }

  def remind!(text, **attrs)
    BuddyReminder.create!(
      { user: user, byte_conversation: convo, body: text, fire_at: 1.minute.from_now }.merge(attrs),
    )
  end

  def bodies
    convo.byte_messages.where(direction: :inbound).order(:id).pluck(:body)
  end

  describe "an ordinary reminder" do
    it "says it, with nothing stuck on the front" do
      described_class.fire!(remind!("take the trash out"))

      expect(bodies.last).to eq("Reminder: take the trash out")
    end

    # Someone with a day full of these reads the same character a dozen times
    # before they get to any of the words.
    it "pushes the words themselves, not a glyph and then the words" do
      described_class.fire!(remind!("take the trash out"))

      expect(WebPushNotifications).to have_received(:send_to_byte)
        .with(hash_including(title: "take the trash out"))
    end
  end

  # `kind` is picked once, by the model, and is invisible afterwards - so a
  # reminder meant to DO something arrives as a line of text and there's nowhere
  # to notice. This is decided when it fires instead.
  describe "a reminder that's really an instruction" do
    let!(:routine) {
      BuddyRoutine.create!(
        user:  user,
        name:  "wind down",
        steps: [BuddyRoutine.step(:log_event, { name: "Wind down" })],
      )
    }

    it "runs the routine it names rather than reading it out" do
      expect { described_class.fire!(remind!("run my wind down routine")) }
        .to change { ActionEvent.where(user_id: user.id).count }.by(1)

      expect(bodies).not_to include(a_string_starting_with("Reminder:"))
    end

    it "takes the other run-verbs people actually type" do
      %w[trigger fire start].each { |verb|
        expect { described_class.fire!(remind!("#{verb} wind down")) }
          .to change { ActionEvent.where(user_id: user.id).count }.by(1)
      }
    end

    it "fires a Jil task by name and says which one" do
      Task.create!(
        user: user, name: "Whisper Quiet", listener: "whisper-quiet",
        code: "", enabled: true, buddy_enabled: true
      )

      described_class.fire!(remind!("run Whisper Quiet"))

      expect(::Jil).to have_received(:trigger).with(user, :"whisper-quiet", {}, hash_including(auth: :buddy))
      expect(bodies.last).to include("Whisper Quiet")
    end

    # The narrow part, and the important one: a reminder is normally an
    # instruction to the PERSON, and those are imperative too.
    it "leaves an ordinary nudge alone even though it's phrased as an order" do
      described_class.fire!(remind!("take the trash out"))
      described_class.fire!(remind!("start the laundry"))

      expect(bodies).to all(start_with("Reminder:"))
    end

    # Resolved at fire time, so it degrades to a nudge instead of running
    # whatever is now closest to the name.
    it "goes back to being a nudge once the routine is gone" do
      routine.destroy!

      described_class.fire!(remind!("run my wind down routine"))

      expect(bodies.last).to eq("Reminder: run my wind down routine")
    end
  end

  describe "the recurring kind" do
    it "rolls forward instead of going terminal" do
      reminder = remind!("feed the fish", recurrence: { "kind" => "daily", "at" => "09:00" })

      described_class.fire!(reminder)

      expect(reminder.reload.fired_at).to be_nil
      expect(reminder.last_fired_at).to be_present
    end
  end
end
