require "rails_helper"

RSpec.describe ByteStandupPrep do
  let(:user) { User.me }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ByteLocal).to receive(:reset_claude_session).and_return(true)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  describe ".window" do
    it "covers yesterday, from its first minute to right now" do
      span = described_class.window(user, now: tz.parse("2026-09-03 08:45:00"))

      expect(span.first).to eq(tz.parse("2026-09-02 00:00:00"))
      expect(span.last).to eq(tz.parse("2026-09-03 08:45:00"))
    end

    # Monday's standup is about Friday. A literal "yesterday" reports on Sunday,
    # finds nothing, and says so — which is worse than useless, because it reads
    # as "you did nothing" rather than as the wrong question.
    it "reaches back over the weekend on a Monday" do
      span = described_class.window(user, now: tz.parse("2026-09-07 08:45:00"))

      expect(span.first).to eq(tz.parse("2026-09-04 00:00:00"))
    end

    it "stops at the previous day on any other morning" do
      span = described_class.window(user, now: tz.parse("2026-09-04 08:45:00"))

      expect(span.first).to eq(tz.parse("2026-09-03 00:00:00"))
    end

    # A run kicked by hand has to see the commit from five minutes ago — that is
    # the one most likely to still need saying out loud.
    it "runs up to the moment it is asked, not to a fixed hour" do
      now = tz.parse("2026-09-03 08:52:00")

      expect(described_class.window(user, now: now)).to cover(now - 1.minute)
    end
  end

  describe ".conversation" do
    it "runs in claude mode against the repo the work is in" do
      convo = described_class.conversation(user)

      expect(convo.mode).to eq("claude")
      expect(convo.metadata["cwd"]).to eq(described_class::CWD)
    end

    # The entire read-only guarantee is this one value. `ask` would not do it:
    # that mode is as wide as whatever has ever been tapped "always allow", and
    # ocs-backend's own settings allow `git checkout` and `git stash`.
    it "sits in read mode, which cannot be widened by an allow rule" do
      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
    end

    # The pwd bar only knows two states and writes back one of them, so a single
    # tap on this thread silently downgrades it to a mode that can be widened.
    it "puts it back when the thread has been toggled to ask" do
      convo = described_class.conversation(user)
      convo.update!(metadata: convo.metadata.merge("permission_mode" => "ask"))

      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
    end

    it "puts it back when the thread has been toggled to auto" do
      convo = described_class.conversation(user)
      convo.update!(metadata: convo.metadata.merge("permission_mode" => "auto"))

      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
    end

    # The brief is read in the primary thread. This one is the machinery that
    # produces it, and unarchived it sits in the list carrying an unread count
    # for a report the person has already read somewhere else.
    it "stays out of the thread list" do
      expect(described_class.conversation(user)).to be_archived
    end

    it "puts it back when the thread has been unarchived" do
      described_class.conversation(user).update!(archived: false)

      expect(described_class.conversation(user)).to be_archived
    end

    # `for_self_initiated` reads `active`, so an archived thread can never
    # become the place a briefing or a reminder lands.
    it "is not somewhere a self-initiated message could land" do
      described_class.conversation(user)

      expect(ByteConversation.for_self_initiated(user)&.name).not_to eq(described_class::NAME)
    end

    it "reuses the one thread rather than making a new one each morning" do
      first = described_class.conversation(user)

      expect(described_class.conversation(user).id).to eq(first.id)
    end

    it "keeps anything else already on the thread" do
      convo = described_class.conversation(user)
      convo.update!(metadata: convo.metadata.merge("note" => "keep me"))

      expect(described_class.conversation(user).metadata["note"]).to eq("keep me")
    end
  end

  describe ".prompt" do
    subject(:prompt) { described_class.prompt(user, now: tz.parse("2026-09-03 08:45:00")) }

    context "with items on the Standup list" do
      before do
        list = create(:list, name: "Standup", user: user)
        create(:list_item, list: list, name: "Yesterday: memo on Allocations")
        create(:list_item, list: list, name: "Today: recon follow-up")
      end

      # The list is the part written on purpose. A run that has to go and find it
      # can fail to, and then the only hand-authored input is missing.
      it "carries the list in rather than leaving it to be looked up" do
        expect(prompt).to include("Yesterday: memo on Allocations")
        expect(prompt).to include("Today: recon follow-up")
      end
    end

    context "with an empty Standup list" do
      before { create(:list, name: "Standup", user: user) }

      it "says so, so an empty list is a fact rather than a silence" do
        expect(prompt).to include("nothing on it this morning")
      end
    end

    it "names both edges of the window" do
      expect(prompt).to include("Wednesday September 2, 2026 at 12:00 AM")
      expect(prompt).to include("Thursday September 3, 2026 at 8:45 AM")
    end

    # Someone — or an agent — may be mid-edit in one of these worktrees at 8:45.
    it "forbids moving any working tree" do
      expect(prompt).to include("git checkout")
      expect(prompt).to include("git switch")
      expect(prompt).to include("git -C")
    end

    # Seven of the ten `ocs-backend--*` directories on this machine are leftovers
    # with no `.git`. Globbing them reports work that finished weeks ago.
    it "sends it to `git worktree list` instead of the directory names" do
      expect(prompt).to include("worktree list")
      expect(prompt).to include("Do NOT glob")
    end

    it "asks for the three sections in the order they get read" do
      expect(prompt).to include("On my list")
      expect(prompt).to include("Committed")
      expect(prompt).to include("Still going")
    end

    # It is read standing up, twenty seconds before it has to be said out loud.
    it "says plainly that length is the failure mode" do
      expect(prompt).to include("One thing, one short bullet")
    end

    # There is nobody to answer, so a question is a stall, not a safeguard.
    it "tells the run not to ask and not to retry a refusal" do
      expect(prompt).to include("do not ask a question")
      expect(prompt).to include("Do not retry a refused call")
    end
  end

  describe ".run!" do
    it "posts the prompt into the prep thread" do
      expect { described_class.run!(user) }.to change {
        described_class.conversation(user).byte_messages.count
      }.by(1)
    end

    it "keeps the prompt itself out of the thread" do
      described_class.run!(user)
      posted = described_class.conversation(user).byte_messages.order(:id).last

      expect(posted.metadata["hidden"]).to be_truthy
    end

    it "starts a fresh session so a month of these doesn't become one context" do
      expect(ByteLocal).to receive(:reset_claude_session)

      described_class.run!(user)
    end

    it "stands down when this morning's brief already went" do
      described_class.run!(user)

      expect(described_class.run!(user)).to eq(:already_ran)
    end

    # A prompt that never reached the Mac is not a brief. Reading a failed row as
    # "already ran" means walking into the meeting with nothing.
    it "runs again when the only attempt today failed" do
      described_class.run!(user)
      described_class.conversation(user).byte_messages.each { |m| m.update!(state: :failed) }

      expect(described_class.run!(user)).to eq(:sent)
    end
  end

  # Someone typing this is watching for a result, so the guard against a trigger
  # firing twice is the wrong rule here — it would silently do nothing.
  describe ".kick!" do
    it "runs even when this morning's already went" do
      described_class.run!(user)

      expect(described_class.kick!(user)).to eq(:sent)
    end

    it "defaults to User.me so the console call needs no argument" do
      expect { described_class.kick! }.to change {
        described_class.conversation(user).byte_messages.count
      }.by(1)
    end
  end

  describe ".dispatch" do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(Buddy::Errors).to receive(:report)
    end

    it "runs the brief on its own trigger" do
      expect(described_class).to receive(:run!).with(user)

      described_class.dispatch(user, described_class::TRIGGER)
    end

    it "ignores every other trigger on the bus" do
      expect(described_class).not_to receive(:run!)

      described_class.dispatch(user, "agenda_item")
    end

    # Both machines run the schedule, both read their own database, and ByteLocal
    # reaches the same Mac from either — so a dev box publishes a second brief
    # into production's thread. DailyAuditWorker learned this the expensive way.
    it "does nothing off production" do
      allow(Rails.env).to receive(:production?).and_return(false)
      expect(described_class).not_to receive(:run!)

      described_class.dispatch(user, described_class::TRIGGER)
    end

    it "swallows a failure rather than taking the trigger bus down with it" do
      allow(described_class).to receive(:run!).and_raise("mac asleep")

      expect { described_class.dispatch(user, described_class::TRIGGER) }.not_to raise_error
    end
  end

  describe ".forward!" do
    let(:prep)    { described_class.conversation(user) }
    let(:primary) { ByteConversation.for_self_initiated(user) }

    def report(parent, kind: "claude", body: "- memo on Allocations")
      prep.byte_messages.create!(
        user:      user,
        direction: :inbound,
        state:     :delivered,
        body:      body,
        metadata:  { "kind" => kind, "in_reply_to" => parent&.id },
      )
    end

    before do
      user.byte_conversations.create!(name: "Byte", mode: :buddy) if primary.nil?
      described_class.run!(user)
    end

    def sent_prompt
      prep.byte_messages.where(direction: :outbound).order(:id).last
    end

    it "carries the finished brief into the primary thread" do
      expect { described_class.forward!(report(sent_prompt)) }.to change {
        ByteConversation.for_self_initiated(user).byte_messages.count
      }.by(1)
    end

    it "delivers the report verbatim" do
      described_class.forward!(report(sent_prompt, body: "- recon follow-up (merged)"))
      landed = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

      expect(landed.body).to eq("- recon follow-up (merged)")
    end

    it "marks where it came from" do
      described_class.forward!(report(sent_prompt))
      landed = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

      expect(landed.metadata["source"]).to eq("standup_prep")
    end

    # The prep thread is a real thread and a reply typed into it the next morning
    # answers a different parent.
    it "leaves a message that isn't answering the brief where it was written" do
      stray = prep.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "hm",
        metadata: { "kind" => "claude" }
      )

      expect(described_class.forward!(stray)).to be(false)
    end

    it "ignores a message from any other thread" do
      other = user.byte_conversations.create!(name: "Daily Audit", mode: :claude)
      elsewhere = other.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "audit",
        metadata: { "kind" => "claude", "in_reply_to" => sent_prompt.id }
      )

      expect(described_class.forward!(elsewhere)).to be(false)
    end

    it "ignores anything that isn't a claude reply" do
      expect(described_class.forward!(report(sent_prompt, kind: "buddy_activity"))).to be(false)
    end
  end
end
