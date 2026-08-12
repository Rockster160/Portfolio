require "rails_helper"

RSpec.describe ByteDailyAudit do
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

  describe ".conversation" do
    it "runs in claude mode against the repo, not as a Buddy thread" do
      convo = described_class.conversation(user)

      expect(convo.mode).to eq("claude")
      expect(convo.metadata["cwd"]).to eq(described_class::CWD)
    end

    # The whole read-only guarantee rests on this one value, and it's togglable
    # from the pwd bar - an audit left in "auto" overnight can rewrite the app.
    it "sits in ask mode so a Write has to be tapped" do
      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("ask")
    end

    it "reasserts ask mode if the thread was flipped to auto by hand" do
      convo = described_class.conversation(user)
      convo.update!(metadata: convo.metadata.merge("permission_mode" => "auto"))

      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("ask")
    end

    it "reuses the one thread rather than making a new one each day" do
      first = described_class.conversation(user)

      expect(described_class.conversation(user).id).to eq(first.id)
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
  end
end
