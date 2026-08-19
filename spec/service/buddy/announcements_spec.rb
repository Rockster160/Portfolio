require "rails_helper"

# A note queued to ride along on somebody's next Today briefing, said in their
# companion's own words rather than read out.
RSpec.describe Buddy::Announcements do
  let(:user)  { User.me }
  let(:other) { create(:user) }

  before { BuddyAnnouncement.delete_all }

  describe "queueing" do
    it "keeps what was said and no expiry by default" do
      ann = described_class.queue!(user: user, body: "  The plumber is coming Thursday.  ")

      expect(ann.body).to eq("The plumber is coming Thursday.")
      expect(ann.expires_at).to be_nil
      expect(ann.state).to eq(:pending)
    end

    it "takes an expiry, because nothing else would ever clear a time-bound one" do
      ann = described_class.queue!(user: user, body: "Bins go out tonight.", expires_in: 12.hours)

      expect(ann.expires_at).to be_within(1.minute).of(12.hours.from_now)
    end

    it "refuses an empty note rather than queueing a blank line" do
      expect(described_class.queue!(user: user, body: "   ")).to be_nil
      expect(BuddyAnnouncement.count).to eq(0)
    end

    it "truncates rather than failing on something enormous" do
      ann = described_class.queue!(user: user, body: "x" * 900)

      expect(ann.body.length).to eq(BuddyAnnouncement::MAX_BODY)
    end
  end

  describe "what the next briefing picks up" do
    it "is nothing at all for someone with none, so their prompt is unchanged" do
      expect(described_class.claim_block!(user)).to eq("")
    end

    # The block sits inside ~12k characters of "forward-looking only", "lead
    # with what's still ahead", "mention FEWER things", "cut padding" and "aim
    # for 3-5 short lines". An announcement is none of those, so without an
    # explicit exemption it reads as something to filter out — which is exactly
    # what happened the first time one was queued for real: it reached the model
    # in the seed and simply wasn't said.
    it "exempts itself from the day rules that would otherwise filter it out" do
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")

      block = described_class.claim_block!(user)

      expect(block).to include("NOT OPTIONAL")
      expect(block).to match(/none of it applies to these/i)
      expect(block).to match(/don't count against the three-to-five lines/i)
      expect(block).to match(/quiet day .* still carries these/i)
      expect(block).to match(/has failed/i)
    end

    it "carries the substance and tells the model to reword it" do
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")

      block = described_class.claim_block!(user)

      expect(block).to include("The plumber is coming Thursday.")
      expect(block).to match(/in your own words/i)
      expect(block).to match(/not a line to read out/i)
    end

    # The main use: telling people what's changing about their companion. Said
    # as a thing about itself, not read out as a release note.
    it "frames a change to the companion in the first person, never as a changelog" do
      described_class.queue!(user: user, body: "Buddy can now search past conversations.")

      block = described_class.claim_block!(user)

      expect(block).to match(/about YOU/)
      expect(block).to match(/first person/i)
      expect(block).to match(/never .*conversation search has been added/i)
      expect(block).to match(/don't call it an update, a feature, a version, a rollout or a change log/i)
    end

    it "asks for the rough edges to be named rather than smoothed over" do
      described_class.queue!(user: user, body: "Reminders may fire a minute late this week.")

      block = described_class.claim_block!(user)

      expect(block).to match(/what to watch for/i)
      expect(block).to match(/believing they broke it/i)
    end

    it "keeps them in the order they were written" do
      described_class.queue!(user: user, body: "First thing.")
      travel(1.minute) { described_class.queue!(user: user, body: "Second thing.") }

      block = described_class.claim_block!(user)

      expect(block.index("First thing.")).to be < block.index("Second thing.")
    end

    it "never picks up someone else's" do
      described_class.queue!(user: other, body: "Their private note.")

      expect(described_class.claim_block!(user)).to eq("")
    end

    it "leaves an expired one behind rather than saying it days late" do
      described_class.queue!(user: user, body: "Bins go out tonight.", expires_in: 1.hour)

      travel(2.hours) { expect(described_class.claim_block!(user)).to eq("") }
    end

    it "holds anything past a few back for the next briefing" do
      5.times { |i| described_class.queue!(user: user, body: "Thing #{i}.") }

      block = described_class.claim_block!(user)

      expect(block.scan(/Thing \d\./).size).to eq(described_class::MAX_PER_BRIEFING)
      expect(BuddyAnnouncement.pending.count).to eq(5 - described_class::MAX_PER_BRIEFING)
    end
  end

  describe "claiming" do
    # The failure this exists to prevent: the same note every morning forever.
    it "says it once and not on the next briefing" do
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")

      expect(described_class.claim_block!(user)).to include("plumber")
      expect(described_class.claim_block!(user)).to eq("")
    end

    it "keeps the row so a briefing that failed can be sent again" do
      ann = described_class.queue!(user: user, body: "The plumber is coming Thursday.")
      described_class.claim_block!(user)

      expect(ann.reload.state).to eq(:delivered)

      ann.update!(delivered_at: nil)
      expect(described_class.claim_block!(user)).to include("plumber")
    end
  end

  describe "in the real briefing seed" do
    it "reaches the prompt the briefing is actually built from" do
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")

      expect(Buddy::TodayBriefing.seed(user)).to include("The plumber is coming Thursday.")
    end

    it "is claimed by building the seed, so one briefing carries it once" do
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")

      Buddy::TodayBriefing.seed(user)

      expect(Buddy::TodayBriefing.seed(user)).not_to include("plumber")
    end

    it "leaves the seed untouched for someone with nothing queued" do
      expect(Buddy::TodayBriefing.seed(user)).not_to match(/ANNOUNCEMENTS/i)
    end

    # It's the one thing in a briefing they have no other way of learning, so it
    # can't sit behind the parts they could read off their own calendar.
    it "sits above the agenda rather than after it" do
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")

      seed = Buddy::TodayBriefing.seed(user)

      expect(seed.index("ANNOUNCEMENTS")).to be < seed.index("LEAD WITH what still needs to happen")
    end

    # The claim happens as the seed is BUILT, so anything that stops a briefing
    # being built has to stop it before that. Buddy::TodayBriefing.deliver!
    # checks SleepGuard on the line above the one that calls `seed`, and if those
    # two ever swap, a scheduled briefing that never went out would still have
    # burned the announcement.
    it "survives a scheduled briefing that Buddy was asleep for" do
      convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")
      allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

      expect(Buddy::TodayBriefing.deliver!(user, convo)).to be_nil
      expect(BuddyAnnouncement.pending.count).to eq(1)
    end

    it "is claimed by a briefing that Buddy was awake for" do
      convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)
      described_class.queue!(user: user, body: "The plumber is coming Thursday.")
      allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(false)
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)

      msg = Buddy::TodayBriefing.deliver!(user, convo)

      expect(msg.body).to include("The plumber is coming Thursday.")
      expect(BuddyAnnouncement.pending.count).to eq(0)
    end
  end
end
