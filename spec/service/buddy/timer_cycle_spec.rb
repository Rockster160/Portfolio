require "rails_helper"

RSpec.describe Buddy::TimerCycle do
  # Prod 4135, 20 Aug: "I need to stay on this until 630pm, but need breaks every
  # 30 mins to relax my brain for 10 mins."
  #
  # What she got was ONE 30-minute timer with an empty `then_continue` queue, and
  # a reply describing a rhythm that didn't exist.
  #
  # `schedule_reminder` could have nagged her every half hour (`every_minutes` +
  # `until_time`), and that is what the reply described. It isn't what she asked
  # for: a nag on a fixed clock says nothing about the break, and it goes off at
  # 3:51 whether she started at 3:21 or 3:35. The rhythm is a chain of blocks
  # joined by a TAP. See Buddy::TimerCycle for why.
  describe "the cycle" do
    let(:user) { User.me }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(WebPushNotifications).to receive(:update_count)
      convo.update_columns(buddy_theme: "byte")
    end

    # Every example here builds real timers, and the suite runs Sidekiq inline —
    # a 30-minute countdown would have TimerFireWorker reschedule itself forever.
    around { |example| Sidekiq::Testing.fake! { example.run } }

    def start!(seconds: 1800, break_seconds: 600, until_at: nil, label: "Kitchen cupboards")
      described_class.start!(
        user:          user,
        conversation:  convo,
        seconds:       seconds,
        label:         label,
        break_seconds: break_seconds,
        until_at:      until_at,
      )
    end

    def said
      convo.byte_messages.where(direction: :inbound).order(:id)
    end

    def timers
      user.timers.order(:id)
    end

    def card
      ByteAction.where(tool_name: described_class::TOOL_NAME).order(:id).last
    end

    describe "a block ending" do
      it "starts the break on its own, because that half is theirs to not count" do
        timer = start!
        expect { described_class.on_fired(timer, convo) }.to change { timers.count }.by(1)

        rest = timers.last
        expect(rest.name).to eq("Break")
        expect(rest.duration_ms).to eq(600_000)
      end

      it "offers exactly one button to start the next one" do
        described_class.on_fired(start!, convo)

        expect(card.buttons.length).to eq(1)
        expect(card.buttons.first["label"]).to eq("Start the next 30 min")
        expect(card.multi_select).to be(false)
      end

      it "says what just ended and what's running now" do
        described_class.on_fired(start!, convo)

        expect(said.last.body).to include("30 min on Kitchen cupboards").and include("Take 10 min")
      end

      # It has to reach her when she's away from the screen; that's the whole
      # point of the break being counted for her.
      it "pushes" do
        described_class.on_fired(start!, convo)

        expect(WebPushNotifications).to have_received(:send_to_byte)
      end

      # THE rule. Nothing about a fired block starts the next one.
      it "does not start the next block" do
        timer = start!
        described_class.on_fired(timer, convo)

        expect(timers.reject { |t| t.name == "Break" }.length).to eq(1)
      end

      it "still offers the button when no break was asked for" do
        timer = start!(break_seconds: nil)

        expect { described_class.on_fired(timer, convo) }.not_to(change { timers.count })
        expect(card.buttons.length).to eq(1)
        expect(said.last.body).not_to include("Take")
      end

      # The fire path asks this before handing over, so an ordinary countdown
      # still gets its plain "time's up" and no button.
      it "leaves an ordinary timer alone" do
        plain = Buddy::Timers.create!(user: user, seconds: 60, label: "Pasta", conversation: convo)

        expect(described_class.cycle?(plain)).to be(false)
        expect { described_class.on_fired(plain, convo) }.not_to(change { convo.byte_messages.count })
      end

      # End to end through the worker's entry point, since that's what decides
      # between a card and a full stop.
      it "reaches the card through the ordinary fire path" do
        Buddy::Timers.on_fired(start!.tap { |t| t.update!(fired_at: Time.current) })

        expect(card).to be_present
      end

      it "still says time's up for a countdown with no cycle on it" do
        plain = Buddy::Timers.create!(user: user, seconds: 60, label: "Pasta", conversation: convo)
        Buddy::Timers.on_fired(plain.tap { |t| t.update!(fired_at: Time.current) })

        expect(said.last.body).to include("your Pasta timer's done")
      end
    end

    describe "the tap" do
      def fire_and_tap!
        described_class.on_fired(start!, convo)
        described_class.resume!(card)
      end

      it "starts the next block" do
        described_class.on_fired(start!, convo)
        action = card

        expect { described_class.resume!(action) }.to change { timers.where(name: "Kitchen cupboards").count }.by(1)
      end

      it "carries the whole rhythm forward so it can go round again" do
        described_class.on_fired(start!, convo)
        nxt = described_class.resume!(card)

        expect(described_class.cycle_for(nxt)).to include(
          "seconds" => 1800, "break_seconds" => 600, "label" => "Kitchen cupboards",
        )
      end

      # Tapping early gives up the rest of the break. Left running, it fires
      # partway into the block she just started and announces a break that ended
      # ten minutes ago — the misalignment the tap exists to avoid.
      it "stops the break she's cutting short" do
        described_class.on_fired(start!, convo)
        rest = timers.find_by(name: "Break")

        described_class.resume!(card)

        expect(rest.reload.archived_at).to be_present
      end

      it "says the next one is going" do
        fire_and_tap!

        expect(said.last.body).to include("started the next 30 min on Kitchen cupboards")
      end

      it "does nothing on an action that isn't a cycle" do
        other = ByteAction.create!(
          user: user, byte_conversation: convo, kind: :custom,
          tool_name: "something_else", buttons: [], tool_input: {}
        )

        expect(described_class.resume!(other)).to be_nil
      end
    end

    # The only way in. `set_timer` is one call for the whole rhythm, not one per
    # block — the model calling it five times would be five unrelated countdowns.
    describe "through set_timer" do
      let(:tool) { Buddy::Tools[:set_timer] }
      let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }

      def run!(payload)
        tool[:execute].call(payload, ctx)
      end

      it "takes a length in minutes, the way people say it" do
        run!({ minutes: 30, label: "Cupboards" })

        expect(timers.last.duration_ms).to eq(1_800_000)
      end

      it "still takes seconds" do
        run!({ seconds: 90 })

        expect(timers.last.duration_ms).to eq(90_000)
      end

      # A timer with no length used to clamp to one second and fire immediately,
      # which reads as a bug in the countdown rather than in the call.
      it "refuses a timer with no length at all" do
        expect { tool[:confirm].call({ label: "Nothing" }, ctx) }.to raise_error(/needs a length/)
      end

      it "builds a real cycle off repeat" do
        run!({ minutes: 30, label: "Cupboards", repeat: true, break_minutes: 10 })

        expect(described_class.cycle_for(timers.last)).to include("seconds" => 1800, "break_seconds" => 600)
      end

      it "leaves a plain countdown plain" do
        run!({ minutes: 30, label: "Cupboards" })

        expect(described_class.cycle?(timers.last)).to be(false)
      end

      it "carries the hour they said to stop" do
        ends = 3.hours.from_now.change(sec: 0)
        run!({ minutes: 30, repeat: true, until_time: ends.iso8601 })

        expect(Time.zone.parse(described_class.cycle_for(timers.last)["until_at"])).to be_within(1.minute).of(ends)
      end

      # The receipt is the only thing standing between "I've set up your rhythm"
      # and one countdown. It has to say the whole shape back.
      it "reads back the whole rhythm rather than one countdown" do
        result = run!({ minutes: 30, label: "Cupboards", repeat: true, break_minutes: 10, until_time: 3.hours.from_now.iso8601 })

        expect(tool[:receipt].call(result, ctx)).to match(/30 min on Cupboards then 10 min off until \d/)
      end

      it "reads back an ordinary one as it always did" do
        result = run!({ minutes: 5, label: "Pasta" })

        expect(tool[:receipt].call(result, ctx)).to include("set a 5 min timer for Pasta")
      end
    end

    describe "the hour they named to stop" do
      it "keeps going while there's still time on the clock" do
        timer = start!(until_at: 2.hours.from_now)
        described_class.on_fired(timer, convo)

        expect(card).to be_present
      end

      it "stops offering another block once it's passed" do
        timer = start!(until_at: 1.minute.ago)
        described_class.on_fired(timer, convo)

        expect(card).to be_nil
        expect(said.last.body).to include("done")
      end

      it "starts no break on the last one either" do
        timer = start!(until_at: 1.minute.ago)

        expect { described_class.on_fired(timer, convo) }.not_to(change { timers.count })
      end

      # The card outlives the deadline if she leaves it sitting, so the tap has to
      # check as well rather than trusting that it was checked once.
      it "refuses a tap that arrives after the deadline" do
        timer = start!(until_at: 2.seconds.from_now)
        described_class.on_fired(timer, convo)
        action = card

        travel_to(1.minute.from_now) do
          expect { described_class.resume!(action) }.not_to(change { timers.where(name: "Kitchen cupboards").count })
        end
      end
    end
  end

  # "Check my printer every 30 minutes until the print finishes."
  #
  # Two things were wrong with the answer to that, and they're the same mistake
  # from opposite ends.
  #
  # It came back as a REMINDER — a nudge on a clock that fires whether or not
  # they went and looked, so fourteen of them stack up while they're away from
  # the printer. A repeat they have to ACT on each round is a cycle: 30 minutes,
  # then a button, and the next 30 starts when they've done it.
  #
  # And the ending was rounded into a clock. "Until the print finishes" is not
  # 11:59pm; it is fifteen minutes or fifteen years, whichever the thing takes.
  describe "a cycle that ends on an event" do
    let(:user) { User.me }
    let(:printer) { { minutes: 30, label: "Printer", repeat: true, stop_when: :deploy } }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }
    let(:tool) { Buddy::Tools[:set_timer] }
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }

    around { |example| Sidekiq::Testing.fake! { example.run } }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(WebPushNotifications).to receive(:update_count)
    end

    def run!(args)
      tool[:execute].call(args, ctx)
    end

    def timer_of(result) = user.timers.find(result[:timer_id])
    def cycle_of(result) = Buddy::TimerCycle.cycle_for(timer_of(result))

    describe "the ending" do
      it "puts no clock on it at all" do
        expect(cycle_of(run!(printer))["until_at"]).to be_nil
      end

      # The trap: an hour and an event both set means the hour arrives first and
      # stops the rhythm early, which is the opposite of what they asked for.
      it "ignores an hour when they named a thing happening" do
        result = run!(printer.merge(until_time: 2.hours.from_now.iso8601))

        expect(cycle_of(result)["until_at"]).to be_nil
      end

      it "arms a watch that ends the whole rhythm" do
        result = run!(printer)
        watch  = BuddyWatch.where(user: user, kind: :cancel).last

        expect(watch.cancels_cycle_id).to eq(cycle_of(result)["cycle_id"])
        expect(watch).to be_one_shot
      end

      it "says the event on the chip, not a time" do
        result = run!(printer)

        chip = tool[:receipt].call(result, ctx)
        expect(chip).to include("until a deploy finishes")
        expect(chip).not_to include("until 11:59")
      end

      it "still takes a real hour when that's what they named" do
        result = run!({ minutes: 30, label: "Cupboards", repeat: true, until_time: 2.hours.from_now.iso8601 })

        expect(cycle_of(result)["until_at"]).to be_present
        expect(tool[:receipt].call(result, ctx)).to include("until")
      end
    end

    # The watch is armed on the FIRST block and the timer it eventually kills is
    # the fifth in the chain, so the handle has to survive every tap.
    describe "when the thing happens" do
      it "stops whichever block is counting, however many rounds later" do
        result = run!(printer)
        watch  = BuddyWatch.where(user: user, kind: :cancel).last

        Buddy::TimerCycle.on_fired(timer_of(result), convo)
        card = ByteAction.where(tool_name: Buddy::TimerCycle::TOOL_NAME).order(:id).last
        later = Buddy::TimerCycle.resume!(card)

        Buddy::WatchMatcher.fire!(watch)

        expect(later.reload.archived_at).to be_present
      end

      it "takes down the card still offering the next one" do
        result = run!(printer)
        watch  = BuddyWatch.where(user: user, kind: :cancel).last
        Buddy::TimerCycle.on_fired(timer_of(result), convo)

        Buddy::WatchMatcher.fire!(watch)

        expect(ByteAction.where(tool_name: Buddy::TimerCycle::TOOL_NAME).pending.count).to eq(0)
      end

      it "says it stopped" do
        result = run!(printer)
        watch  = BuddyWatch.where(user: user, kind: :cancel).last

        expect { Buddy::WatchMatcher.fire!(watch) }.to change { convo.byte_messages.count }.by(1)
        expect(convo.byte_messages.last.body).to include("stopped the check-ins")
      end
    end

    # "As long as the user is able to see and manage these."
    describe "on the reminders list" do
      it "shows the rhythm as one row, not one per block" do
        run!(printer)
        Buddy::TimerCycle.on_fired(user.timers.last, convo)

        rows = Buddy::ReminderPresenter.rows(user).select { |r| r[:type] == :cycle }

        expect(rows.length).to eq(1)
        expect(rows.first[:label]).to eq("Printer")
      end

      it "says the rhythm and how it ends" do
        run!(printer.merge(break_minutes: 10))

        row = Buddy::ReminderPresenter.rows(user).find { |r| r[:type] == :cycle }

        expect(row[:sublabel]).to include("every 30 min").and include("10 min off")
        expect(row[:sublabel]).to include("deploy")
      end

      it "switches the whole thing off when they take the row away" do
        result = run!(printer)

        Buddy::TimerCycle.cancel!(user, cycle_of(result)["cycle_id"])

        expect(timer_of(result).reload.archived_at).to be_present
        expect(Buddy::ReminderPresenter.rows(user).select { |r| r[:type] == :cycle }).to be_empty
      end

      # A cycle is a rule rather than a row, so Undo means starting the next
      # block rather than un-deleting anything.
      it "starts the next block on undo" do
        result   = run!(printer)
        cycle_id = cycle_of(result)["cycle_id"]
        Buddy::TimerCycle.cancel!(user, cycle_id)

        Buddy::TimerCycle.restart!(user, cycle_id, convo)

        expect(Buddy::TimerCycle.live_cycles(user).map { |c| c[:id] }).to eq([cycle_id])
      end

      it "re-arms the ending along with it" do
        result   = run!(printer)
        cycle_id = cycle_of(result)["cycle_id"]
        Buddy::TimerCycle.cancel!(user, cycle_id)

        Buddy::TimerCycle.restart!(user, cycle_id, convo)

        expect(Buddy::TimerCycle.stopper_for(user, cycle_id)).to be_present
      end
    end

    describe "when the ending can't be wired" do
      before { allow(Buddy::WatchCondition).to receive(:resolve).and_raise("no listener for that") }

      # The countdown they asked for is good whether or not its ending could be
      # built. Losing both is how they end up with nothing.
      it "runs the rhythm anyway" do
        result = run!(printer)

        expect(Buddy::TimerCycle.cycle?(timer_of(result))).to be(true)
        expect(BuddyWatch.where(user: user, kind: :cancel).count).to eq(0)
      end

      it "tells the model the ending is missing, in as many words" do
        result = run!(printer)

        expect(result[:stop_failed]).to include("THE TIMER IS RUNNING")
        expect(result[:stop_failed]).to include("request_feature")
      end

      it "says so on the chip" do
        expect(tool[:receipt].call(run!(printer), ctx)).to include("won't stop on its own")
      end
    end

    describe "what the companion is told" do
      it "sends a repeat they must act on here rather than to a reminder" do
        schema = Buddy::Tools.function_schema(tool)

        expect(schema[:description]).to include("A REPEAT THEY HAVE TO ACT ON EACH TIME IS THIS TOOL")
        expect(schema[:description]).to include("until the print finishes")
      end

      it "forbids turning an event ending into a clock" do
        schema = Buddy::Tools.function_schema(tool)

        expect(schema[:description]).to include("Never turn one of those into a clock time")
      end
    end
  end
end
