require "rails_helper"

RSpec.describe ByteDailyAudit do
  let(:user) { User.me }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ByteLocal).to receive(:reset_claude_session).and_return(true)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  describe ".window" do
    it "covers yesterday and today, so a fix can be seen next to the failure" do
      days = described_class.window(user, now: Time.zone.parse("2026-08-12 22:00:00"))

      expect(days.first).to eq(Date.new(2026, 8, 11))
      expect(days.last).to eq(Date.new(2026, 8, 12))
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
    subject(:prompt) { described_class.prompt(user, now: Time.zone.parse("2026-08-12 22:00:00")) }

    it "spans two days, ending today" do
      expect(prompt).to include("Tuesday August 11, 2026")
      expect(prompt).to include("Wednesday August 12, 2026")
    end

    # A fresh session every night can't remember what it already reported, so
    # the overlap is the only thing that lets it see this morning's fix.
    it "makes it reconcile the older day against what shipped since" do
      expect(prompt).to include("check whether a deploy since then addressed it")
      expect(prompt).to include("resolved since")
      expect(prompt).to include("no memory of previous reports")
    end

    it "splits the counts by day so the two are comparable" do
      expect(prompt).to include("split by day")
    end

    it "forbids the suggestion that must never be made" do
      expect(prompt).to include("Never suggest compacting, debouncing, batching, deduping or collapsing")
    end

    it "asks for the counts, the misfires, the deploys and the backfills" do
      expect(prompt).to include("per conversation AND per direction")
      expect(prompt).to include("Read both days in full")
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

    it "runs again the next day" do
      described_class.run!(user)
      convo = described_class.conversation(user)
      convo.byte_messages.update_all(created_at: 2.days.ago)

      expect(described_class.run!(user)).to eq(:sent)
    end
  end
end
