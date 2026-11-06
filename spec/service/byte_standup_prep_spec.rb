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

    # The work repo and the `gh` login it reports from are only on the laptop.
    it "runs on the laptop, and goes back there if it was moved" do
      convo = described_class.conversation(user)
      expect(convo).to be_on_laptop

      convo.update!(machine: :mini)
      expect(described_class.conversation(user)).to be_on_laptop
    end

    # The entire read-only guarantee is this one value. `ask` would not do it:
    # that mode is as wide as whatever has ever been tapped "always allow", and
    # ocs-backend's own settings allow `git checkout` and `git stash`.
    it "sits in read mode, which cannot be widened by an allow rule" do
      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
    end

    # The pwd bar only knows two states and writes back one of them, so a single
    # tap on this thread silently downgrades it to a mode that can be widened.
    it "puts read mode back when the thread has been toggled to ask or auto" do
      %w[ask auto].each do |mode|
        convo = described_class.conversation(user)
        convo.update!(metadata: convo.metadata.merge("permission_mode" => mode))

        expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
      end
    end

    # The brief is read in the primary thread. This one is the machinery that
    # produces it, and unarchived it sits in the list carrying an unread count
    # for a report the person has already read somewhere else.
    it "stays out of the thread list, even after being unarchived" do
      expect(described_class.conversation(user)).to be_archived

      described_class.conversation(user).update!(archived: false)
      expect(described_class.conversation(user)).to be_archived
    end

    # `for_self_initiated` reads `active`, so an archived thread can never
    # become the place a briefing or a reminder lands.
    it "is not somewhere a self-initiated message could land" do
      described_class.conversation(user)

      expect(ByteConversation.for_self_initiated(user)&.name).not_to eq(described_class::NAME)
    end

    it "reuses the one thread each morning, keeping anything else on it" do
      convo = described_class.conversation(user)
      convo.update!(metadata: convo.metadata.merge("note" => "keep me"))

      again = described_class.conversation(user)
      expect(again.id).to eq(convo.id)
      expect(again.metadata["note"]).to eq("keep me")
    end
  end

  describe ".prompt" do
    # The list is the part written on purpose. A run that has to go and find it
    # can fail to, and then the only hand-authored input is missing.
    it "carries the Standup list in, and both edges of the window" do
      list = create(:list, name: "Standup", user: user)
      create(:list_item, list: list, name: "Yesterday: memo on Allocations")
      create(:list_item, list: list, name: "Today: recon follow-up")

      prompt = described_class.prompt(user, now: tz.parse("2026-09-03 08:45:00"))

      expect(prompt).to include("Yesterday: memo on Allocations", "Today: recon follow-up")
      expect(prompt).to include("Wednesday September 2, 2026 at 12:00 AM", "Thursday September 3, 2026 at 8:45 AM")
    end
  end

  describe ".run!" do
    # A fresh session each time, so a month of these doesn't become one context.
    it "posts the prompt, hidden, into the prep thread on a fresh session" do
      expect(ByteLocal).to receive(:reset_claude_session)

      expect { described_class.run!(user) }.to change {
        described_class.conversation(user).byte_messages.count
      }.by(1)
      expect(described_class.conversation(user).byte_messages.order(:id).last.metadata["hidden"]).to be_truthy
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

    it "carries the finished brief verbatim into the primary thread, marked with its source" do
      expect { described_class.forward!(report(sent_prompt, body: "- recon follow-up (merged)")) }.to change {
        ByteConversation.for_self_initiated(user).byte_messages.count
      }.by(1)
      landed = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

      expect(landed.body).to eq("- recon follow-up (merged)")
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

  # The -5 minute "Import Standup" step used to empty the list every morning.
  # It was disabled on 3 Sep when this service replaced it and nothing took
  # over the emptying, so `Yesterday: Worked on adding a memo to Allocations` —
  # typed 3 Sep about work that merged 3 Sep — led "On my list" every morning
  # for the six days after. Rocco: "Stand up should ONLY be what was worked on
  # yesterday."
  describe "spending the list" do
    let(:prep)    { described_class.conversation(user) }
    let(:primary) { ByteConversation.for_self_initiated(user) }
    let(:list)    { create(:list, name: "Standup", user: user) }
    let!(:item)   { create(:list_item, list: list, name: "Yesterday: memo on Allocations") }

    before do
      user.byte_conversations.create!(name: "Byte", mode: :buddy) if primary.nil?
      described_class.run!(user)
    end

    def sent_prompt
      prep.byte_messages.where(direction: :outbound).order(:id).last
    end

    def brief(parent)
      prep.byte_messages.create!(
        user:      user,
        direction: :inbound,
        state:     :delivered,
        body:      "- memo on Allocations",
        metadata:  { "kind" => "claude", "in_reply_to" => parent&.id },
      )
    end

    it "says it in the brief first" do
      expect(sent_prompt.body).to include("Yesterday: memo on Allocations")
    end

    it "takes it off the list once the brief has landed" do
      expect { described_class.forward!(brief(sent_prompt)) }
        .to change { ListItem.find_by(id: item.id) }.to(nil)
    end

    # A run that fails never reaches the forward, and the items have to survive
    # it — a morning with no brief must not also be a morning that quietly ate
    # the only part he wrote by hand.
    it "leaves it alone when no brief was delivered" do
      expect { described_class.forward!(brief(nil)) }
        .not_to(change { ListItem.find_by(id: item.id) })
    end

    # By the ids read when the prompt went out, not by re-reading the list:
    # anything typed while the brief is being written belongs to tomorrow's.
    it "does not take anything added after the prompt went out" do
      later = create(:list_item, list: list, name: "Yesterday: the other thing")
      described_class.forward!(brief(sent_prompt))

      expect(ListItem.find_by(id: later.id)).to be_present
    end
  end
end
