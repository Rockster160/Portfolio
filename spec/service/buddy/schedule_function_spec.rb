require "rails_helper"

# "Play Whisper Nap sound at 11": a Jil function call with typed arguments, on
# the clock.
#
# A reminder is the carrier — cancel, list, recurrence, the
# intraday window and the condition check all work on one unchanged — so this is
# a reminder that makes a CALL instead of saying a line.
RSpec.describe "schedule_function" do
  let(:user) { create(:user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let!(:whisper) {
    Task.create!(
      user: user, name: "Whisper Sound", buddy_enabled: true,
      listener: 'function("Sound" TAB String)::String',
      description: "Play a sound cue on Whisper's timer display."
    )
  }
  let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }
  let(:tool) { Buddy::Tools[:schedule_function] }
  let(:at)   { 3.hours.from_now }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def schedule!(payload)
    args = { name: "Whisper Sound", at: at.iso8601 }.merge(payload)
    BuddyReminder.find(tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)[:reminder_id])
  end

  describe "putting it on the clock" do
    # The function NAME, never a resolved id: renamed or switched off, it goes
    # quiet rather than running the nearest thing to it.
    it "stores the call by name, with its arguments, rather than running it", :aggregate_failures do
      expect(Jil::Executor).not_to receive(:call)

      reminder = schedule!(sound: "nap")

      expect(reminder.action).to eq(
        "tool" => "run_jil_task", "payload" => { "name" => "Whisper Sound", "sound" => "nap" },
      )
      expect(reminder.action_call[:payload]).to include(sound: "nap")
      expect(reminder.fire_at).to be_within(2.seconds).of(at)
      expect(BuddyReminder.pending.where(user_id: user.id)).to include(reminder)
    end

    it "takes a recurrence, so a nightly one is a single row" do
      reminder = schedule!({ at: nil, repeat: "daily:21:00" })

      expect(reminder.recurrence).to include("freq" => "daily", "at" => "21:00")
      expect(BuddyReminder.where(user_id: user.id).count).to eq(1)
    end
  end

  describe "what it refuses" do
    def confirm(payload) = tool[:confirm].call({ name: "Whisper Sound", at: at.iso8601 }.merge(payload), ctx)

    # Resolved through call_jil_function's OWN confirm, so a bad name is caught
    # while they're still here — and so is the read-with-a-writer guard, rather
    # than a second copy of it drifting from the one that runs.
    it "refuses an unknown function, a past time, an unreadable repeat, or no time at all", :aggregate_failures do
      expect { confirm(name: "Nonexistent Thing") }.to raise_error(/no Jil task matches/)
      expect { confirm(at: 2.hours.ago.iso8601) }.to raise_error(/already passed/)
      expect { confirm(at: nil, repeat: "everyish") }.to raise_error(/unknown repeat spec/)
      expect { confirm(at: nil) }.to raise_error(/couldn't work out when/)
    end
  end

  describe "when it comes due" do
    let(:reminder) { schedule!(sound: "nap") }

    before { reminder.update!(fire_at: 1.minute.ago) }

    # The same marker replay a routine goes through, under the note whoever set
    # it wrote, and no separate nudge.
    it "makes the call through the marker path, under their note, and marks itself fired", :aggregate_failures do
      captured = nil
      allow(Buddy::ProposalBuilder).to receive(:run_markers!) { |args|
        captured = args
        {}
      }
      reminder.update!(body: "Nap sound for Whisper")

      Buddy::ReminderFirer.fire!(reminder)

      expect(captured).to include(user: user, conversation: convo, body: "Nap sound for Whisper")
      expect(captured[:markers]).to eq([{ tool_name: :run_jil_task, payload: { name: "Whisper Sound", sound: "nap" } }])
      expect(reminder.reload.fired_at).to be_present
      plain = convo.byte_messages.where(direction: :inbound).reject { |m| m.metadata["kind"] == "buddy_activity" }
      expect(plain).to be_empty
    end

    # Everything a reminder already knows how to do keeps working on one of
    # these, which is the whole reason it's the carrier.
    it "answers a condition the same way a text one does" do
      allow(Buddy::ProposalBuilder).to receive(:run_markers!).and_return({})
      reminder.update!(condition: {
        "find" => "action_events", "query" => 'name:"Nope"', "expect" => "found"
      })

      Buddy::ReminderFirer.fire!(reminder)

      expect(Buddy::ProposalBuilder).not_to have_received(:run_markers!)
      expect(reminder.reload.metadata["last_skipped_at"]).to be_present
    end
  end

  # A stored call whose tool has since been removed reads as an ordinary
  # reminder rather than blowing up mid-fire.
  it "degrades to a plain reminder when the stored tool is gone" do
    reminder = schedule!(sound: "nap")
    reminder.update!(action: { "tool" => "tool_that_no_longer_exists", "payload" => {} })

    expect(reminder.action_call).to be_nil
  end
end
