require "rails_helper"

# When Buddy comes back to something on its own.
#
# The design constraint that shapes all of this: there is NO quota. A person
# with nothing worth following up gets nothing; a person with a sick cat and a
# parent in hospital gets both. What keeps it from being annoying is spacing and
# ordering, not a cap — a cap with an empty slot in it is an invitation to
# invent something to put there.
RSpec.describe Buddy::CheckIns do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def followup(content, severity: 60, check_in_at: 2.hours.from_now, **attrs)
    user.buddy_memories.create!(
      kind: :followup, content: content, severity: severity, check_in_at: check_in_at, **attrs
    )
  end

  before do
    BuddyMemory.where(user: user).destroy_all
    convo
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionRelay).to receive(:conversation_for).and_return(convo)
  end

  describe "placement in the day" do
    it "lands inside a band, never at an arbitrary minute" do
      placed = described_class.place(Time.current + 5.days, user: user)
      hour   = placed.in_time_zone(user.timezone).hour

      expect(described_class::BANDS.values.any? { |b| b.cover?(hour) }).to be(true)
      expect(placed.min).to eq(0)
    end

    it "never places a check-in before the moment it was asked to" do
      target = Time.current + 3.days

      expect(described_class.place(target, user: user)).to be >= target
    end

    it "rolls past a band that has already gone by rather than going backwards" do
      zone   = ActiveSupport::TimeZone[user.timezone]
      late   = zone.local(2026, 8, 20, 23, 30, 0)
      placed = described_class.place(late, user: user, now: late)

      expect(placed).to be > late
    end
  end

  describe "no quota, but spacing" do
    it "gives a person with several real concerns all of them" do
      followup("the cat is in hospital", severity: 70)
      followup("mum broke her leg", severity: 85)
      followup("the deck project stalled", severity: 40)

      described_class.replan!(user)

      expect(BuddyMemory.where(user: user).where.not(check_in_at: nil).count).to eq(3)
    end

    it "never lands two in one sitting" do
      3.times { |i| followup("thing #{i}", severity: 50 + i) }

      described_class.replan!(user)

      times = BuddyMemory.where(user: user).order(:check_in_at).pluck(:check_in_at)
      times.each_cons(2) { |a, b| expect(b - a).to be >= described_class::MIN_GAP }
    end

    # The mother-vs-cat case: a weightier arrival takes the near slot and the
    # lesser one moves. Nothing is dropped.
    it "lets a weightier concern take the near slot and pushes the lighter one back" do
      cat = followup("the cat is sick", severity: 50)
      leg = followup("mum broke her leg", severity: 90)

      described_class.replan!(user)

      expect(leg.reload.check_in_at).to be < cat.reload.check_in_at
    end

    # MIN_GAP spaces check-ins from EACH OTHER. Seeding the cursor with `now`
    # turned it into a flat 20-hour delay on the first one in the queue, so a
    # check-in about a 6pm dinner, noted at 2pm the same day, was asked the
    # NEXT evening (prod: Suki to Eve, buddy_memories 128, message 5157).
    describe "the first one, with nothing to be spaced from" do
      it "is not pushed a day out when there is no previous check-in" do
        memory = followup("grandson's dinner tonight", check_in_at: 3.hours.from_now)

        described_class.replan!(user)

        expect(memory.reload.check_in_at).to be < 20.hours.from_now
      end

      it "is still not pushed out when the last check-in was days ago" do
        BuddyMemory.where(user: user).destroy_all
        followup("an old one", check_in_at: 6.days.ago, checked_in_at: 6.days.ago)
        memory = followup("grandson's dinner tonight", check_in_at: 3.hours.from_now)

        described_class.replan!(user)

        expect(memory.reload.check_in_at).to be < 20.hours.from_now
      end

      # The spacing it DOES owe: a check-in an hour ago means the next waits.
      it "still spaces off a check-in that just happened" do
        followup("an earlier one", check_in_at: nil, checked_in_at: 1.hour.ago)
        memory = followup("the new one", check_in_at: 2.hours.from_now)

        described_class.replan!(user)

        expect(memory.reload.check_in_at).to be >= 1.hour.ago + described_class::MIN_GAP
      end
    end
  end

  # No config.time_zone, so `Date.current` and `created_at.to_date` were both
  # UTC. 6pm MDT is already midnight UTC, and BANDS puts `evening` at 18-20 and
  # `night` at 22-23 local — so EVERY evening and night check-in counted a day
  # too many. Prod memory 128: created 31 Aug 2:05 PM, seeded 1 Sep 6:00 PM,
  # 28 hours apart, announced as "2 days".
  # Every time here is UTC on purpose: that is what `Time.current` hands this
  # code in production, because there is no `config.time_zone`. A user-zoned
  # time would hide the whole bug — `.to_date` on one of those is already the
  # local date.
  describe "how long it says something has been waiting" do
    let(:zone) { ActiveSupport::TimeZone[user.timezone] }

    # 31 Aug 2:05 PM MDT = 1 Sep 20:05 UTC... no: 31 Aug 20:05 UTC.
    # 1 Sep 6:00 PM MDT  = 2 Sep 00:00 UTC — already tomorrow, in UTC.
    let(:created_utc) { Time.utc(2026, 8, 31, 20, 5) }
    let(:seeded_utc)  { Time.utc(2026, 9, 2, 0, 0) }

    it "the two really are one local day apart" do
      expect(created_utc.in_time_zone(zone).to_date).to eq(Date.new(2026, 8, 31))
      expect(seeded_utc.in_time_zone(zone).to_date).to eq(Date.new(2026, 9, 1))
      expect(seeded_utc - created_utc).to be < 30.hours
    end

    it "calls 28 hours across one local midnight yesterday" do
      memory = followup("the dinner", created_at: created_utc)

      expect(memory.waiting_label(seeded_utc)).to eq("since yesterday")
    end

    it "does not roll over on the same local evening" do
      memory = followup("the dinner", created_at: Time.utc(2026, 9, 1, 15, 0))  # 9am MDT

      expect(memory.waiting_label(Time.utc(2026, 9, 2, 2, 0))).to eq("today")  # 8pm MDT same day
    end

    it "still counts real days" do
      memory = followup("the dinner", created_at: Time.utc(2026, 8, 29, 20, 5))

      expect(memory.waiting_label(seeded_utc)).to eq("3 days")
    end

    it "reads the same from the seed the model is handed" do
      memory = followup("the dinner", created_at: created_utc)

      seed = described_class.send(:seed, memory, seeded_utc)

      expect(seed).to include("since yesterday")
      expect(seed).not_to include("2 days")
    end
  end

  describe "severity is not the running order" do
    # Severe now, actionable next week. A queue sorted on severity alone asks
    # about next week's surgery tomorrow.
    it "puts a live lesser concern ahead of a weightier one that isn't live yet" do
      surgery = followup("mum's surgery", severity: 90, relevant_at: 7.days.from_now)
      today   = followup("rough day at work", severity: 45)

      described_class.replan!(user)

      expect(today.reload.check_in_at).to be < surgery.reload.check_in_at
    end

    it "never schedules one before it becomes relevant" do
      surgery = followup("mum's surgery", severity: 90, relevant_at: 7.days.from_now)

      described_class.replan!(user)

      expect(surgery.reload.check_in_at).to be >= surgery.relevant_at
    end
  end

  describe "what is even a candidate" do
    it "ignores anything below the severity floor" do
      trivial = followup("they like big mugs", severity: 5)

      expect(trivial.check_in_candidate?).to be(false)
      expect(described_class.due(user)).to be_empty
    end

    it "ignores anything already resolved or dropped" do
      followup("sorted itself out", check_in_at: 1.hour.ago).update!(status: :done)

      expect(described_class.due(user)).to be_empty
    end

    it "ignores a plain memory that was never a follow-up" do
      user.buddy_memories.create!(kind: :concept, content: "cat is called Fae", severity: 90)

      expect(described_class.due(user)).to be_empty
    end
  end

  describe "firing" do
    it "seeds a turn rather than posting a canned line" do
      memory = followup("the cat is in hospital", check_in_at: 1.hour.ago)
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      expect(described_class.fire!(memory)).to eq(:fired)
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt) { |args|
        expect(args[:seed]).to include("the cat is in hospital")
        expect(args[:metadata][:source]).to eq("check_in")
      }
    end

    # They are right here. A scheduled question about last week is an
    # interruption, and the gate MOVES it rather than dropping it.
    it "gets out of the way of a live conversation and comes back later" do
      memory = followup("the cat is in hospital", check_in_at: 1.hour.ago)
      convo.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: "hey")
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      expect(described_class.fire!(memory)).to eq(:deferred)
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
      expect(memory.reload.check_in_at).to be > Time.current
    end

    # Every seeded turn is written as an OUTBOUND message — a briefing, a watch
    # firing, a reminder, and check-in delivery itself. Counting those as "the
    # person just spoke" meant Buddy talking to itself looked like a live
    # conversation, so the 8:30 briefing would push any check-in due in the hour
    # after it, every day, and one check-in would defer the next behind it.
    it "does not mistake Buddy's own seeded turns for the person speaking" do
      memory = followup("the cat is in hospital", check_in_at: 1.hour.ago)
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "What's on for TODAY...",
        metadata: { "kind" => "buddy_trigger", "hidden" => true, "source" => "today_scheduled" },
      )
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      expect(described_class.fire!(memory)).to eq(:fired)
    end

    it "still gets out of the way of something the person actually typed" do
      memory = followup("the cat is in hospital", check_in_at: 1.hour.ago)
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hey")
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      expect(described_class.fire!(memory)).to eq(:deferred)
    end

    it "closes one that stopped being worth asking about instead of firing it" do
      memory = followup("sorted", check_in_at: 1.hour.ago)
      memory.update!(status: :done)
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      expect(described_class.fire!(memory)).to eq(:closed)
      expect(memory.reload.check_in_at).to be_nil
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end
  end

  describe "ignored dies, answered can re-arm" do
    it "does not ask a second time on its own once it has asked" do
      memory = followup("the cat is in hospital", check_in_at: 1.hour.ago)
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      described_class.fire!(memory)

      expect(memory.reload.check_in_at).to be_nil
      expect(memory.reload.checked_in_at).to be_present
      expect(described_class.due(user)).to be_empty
    end

    # "Cat is still in the hospital, doing okay for now" is not a resolution.
    # `checked_in_at` is a last-checked mark, not a seal.
    it "can be armed again after an answer, and keeps the record of the last one" do
      memory = followup("the cat is in hospital", check_in_at: 1.hour.ago)
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
      described_class.fire!(memory)
      first_check = memory.reload.checked_in_at

      memory.update!(check_in_at: 2.days.from_now)

      expect(memory.reload.checked_in_at).to eq(first_check)
      expect(memory.check_in_candidate?).to be(true)
    end
  end
end
