require "rails_helper"

RSpec.describe ByteDailyAudit do
  describe "the audit" do
    let(:user) { User.me }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(ByteLocal).to receive(:reset_claude_session).and_return(true)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    # The console entry point. Someone typing this is watching for a result, so
    # the cron-shaped "skip if already run today" is wrong here.
    describe ".kick!" do
      it "runs even when this morning's scheduled one already went" do
        described_class.run!(user)

        expect(described_class.kick!(user)).to eq(:sent)
      end

      it "defaults to User.me so the console call needs no argument" do
        expect { described_class.kick! }.to change { described_class.conversation(user).byte_messages.count }.by(1)
      end

      it "can be pointed at an older window" do
        described_class.kick!(user, now: Time.zone.parse("2026-08-05 22:00:00"))
        posted = described_class.conversation(user).byte_messages.order(:created_at).last

        expect(posted.body).to include("Tuesday August 4, 2026")
        expect(posted.body).to include("Wednesday August 5, 2026")
      end
    end

    describe ".window" do
      let(:tz) { ActiveSupport::TimeZone["America/Denver"] }

      it "covers the 24 hours ending right now" do
        span = described_class.window(user, now: tz.parse("2026-08-12 14:32:00"))

        expect(span.first).to eq(tz.parse("2026-08-11 14:32:00"))
        expect(span.last).to eq(tz.parse("2026-08-12 14:32:00"))
      end

      # The reason it isn't pinned to a fixed hour: a run kicked by hand has to
      # pick up what was said a minute ago, or there's no point being able to kick
      # one.
      it "moves with the clock rather than snapping to a scheduled hour" do
        early = described_class.window(user, now: tz.parse("2026-08-12 06:00:00"))
        later = described_class.window(user, now: tz.parse("2026-08-12 09:14:00"))

        expect(later.last).to eq(tz.parse("2026-08-12 09:14:00"))
        expect(later).not_to eq(early)
      end

      it "reaches all the way to now, leaving no tail unreviewed" do
        now = tz.parse("2026-08-12 14:32:00")

        expect(described_class.window(user, now: now)).to cover(now - 1.minute)
      end
    end

    # A run that fails costs more than its own report. The next window opens 24
    # hours before ITSELF rather than where the last finished report stopped, so
    # the hours in between belong to no run at all and nothing later reaches back
    # for them. On 20 Aug that was 8:30 AM to 1:32 PM the day before.
    describe "a gap left by a run that never happened" do
      let(:tz)    { ActiveSupport::TimeZone["America/Denver"] }
      let(:since) { tz.parse("2026-08-19 08:30:51") }
      let(:upto)  { tz.parse("2026-08-19 13:32:20") }

      it "starts where it's told rather than 24 hours back" do
        span = described_class.window(user, now: upto, since: since)

        expect(span.first).to eq(since)
        expect(span.last).to eq(upto)
      end

      it "leaves the default alone when nothing is passed" do
        expect(described_class.window(user, now: upto).first).to eq(upto - 24.hours)
      end

      # A five-hour window described as "the 24 hours" is an instruction to go
      # and find nineteen hours that aren't in it, and a closed window read as
      # reaching the present puts today's traffic in scope.
      it "tells the run how long its window is, both edges, and that it has closed" do
        described_class.kick!(user, now: upto, since: since)
        body = described_class.conversation(user).byte_messages.order(:id).last.body

        expect(body).to include("Review the 5 hours from")
        expect(body).to include("Wednesday August 19, 2026 at 8:30 AM", "Wednesday August 19, 2026 at 1:32 PM")
        expect(body).not_to include("right up to now")
      end

      it "still says 24 hours up to now for an ordinary run" do
        expect(described_class.prompt(user, now: upto)).to include("Review the 24 hours from", "right up to now")
      end
    end

    # The app's own failures, in the same report and in a section of their own:
    # a companion getting something wrong and the app raising are only
    # sometimes the same story.
    describe "the errors it carries" do
      let(:now) { Time.zone.parse("2026-08-12 14:32:00") }

      it "renders the window's failures into the prompt" do
        travel_to(now - 3.hours) {
          2.times { ErrorReport.record!(section: "google_calendar.sync", exception: StandardError.new("timed out")) }
        }

        body = described_class.prompt(user, now: now)

        expect(body).to include("**2x** BE/rescue `google_calendar.sync`")
        expect(body).to include("StandardError: timed out")
      end

      # Written in their own clock, which is the one the window's edges are
      # already stated in.
      it "names the stretch a repeat ran over, in their timezone" do
        travel_to(now - 5.hours) { ErrorReport.record!(section: "sync", exception: StandardError.new("a")) }
        travel_to(now - 1.hour)  { ErrorReport.record!(section: "sync", exception: StandardError.new("a")) }

        expect(described_class.prompt(user, now: now)).to include("3:32 AM to 7:32 AM")
      end

      # Worth knowing about precisely because nobody has seen it.
      it "marks a failure that was never announced" do
        travel_to(now - 1.hour) { ErrorReport.record!(section: "sync", exception: StandardError.new("a")) }

        expect(described_class.prompt(user, now: now)).to include("· never announced")
      end

      # A repeat held back while the same failure was still going is not a
      # failure nobody was told about - the first one was announced.
      it "doesn't call a held-back repeat unannounced" do
        travel_to(now - 2.hours) {
          ErrorReport.record!(section: "sync", exception: StandardError.new("a"))
            .update!(channel: "#zygy-alerts")
        }
        travel_to(now - 1.hour) { ErrorReport.record!(section: "sync", exception: StandardError.new("a")) }

        expect(described_class.prompt(user, now: now)).not_to include("· never announced")
      end

      it "leaves out failures from outside the window" do
        travel_to(now - 3.days) { ErrorReport.record!(section: "ancient", exception: StandardError.new("a")) }

        expect(described_class.prompt(user, now: now)).not_to include("ancient")
      end
    end

    # "Note: ..." typed in a Buddy thread is somebody pointing straight at a
    # problem, so the audit is handed each one rather than left to spot it.
    describe "the notes it carries" do
      let(:now)   { Time.zone.parse("2026-08-12 14:32:00") }
      let(:buddy) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }

      def say(body, direction:, at:, metadata: {})
        buddy.byte_messages.create!(
          user:       user,
          direction:  direction,
          state:      :delivered,
          body:       body,
          metadata:   metadata,
          created_at: at,
        )
      end

      it "names each note and the companion message it was written under" do
        reply = say("Set for 5 minutes", direction: :inbound, at: now - 2.hours, metadata: { kind: :buddy })
        say("Set ✓", direction: :inbound, at: now - 2.hours + 1.second, metadata: { kind: :buddy_activity })
        note = say("Note: I said 15", direction: :outbound, at: now - 1.hour, metadata: { kind: :audit_note })

        body = described_class.prompt(user, now: now)

        expect(body).to include("message #{note.id}", "\"Note: I said 15\"", "under message #{reply.id}")
        expect(body).not_to include("None were left in this window.")
      end

      it "leaves out an ordinary message and a note from outside the window" do
        say("Note: ancient", direction: :outbound, at: now - 3.days, metadata: { kind: :audit_note })
        say("just chatting", direction: :outbound, at: now - 1.hour)

        expect(described_class.prompt(user, now: now)).to include("None were left in this window.")
      end
    end

    describe ".span_length" do
      let(:tz) { ActiveSupport::TimeZone["America/Denver"] }

      def length(minutes)
        start = tz.parse("2026-08-19 08:00:00")
        described_class.span_length(start..(start + minutes.minutes))
      end

      # An hour and a bit rounded to "1 hours" reads as a bug in the prompt.
      it "reads a day as hours, rounds a ragged window, and stays in minutes under an hour" do
        expect(length(24 * 60)).to eq("24 hours")
        expect(length(302)).to eq("5 hours")
        expect(length(35)).to eq("35 minutes")
      end
    end

    describe ".conversation" do
      it "runs in claude mode against the repo, not as a Buddy thread" do
        convo = described_class.conversation(user)

        expect(convo.mode).to eq("claude")
        expect(convo.metadata["cwd"]).to eq(described_class::CWD)
      end

      # It has to run with the laptop shut.
      it "runs on the Mini, and goes back there if it was moved" do
        convo = described_class.conversation(user)
        expect(convo).to be_on_mini

        convo.update!(machine: :laptop)
        expect(described_class.conversation(user)).to be_on_mini
      end

      # The whole read-only guarantee rests on this one value, and it's togglable
      # from the pwd bar - an audit left in "auto" overnight can rewrite the app.
      # "ask" is not the safe answer either: it consults `permissions.allow` and
      # nothing else, so it is as wide as whatever has ever been tapped "always
      # allow" - and it stops dead on anything that hasn't, at 2am, for ten
      # minutes, with nobody there to tap it.
      it "sits in read mode, which nothing can widen and which never asks" do
        expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
      end

      it "reasserts read and claude mode if the thread was flipped by hand, keeping the rest" do
        convo = described_class.conversation(user)
        convo.update!(mode: :buddy, metadata: convo.metadata.merge("permission_mode" => "auto", "note" => "keep me"))

        again = described_class.conversation(user)
        expect(again.id).to eq(convo.id)
        expect(again.mode).to eq("claude")
        expect(again.metadata).to include("permission_mode" => "read", "note" => "keep me")
      end

      # Found by NAME, so the report is somewhere you can scroll back through
      # rather than wherever the day happened to end.
      it "adopts an existing thread of that name instead of making a second" do
        existing = user.byte_conversations.create!(name: described_class::NAME, mode: :claude)

        expect(described_class.conversation(user).id).to eq(existing.id)
      end
    end

    describe ".prompt" do
      subject(:prompt) { described_class.prompt(user, now: tz.parse("2026-08-12 06:00:00")) }

      let(:tz) { ActiveSupport::TimeZone["America/Denver"] }

      # A bare date can't say where a window that ends at 6am, or at 2:14pm,
      # actually stops.
      it "names both edges of the window with the hour, not just the date" do
        expect(prompt).to include("Tuesday August 11, 2026 at 6:00 AM")
        expect(prompt).to include("Wednesday August 12, 2026 at 6:00 AM")
      end

      # A fresh session each day means a dismissed finding comes back every day
      # until the prompt itself says otherwise.
      it "carries the findings that have already been answered" do
        expect(prompt).to include("NOT FINDINGS", "syncevents")
      end

      # `bin/daily-audit` finds tonight's session by looking for the transcript
      # that OPENS with this sentence, because there is a window every night when
      # nothing else can tell it: run! clears the stored session id before
      # posting, and the Mac only writes the new one once the turn finishes —
      # several minutes later for a report that reads a day of traffic. Ask
      # during that window and you get "no Claude session yet" about an audit
      # that is running right then.
      #
      # So the opening sentence is a contract between a prompt and a shell
      # script, with nothing but this test connecting them. Reword the first line
      # and the fallback silently stops matching, which looks exactly like the
      # bug it exists to fix.
      describe "the sentence bin/daily-audit matches on" do
        let(:marker) { "You are the daily audit for this app." }

        it "opens the prompt" do
          expect(prompt).to start_with(marker)
        end

        it "is what the script actually searches for" do
          expect(Rails.root.join("bin/daily-audit").read).to include(marker)
        end
      end
    end

    describe ".run!" do
      # The prompt is long and is not something to scroll past every morning.
      it "posts the prompt hidden into the thread on a fresh Claude session" do
        expect { described_class.run!(user) }.to change { described_class.conversation(user).byte_messages.count }.by(1)
        posted = described_class.conversation(user).byte_messages.order(:created_at).last

        expect(ByteLocal).to have_received(:reset_claude_session)
        expect(posted.metadata).to include("hidden" => true, "daily_audit" => true)
      end

      # sidekiq-cron can fire the same minute twice across a restart, and the
      # retry loop re-enters run! on every attempt.
      it "does not run twice in one day" do
        described_class.run!(user)

        expect(described_class.run!(user)).to eq(:already_ran)
      end

      it "runs anyway when forced" do
        described_class.run!(user)

        expect(described_class.run!(user, force: true)).to eq(:sent)
      end

      it "runs again the next day" do
        described_class.run!(user)
        convo = described_class.conversation(user)
        convo.byte_messages.update_all(created_at: 2.days.ago)

        expect(described_class.run!(user)).to eq(:sent)
      end

      # 20 Aug: the 8:30 handoff failed (message 4046), the 10am backstop found
      # that row and stood down, and the day had no report at all. The backstop is
      # there for the morning the audit didn't happen, and a prompt that never
      # reached the Mac is that morning.
      describe "when the morning's prompt never got out" do
        it "lets the backstop have another go" do
          described_class.run!(user)
          described_class.conversation(user).byte_messages.last.update!(state: :failed)

          expect(described_class.run!(user)).to eq(:sent)
        end

        it "still stands down once one of them lands" do
          described_class.run!(user)
          described_class.conversation(user).byte_messages.last.update!(state: :failed)
          described_class.run!(user)

          expect(described_class.run!(user)).to eq(:already_ran)
        end
      end
    end
  end

  # When the daily audit goes.
  #
  # It used to be a flat 6am, which put the report an hour or two ahead of the
  # briefing it reads best under. It now hangs off the briefing turn FINISHING -
  # the reply is written, it's on screen, and nothing else is going to happen to
  # it - so there is no clock to keep in step and nothing polling for it.
  describe "the trigger" do
    let(:user)   { User.me }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before { allow(DailyAuditWorker).to receive(:perform_async) }

    def seed!(source:)
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :pending, body: "brief me",
        metadata: { "kind" => "buddy_trigger", "hidden" => true, "source" => source }
      )
    end

    # The turn's own hook, driven the way finalize_success drives it.
    def finish_turn_on(seed, as: user)
      turn = Buddy::GPT::Turn.allocate
      turn.instance_variable_set(:@user, as)
      turn.instance_variable_set(:@inbound, seed)
      turn.send(:queue_daily_audit)
    end

    it "queues the audit when the scheduled briefing finishes" do
      finish_turn_on(seed!(source: "today_scheduled"))

      expect(DailyAuditWorker).to have_received(:perform_async)
    end

    # A tap on the hero chip is not the morning broadcast. Someone asking for a
    # Today at four in the afternoon shouldn't drag a report along with it.
    it "ignores a Today the person asked for by hand" do
      finish_turn_on(seed!(source: "quick_action"))

      expect(DailyAuditWorker).not_to have_received(:perform_async)
    end

    it "ignores an ordinary reply" do
      plain = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :delivered, body: "hey", metadata: {},
      )
      finish_turn_on(plain)

      expect(DailyAuditWorker).not_to have_received(:perform_async)
    end

    # The audit reads Rocco's traffic and posts into Rocco's thread. Another
    # household member's morning briefing is not a reason to run it.
    it "only fires for the account the audit is about" do
      finish_turn_on(seed!(source: "today_scheduled"), as: create(:user))

      expect(DailyAuditWorker).not_to have_received(:perform_async)
    end
  end
end
