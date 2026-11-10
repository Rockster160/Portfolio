require "rails_helper"

RSpec.describe Buddy::TimerCycle do
  # A work/break rhythm is a chain of blocks joined by a TAP: a block ending
  # starts the break on its own, and the next block starts only when tapped.
  describe "the cycle" do
    let(:user) { User.me }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
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

    # The later blocks and breaks start from the chat, so the board has to
    # travel in the cycle or they'd fall off the board after the first block.
    describe "on a board" do
      let(:board) { user.byte_conversations.create!(mode: :buddy, name: "Kitchen", metadata: { "board" => true }) }

      it "keeps the break and the next block on the board" do
        timer = described_class.start!(
          user: user, conversation: board, seconds: 1800, label: "Cupboards", break_seconds: 600,
        )
        described_class.on_fired(timer, convo)

        expect(Buddy::Timers.board_id(timers.last)).to eq(board.id)
        expect(card.tool_input[described_class::KEY]["place"]).to eq(Buddy::Timers::BOARD => board.id)

        card.apply_decision!(value: "start", source: :user)
        resumed = described_class.resume!(card)
        expect(Buddy::Timers.board_id(resumed)).to eq(board.id)
      end
    end

    describe "a block ending" do
      it "starts the break, offers one button for the next block, and pushes", :aggregate_failures do
        timer = start!
        expect { described_class.on_fired(timer, convo) }.to change { timers.count }.by(1)

        rest = timers.last
        expect(rest.name).to eq("Break")
        expect(rest.duration_ms).to eq(600_000)
        expect(timers.reject { |t| t.name == "Break" }.length).to eq(1)
        expect(card.buttons.length).to eq(1)
        expect(card.multi_select).to be(false)
        expect(WebPushNotifications).to have_received(:send_to_byte)
      end

      # The break must not be anchored to the message that asked for the rhythm.
      it "starts the break NOW, not back when the rhythm was asked for" do
        convo.byte_messages.create!(
          user: user, direction: :outbound, state: :sent,
          body: "Let's do 15/15", created_at: 15.minutes.ago,
        )
        timer = start!(seconds: 900, break_seconds: 900)

        described_class.on_fired(timer, convo)

        rest = timers.where(name: "Break").last
        expect(rest.started_at).to be_within(5.seconds).of(Time.current)
        expect(rest.end_at).to be > Time.current
        expect(rest.remaining_ms).to be_within(5_000).of(900_000)
      end

      it "still offers the button when no break was asked for" do
        timer = start!(break_seconds: nil)

        expect { described_class.on_fired(timer, convo) }.not_to(change { timers.count })
        expect(card.buttons.length).to eq(1)
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

      # TimerFireWorker has its own guards (drift, an already-set fired_at) in
      # front of the hand-off.
      it "posts the card when the fire arrives through the worker" do
        timer = start!(break_seconds: nil)
        travel_to(timer.end_at + 1.second)

        TimerFireWorker.new.perform(timer.id)

        expect(card).to be_present
      end

      it "still says time's up for a countdown with no cycle on it" do
        plain = Buddy::Timers.create!(user: user, seconds: 60, label: "Pasta", conversation: convo)
        Buddy::Timers.on_fired(plain.tap { |t| t.update!(fired_at: Time.current) })

        expect(said.last.body).to include("Pasta")
        expect(card).to be_nil
      end
    end

    describe "cutting a block short" do
      def skip_card
        ByteAction.where(tool_name: described_class::TOOL_NAME).pending.order(:id).last
      end

      it "offers a way out from the first second of a block" do
        timer = start!(seconds: 900, break_seconds: 600)

        described_class.offer_skip!(timer, convo)

        expect(skip_card.buttons.first["value"]).to eq(described_class::SKIP)
      end

      it "ends the block and does what its ending would have done" do
        timer = start!(seconds: 900, break_seconds: 600)
        described_class.offer_skip!(timer, convo)
        card = skip_card

        expect { described_class.skip!(card) }.to change { timers.where(name: "Break").count }.by(1)
        expect(timer.reload.archived_at).to be_present
      end

      # Two live cards is two ways to start a block, and the second tap would
      # start one on top of the other.
      it "leaves only the newest card tappable" do
        timer = start!(seconds: 900, break_seconds: nil)
        described_class.offer_skip!(timer, convo)
        first = skip_card

        described_class.on_fired(timer, convo)

        expect(first.reload).not_to be_pending
        expect(ByteAction.where(tool_name: described_class::TOOL_NAME).pending.count).to eq(1)
      end

      it "sends a skip tap to skip and a resume tap to resume" do
        timer = start!(seconds: 900, break_seconds: nil)
        described_class.offer_skip!(timer, convo)
        card = skip_card
        card.apply_decision!(value: described_class::SKIP, source: :user)

        expect { described_class.tapped!(card) }.to change { timer.reload.archived_at }.from(nil)
      end

      # Mid-break there is no block counting; the resume card is the live one.
      it "does nothing when no block is running" do
        timer = start!(seconds: 900, break_seconds: 600)
        described_class.offer_skip!(timer, convo)
        card = skip_card
        Buddy::Timers.stop!(timer)

        expect(described_class.skip!(card)).to be_nil
      end
    end

    describe "the tap" do
      # Tapping early gives up the rest of the break, or it would fire partway
      # into the new block.
      it "starts the next block with the whole rhythm and stops the break", :aggregate_failures do
        described_class.on_fired(start!, convo)
        rest = timers.find_by(name: "Break")
        action = card

        nxt = nil
        expect { nxt = described_class.resume!(action) }.to change { timers.where(name: "Kitchen cupboards").count }.by(1)
        expect(described_class.cycle_for(nxt)).to include(
          "seconds" => 1800, "break_seconds" => 600, "label" => "Kitchen cupboards",
        )
        expect(rest.reload.archived_at).to be_present
      end

      # Same trap on the other side of the tap: a block that starts when they
      # come back must start THEN, not whenever the last thing was typed.
      it "starts the next block from the tap, not from the last thing they said" do
        convo.byte_messages.create!(
          user: user, direction: :outbound, state: :sent,
          body: "Let's do 15/15", created_at: 20.minutes.ago,
        )
        described_class.on_fired(start!(seconds: 900, break_seconds: nil), convo)

        nxt = described_class.resume!(card)

        expect(nxt.started_at).to be_within(5.seconds).of(Time.current)
        expect(nxt.remaining_ms).to be_within(5_000).of(900_000)
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

      it "takes a length in minutes or seconds", :aggregate_failures do
        run!({ minutes: 30, label: "Cupboards" })
        expect(timers.last.duration_ms).to eq(1_800_000)
        expect(described_class.cycle?(timers.last)).to be(false)

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

      it "carries the hour they said to stop" do
        ends = 3.hours.from_now.change(sec: 0)
        run!({ minutes: 30, repeat: true, until_time: ends.iso8601 })

        expect(Time.zone.parse(described_class.cycle_for(timers.last)["until_at"])).to be_within(1.minute).of(ends)
      end
    end

    describe "the hour they named to stop" do
      it "keeps going while there's still time on the clock" do
        timer = start!(until_at: 2.hours.from_now)
        described_class.on_fired(timer, convo)

        expect(card).to be_present
      end

      it "offers no block and starts no break once it's passed", :aggregate_failures do
        timer = start!(until_at: 1.minute.ago)

        expect { described_class.on_fired(timer, convo) }.not_to(change { timers.count })
        expect(card).to be_nil
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

  # A cycle that ends when something happens ("until the print finishes")
  # carries a cancel watch, never a clock time.
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
    end

    def run!(args)
      tool[:execute].call(args, ctx)
    end

    def timer_of(result) = user.timers.find(result[:timer_id])
    def cycle_of(result) = Buddy::TimerCycle.cycle_for(timer_of(result))

    describe "the ending" do
      # An hour and an event both set would stop the rhythm early.
      it "puts no clock on it, even if an hour was also given, and arms a one-shot watch", :aggregate_failures do
        result = run!(printer.merge(until_time: 2.hours.from_now.iso8601))
        watch  = BuddyWatch.where(user: user, kind: :cancel).last

        expect(cycle_of(result)["until_at"]).to be_nil
        expect(watch.cancels_cycle_id).to eq(cycle_of(result)["cycle_id"])
        expect(watch).to be_one_shot
      end

      it "still takes a real hour when that's what they named" do
        result = run!({ minutes: 30, label: "Cupboards", repeat: true, until_time: 2.hours.from_now.iso8601 })

        expect(cycle_of(result)["until_at"]).to be_present
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

      it "takes down the card still offering the next one and posts that it stopped", :aggregate_failures do
        result = run!(printer)
        watch  = BuddyWatch.where(user: user, kind: :cancel).last
        Buddy::TimerCycle.on_fired(timer_of(result), convo)

        expect { Buddy::WatchMatcher.fire!(watch) }.to change { convo.byte_messages.count }.by(1)
        expect(ByteAction.where(tool_name: Buddy::TimerCycle::TOOL_NAME).pending.count).to eq(0)
      end
    end

    describe "on the reminders list" do
      it "shows the rhythm as one row, not one per block" do
        run!(printer)
        Buddy::TimerCycle.on_fired(user.timers.last, convo)

        rows = Buddy::ReminderPresenter.rows(user).select { |r| r[:type] == :cycle }

        expect(rows.length).to eq(1)
        expect(rows.first[:label]).to eq("Printer")
      end

      it "switches the whole thing off when they take the row away" do
        result = run!(printer)

        Buddy::TimerCycle.cancel!(user, cycle_of(result)["cycle_id"])

        expect(timer_of(result).reload.archived_at).to be_present
        expect(Buddy::ReminderPresenter.rows(user).select { |r| r[:type] == :cycle }).to be_empty
      end

      # A cycle is a rule rather than a row, so Undo means starting the next
      # block rather than un-deleting anything.
      it "starts the next block on undo and re-arms the ending", :aggregate_failures do
        result   = run!(printer)
        cycle_id = cycle_of(result)["cycle_id"]
        Buddy::TimerCycle.cancel!(user, cycle_id)

        Buddy::TimerCycle.restart!(user, cycle_id, convo)

        expect(Buddy::TimerCycle.live_cycles(user).map { |c| c[:id] }).to eq([cycle_id])
        expect(Buddy::TimerCycle.stopper_for(user, cycle_id)).to be_present
      end
    end

    describe "when the ending can't be wired" do
      before { allow(Buddy::WatchCondition).to receive(:resolve).and_raise("no listener for that") }

      # The countdown they asked for is good whether or not its ending could be
      # built, and the model is told the ending is missing.
      it "runs the rhythm anyway and flags the missing stop", :aggregate_failures do
        result = run!(printer)

        expect(Buddy::TimerCycle.cycle?(timer_of(result))).to be(true)
        expect(BuddyWatch.where(user: user, kind: :cancel).count).to eq(0)
        expect(result[:stop_failed]).to be_present
      end
    end
  end
end
