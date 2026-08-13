require "rails_helper"

# "Play Whisper Nap sound at 11."
#
# There was no way to do that. `call_jil_function` runs the instant it's called;
# `schedule_reminder`'s `run <name>` path resolves only routines and plain
# trigger tasks, because there is nowhere in a sentence to put `sound: "nap"`;
# and `schedule_trigger` publishes a bare scope with no typed arguments. So the
# model did the only thing available to it and played the sound sixteen minutes
# early (prod 3562).
#
# A reminder was already the right carrier — cancel, list, recurrence, the
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
    allow(::WebPushNotifications).to receive(:update_count)
  end

  def schedule!(payload)
    args = { name: "Whisper Sound", at: at.iso8601 }.merge(payload)
    BuddyReminder.find(tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)[:reminder_id])
  end

  describe "putting it on the clock" do
    it "stores the call rather than running it" do
      expect(Jil::Executor).not_to receive(:call)

      reminder = schedule!(sound: "nap")

      expect(reminder.action).to eq(
        "tool" => "call_jil_function", "payload" => { "name" => "Whisper Sound", "sound" => "nap" },
      )
    end

    it "keeps the function's own arguments" do
      expect(schedule!(sound: "nap").action_call[:payload]).to include(sound: "nap")
    end

    it "fires at the time they said" do
      expect(schedule!(sound: "nap").fire_at).to be_within(2.seconds).of(at)
    end

    # The tool NAME, never a resolved id — the same degradation rule a routine
    # step follows. Renamed or switched off, it goes quiet rather than running
    # the nearest thing to it.
    it "stores the name, not the task id" do
      expect(schedule!(sound: "nap").action["payload"]["name"]).to eq("Whisper Sound")
    end

    it "takes a recurrence, so a nightly one is a single row" do
      reminder = schedule!({ at: nil, repeat: "daily:21:00" })

      expect(reminder.recurrence).to include("freq" => "daily", "at" => "21:00")
      expect(BuddyReminder.where(user_id: user.id).count).to eq(1)
    end

    it "shows up where they'd look for it, and can be called off" do
      reminder = schedule!(sound: "nap")

      expect(BuddyReminder.pending.where(user_id: user.id)).to include(reminder)
      expect { reminder.update!(cancelled_at: Time.current) }.not_to raise_error
    end

    it "says what will happen before it happens" do
      args = { name: "Whisper Sound", at: at.iso8601, sound: "nap" }

      expect(tool[:confirm].call(args, ctx)[:summary]).to include("Whisper Sound")
    end
  end

  describe "what it refuses" do
    def confirm(payload) = tool[:confirm].call({ name: "Whisper Sound", at: at.iso8601 }.merge(payload), ctx)

    # Resolved through call_jil_function's OWN confirm, so a bad name is caught
    # while they're still here — and so is the read-with-a-writer guard, rather
    # than a second copy of it drifting from the one that runs.
    it "refuses a function that matches nothing" do
      expect { confirm(name: "Nonexistent Thing") }.to raise_error(/no Jil function matches/)
    end

    it "refuses a time that has already gone" do
      expect { confirm(at: 2.hours.ago.iso8601) }.to raise_error(/already passed/)
    end

    it "refuses a repeat spec it can't read" do
      expect { confirm(at: nil, repeat: "everyish") }.to raise_error(/unknown repeat spec/)
    end

    it "refuses to guess when they didn't say" do
      expect { confirm(at: nil) }.to raise_error(/couldn't work out when/)
    end
  end

  describe "when it comes due" do
    let(:reminder) { schedule!(sound: "nap") }

    before { reminder.update!(fire_at: 1.minute.ago) }

    it "makes the call" do
      markers = nil
      allow(Buddy::ProposalBuilder).to receive(:run_markers!) { |args|
        markers = args[:markers]
        {}
      }

      Buddy::ReminderFirer.fire!(reminder)

      expect(markers).to eq([{ tool_name: :call_jil_function, payload: { name: "Whisper Sound", sound: "nap" } }])
    end

    # The same replay a routine goes through, so resolution, level, receipts and
    # the nothing-ran line all behave identically to the call typed by hand.
    it "goes through the marker path rather than a second one of its own" do
      allow(Buddy::ProposalBuilder).to receive(:run_markers!).and_return({})

      Buddy::ReminderFirer.fire!(reminder)

      expect(Buddy::ProposalBuilder).to have_received(:run_markers!)
        .with(hash_including(user: user, conversation: convo))
    end

    # Whoever set it wrote that sentence to be read at this moment.
    it "puts their own note over the receipt" do
      body = nil
      allow(Buddy::ProposalBuilder).to receive(:run_markers!) { |args|
        body = args[:body]
        {}
      }
      reminder.update!(body: "Nap sound for Whisper")

      Buddy::ReminderFirer.fire!(reminder)

      expect(body).to eq("Nap sound for Whisper")
    end

    it "marks itself fired, like any other one-shot" do
      allow(Buddy::ProposalBuilder).to receive(:run_markers!).and_return({})

      Buddy::ReminderFirer.fire!(reminder)

      expect(reminder.reload.fired_at).to be_present
    end

    it "doesn't also read the body out as a nudge" do
      allow(Buddy::ProposalBuilder).to receive(:run_markers!).and_return({})

      Buddy::ReminderFirer.fire!(reminder)

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
