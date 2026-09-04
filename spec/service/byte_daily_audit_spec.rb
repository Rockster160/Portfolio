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

      # The prompt used to say "the 24 hours" in so many words, which for a
      # five-hour window is an instruction to go and find nineteen hours that
      # aren't in it.
      it "tells the run how long its window actually is" do
        body = described_class.prompt(user, now: upto, since: since)

        expect(body).to include("Review the 5 hours from")
        expect(body).not_to include("Review the 24 hours")
      end

      it "still says 24 hours for an ordinary run" do
        expect(described_class.prompt(user, now: upto)).to include("Review the 24 hours from")
      end

      it "names both edges of the gap" do
        body = described_class.prompt(user, now: upto, since: since)

        expect(body).to include("Wednesday August 19, 2026 at 8:30 AM")
        expect(body).to include("Wednesday August 19, 2026 at 1:32 PM")
      end

      # Without this it reads a closed window as though it ran up to the present,
      # and reports today's traffic as though it were in scope.
      it "says the window has closed instead of promising it reaches now" do
        body = described_class.prompt(user, now: upto, since: since)

        expect(body).to include("already closed")
        expect(body).not_to include("right up to now")
      end

      it "keeps the up-to-now promise on an ordinary run" do
        expect(described_class.prompt(user, now: upto)).to include("right up to now")
      end

      it "posts one when kicked" do
        described_class.kick!(user, now: upto, since: since)
        posted = described_class.conversation(user).byte_messages.order(:id).last

        expect(posted.body).to include("Review the 5 hours from")
      end
    end

    describe ".span_length" do
      let(:tz) { ActiveSupport::TimeZone["America/Denver"] }

      def length(minutes)
        start = tz.parse("2026-08-19 08:00:00")
        described_class.span_length(start..(start + minutes.minutes))
      end

      it "reads a day as hours" do
        expect(length(24 * 60)).to eq("24 hours")
      end

      it "rounds a ragged window to the nearest hour" do
        expect(length(302)).to eq("5 hours")
      end

      # An hour and a bit rounded to "1 hours" reads as a bug in the prompt.
      it "stays in minutes while hours would be a rounding lie" do
        expect(length(35)).to eq("35 minutes")
      end
    end

    describe ".conversation" do
      it "runs in claude mode against the repo, not as a Buddy thread" do
        convo = described_class.conversation(user)

        expect(convo.mode).to eq("claude")
        expect(convo.metadata["cwd"]).to eq(described_class::CWD)
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

      it "reasserts read mode if the thread was flipped by hand" do
        convo = described_class.conversation(user)
        convo.update!(metadata: convo.metadata.merge("permission_mode" => "auto"))

        expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
      end

      it "reuses the one thread rather than making a new one each day" do
        first = described_class.conversation(user)

        expect(described_class.conversation(user).id).to eq(first.id)
      end

      # Found by NAME, so the report is somewhere you can scroll back through
      # rather than wherever the day happened to end.
      it "adopts an existing thread of that name instead of making a second" do
        existing = user.byte_conversations.create!(name: described_class::NAME, mode: :claude)

        expect(described_class.conversation(user).id).to eq(existing.id)
      end

      # Prod 19 Aug: the report was published into a Buddy companion thread. A
      # companion thread cannot be the audit however it comes to be named one.
      it "puts a thread that has been flipped to companion mode back" do
        convo = described_class.conversation(user)
        convo.update!(mode: :buddy)

        expect(described_class.conversation(user).mode).to eq("claude")
      end

      it "keeps anything else already on the thread" do
        convo = described_class.conversation(user)
        convo.update!(metadata: convo.metadata.merge("kiosk" => "false", "note" => "keep me"))

        expect(described_class.conversation(user).metadata["note"]).to eq("keep me")
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

      # A kicked run is usually kicked BECAUSE of something that just happened,
      # and the last few minutes are the part most likely to be skipped as too
      # fresh to count.
      it "says the last few minutes are in scope" do
        expect(prompt).to include("right up to now, the last few minutes included")
      end

      # A fresh session each day means a dismissed finding comes back every day
      # until the prompt itself says otherwise.
      it "carries the findings that have already been answered" do
        expect(prompt).to include("NOT FINDINGS")
        expect(prompt).to include("syncevents")
      end

      it "makes it reconcile each problem against what shipped after it" do
        expect(prompt).to include("check whether a deploy LATER IN THE WINDOW addressed it")
        expect(prompt).to include("no memory of previous reports")
      end

      # The window can end anywhere, so a fix can land just past it, and a run
      # kicked twice in a day sees the same traffic twice. The thread itself is
      # what stops the same problem being handed back.
      it "sends it to the earlier reports in the thread before calling one new" do
        expect(prompt).to include("previous report already in this thread")
        expect(prompt).to include("a fix may have shipped after the window closed")
      end

      # The report is read by working down it and replying to each item in place.
      # A separate "here's what got resolved" pass at the end means re-reading the
      # same list twice to work out which is which.
      describe "the verdict on each problem" do
        it "goes in that problem's own headline, with a marker to scan for" do
          expect(prompt).to include("The verdict goes in the HEADLINE")
          expect(prompt).to include("✅").and include("⚠️").and include("🔲")
        end

        it "forbids a second pass over the same findings" do
          expect(prompt).to include(%(There is no separate "resolved since" section))
          expect(prompt).to include("never a second pass over the same problems")
        end

        it "keeps the fix with the problem rather than in a list at the end" do
          expect(prompt).to include("lives WITH the problem")
          expect(prompt).to include("A ranking, not a second telling")
        end

        it "ties the marker to the findings section, not just the deploy one" do
          expect(prompt).to include("each one opens with its status marker")
        end

        # Read top to bottom and replied to in order, so the settled ones must not
        # sit between the ones that still need something.
        it "puts what still needs doing first" do
          expect(prompt).to include("Order them `⚠️` then `🔲` then `✅`")
        end
      end

      # It used to ask for a per-day split, back when the window was two whole
      # days. A rolling 24 hours can end anywhere, so midnight is just a point
      # partway through it.
      it "asks for one set of counts rather than a split at midnight" do
        expect(prompt).to include("don't split it at midnight")
      end

      it "forbids the suggestion that must never be made" do
        expect(prompt).to include("Never suggest compacting, debouncing, batching, deduping or collapsing")
      end

      it "asks for the counts, the misfires, the deploys and the backfills" do
        expect(prompt).to include("per conversation AND per direction")
        expect(prompt).to include("Read the whole window in full")
        expect(prompt).to include("Cite the message id")
        expect(prompt).to include("Deploys")
        expect(prompt).to include("Backfills")
      end

      it "tells it to report rather than change anything" do
        expect(prompt).to include("REPORT ONLY")
        expect(prompt).to include("do not offer to until asked")
      end

      # Every concrete example ever put in a prompt in this app came back out of
      # it, so the operational half has to be tables and columns, not sample
      # findings to pattern-match against.
      it "hands over the query surface instead of making it rediscover one" do
        expect(prompt).to include("prod-query.sh")
        expect(prompt).to include("byte_messages")
        expect(prompt).to include("FORMAT csv")
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
      it "clears the Claude session before posting, so the prompt starts fresh" do
        described_class.run!(user)

        expect(ByteLocal).to have_received(:reset_claude_session)
      end

      it "posts the prompt into the thread" do
        expect { described_class.run!(user) }.to change { described_class.conversation(user).byte_messages.count }.by(1)
      end

      # The prompt is long and is not something to scroll past every morning.
      it "posts it hidden, so the thread shows the report and not the ask" do
        described_class.run!(user)
        posted = described_class.conversation(user).byte_messages.order(:created_at).last

        expect(posted.metadata["hidden"]).to be(true)
        expect(posted.metadata["daily_audit"]).to be(true)
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

    # A day with no report is a day nobody looks at, and the absence reads as
    # "nothing went wrong" rather than as a gap.
    describe "the backstop" do
      let(:schedule) { Rails.root.join("config/initializers/sidekiq_cron.rb").read }

      it "is one run a day, not a sweep" do
        expect(schedule).to include(%(daily_10am = "0 10 * * * MST"))
        expect(schedule).to include("DailyAuditWorker")
        expect(schedule).to include("cron:  daily_10am")
      end

      it "leaves no polling entry behind" do
        expect(schedule).not_to include("daily_6am")
        audit_block = schedule[/Daily Byte Audit Backstop.*?\}/m]
        expect(audit_block).not_to include("every_5_minutes")
        expect(audit_block).not_to include("every_minute")
      end
    end
  end
end
