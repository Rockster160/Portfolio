require "rails_helper"

# The background pass that reads a finished stretch and writes down what was
# worth keeping. The fixture is the real message this exists because of: prod
# 3907, which carried three separate things and produced none of them.
RSpec.describe Buddy::Compile do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def say(body, direction: :outbound, at: Time.current, meta: {})
    convo.byte_messages.create!(
      user: user, direction: direction, state: :delivered,
      body: body, metadata: meta, created_at: at,
    )
  end

  def stub_client(payload)
    text = payload.is_a?(String) ? payload : payload.to_json
    fake = FakeBuddyClient.new([{ text: text }])
    allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
    fake
  end

  def flare
    say("Just noticed that my CSCR has flared up a bit today. Likely related to the fact that I heard " \
        "that I'll be out of a job before the end of the year.")
    say("Oh no. That's a lot to get hit with at once.", direction: :inbound, meta: { "kind" => "buddy" })
  end

  before do
    BuddyMemory.where(user: user).destroy_all
    allow(MonitorChannel).to receive(:broadcast_to)
    convo.update_columns(buddy_compile_after: 2.hours.ago)
  end

  describe "flagging and the debounce" do
    it "sets a target roughly an hour out" do
      convo.update_columns(buddy_compile_after: nil)

      described_class.flag!(convo)

      expect(convo.reload.buddy_compile_after).to be_within(1.minute).of(1.hour.from_now)
    end

    # Every message re-flags, so one compile covers a conversation rather than
    # one per message.
    it "pushes the target back when another message lands" do
      described_class.flag!(convo, now: 30.minutes.ago)
      first = convo.reload.buddy_compile_after

      described_class.flag!(convo)

      expect(convo.reload.buddy_compile_after).to be > first
    end

    it "does nothing while the target is still ahead, without touching the model" do
      convo.update_columns(buddy_compile_after: 20.minutes.from_now)
      flare
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.run!(convo)).to be_empty
    end

    it "does nothing at all when the conversation was never flagged" do
      convo.update_columns(buddy_compile_after: nil)
      flare
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.run!(convo)).to be_empty
    end
  end

  # `buddy_compiled_at` is null until a thread compiles once, and the count cap
  # alone let that first run read whatever forty messages were there. Suki's
  # first run on 19 Aug reached back to 16 Aug and wrote two memories off things
  # that had been asked for, actioned and finished three days earlier — one of
  # them a 3pm errand filed as a concept, which never expires.
  describe "the first compile on a thread that has never compiled" do
    it "reads the sitting that just happened, not the thread's history" do
      old = say("I need to leave around 3 to visit Doug.", at: 3.days.ago)
      say("On the calendar for 3:00 PM.", direction: :inbound, at: 3.days.ago, meta: { "kind" => "buddy" })
      recent = say("The fence gate is sticking again.")
      say("Oh, that one.", direction: :inbound, meta: { "kind" => "buddy" })
      convo.update_columns(buddy_compiled_at: nil)
      client = stub_client({ memories: [] })

      described_class.run!(convo)

      brief = client.calls.first.input.first[:content]
      expect(brief).to include(recent.body)
      expect(brief).not_to include(old.body)
    end

    it "still reads everything since the last compile once there has been one" do
      say("Older but already compiled past.", at: 3.hours.ago)
      say("Noted.", direction: :inbound, at: 3.hours.ago, meta: { "kind" => "buddy" })
      convo.update_columns(buddy_compiled_at: 4.hours.ago)
      client = stub_client({ memories: [] })

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).to include("Older but already compiled past.")
    end
  end

  # Both memories written off Suki's thread point at her goodnight message,
  # which contains neither subject: the stamp was "last thing they said", not
  # "where this came from". Nothing reads the column yet, which is exactly why
  # it has to be right or absent.
  describe "where a memory says it came from" do
    it "points at the message the content is actually in" do
      origin = say("The fence gate is sticking again and the latch is bent.")
      say("I'll remember that.", direction: :inbound, meta: { "kind" => "buddy" })
      say("I'm off to bed for the night.")
      stub_client({
        memories: [
          { content: "Their fence gate is sticking and the latch is bent.", kind: "concept",
            severity: 20, tags: %w[home], check_in_days: nil },
        ],
      })

      expect(described_class.run!(convo).first.source_message_id).to eq(origin.id)
    end

    it "leaves it empty rather than pointing somewhere wrong" do
      say("I'm off to bed for the night.")
      say("Night!", direction: :inbound, meta: { "kind" => "buddy" })
      stub_client({
        memories: [
          { content: "Their dentist appointment moved to November.", kind: "concept",
            severity: 20, tags: %w[health], check_in_days: nil },
        ],
      })

      expect(described_class.run!(convo).first.source_message).to be_nil
    end
  end

  # Prod memory 64: the attribution form went up at 15:04 ("Who did: Puppy
  # Up?"), Rocco typed an unrelated printer command at 15:13, and the compile
  # read them as one exchange — writing down that "Puppy Up" MEANS "print game
  # tray vase". A widget with buttons is not the companion asking a question.
  describe "app widgets that look like conversation" do
    it "keeps a form prompt out of the stretch it reads" do
      say("Who did: Puppy Up?", direction: :inbound, meta: { "kind" => "buddy_reply", "source" => "form" })
      say("print game tray vase")
      say("It's printing.", direction: :inbound, meta: { "kind" => "buddy" })
      client = stub_client({ memories: [] })

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).not_to include("Puppy Up")
    end
  end

  describe "writing what mattered" do
    # The point of the whole thing: one message, several records, each with its
    # own weight and its own timing.
    it "writes every separate thing one message carried" do
      flare
      stub_client({
        memories: [
          { content: "Their CSCR has flared up.", summary: "CSCR flare", kind: "concept",
            severity: 55, tags: %w[health], check_in_days: 3 },
          { content: "They are stressed about it all landing at once.", summary: "Stress",
            kind: "concept", severity: 60, tags: %w[wellbeing], check_in_days: 0 },
          { content: "They will be out of a job before the end of the year.", summary: "Job ending",
            kind: "concept", severity: 85, tags: %w[work], check_in_days: 7 },
        ],
      })

      written = described_class.run!(convo)

      expect(written.size).to eq(3)
      expect(written.map(&:severity)).to contain_exactly(55, 60, 85)
      expect(written.map(&:tag_list).flatten).to contain_exactly("health", "wellbeing", "work")
      expect(written.map(&:kind).uniq).to eq(["followup"])
    end

    it "keeps a plain memory as a memory when nothing needs asking about" do
      flare
      stub_client({
        memories: [
          { content: "They forgot the sleeping bags camping.", kind: "concept",
            severity: 10, tags: %w[camping], check_in_days: nil },
        ],
      })

      written = described_class.run!(convo)

      expect(written.first).to be_kind_concept
      expect(written.first.check_in_at).to be_nil
      expect(written.first.tag_list).to eq(["camping"])
    end

    it "writes nothing when the stretch carried nothing worth keeping" do
      flare
      stub_client({ memories: [] })

      expect(described_class.run!(convo)).to be_empty
      expect(BuddyMemory.where(user: user).count).to eq(0)
    end

    it "clamps a severity outside the scale rather than failing the write" do
      flare
      stub_client({ memories: [{ content: "Something enormous.", severity: 900 }] })

      expect(described_class.run!(convo).first.severity).to eq(100)
    end

    it "does not write the same thing twice across two compiles" do
      flare
      stub_client({ memories: [{ content: "They will be out of a job before the year is out.", severity: 80 }] })
      described_class.run!(convo)

      convo.update_columns(buddy_compile_after: 2.hours.ago, buddy_compiled_at: nil)
      stub_client({ memories: [{ content: "They will be out of a job before the year is out.", severity: 80 }] })

      expect(described_class.run!(convo)).to be_empty
      expect(BuddyMemory.where(user: user).count).to eq(1)
    end

    # Degrading to silence is right: a compile is invisible, so a parse failure
    # should look exactly like a compile that found nothing.
    it "writes nothing and stays quiet when the output can't be parsed" do
      flare
      stub_client("I'm afraid I can't help with that.")

      expect(described_class.run!(convo)).to be_empty
    end

    it "survives the model call failing outright" do
      flare
      fake = FakeBuddyClient.new([{ error: "rate limited" }])
      allow(Buddy::GPT::Client).to receive(:new).and_return(fake)

      expect(described_class.run!(convo)).to be_empty
      expect(convo.reload.buddy_compile_after).to be_nil
    end

    it "clears the flag once it has run, so it doesn't compile the same stretch forever" do
      flare
      stub_client({ memories: [] })

      described_class.run!(convo)

      expect(convo.reload.buddy_compile_after).to be_nil
      expect(convo.reload.buddy_compiled_at).to be_present
    end
  end

  describe "several follow-ups from one stretch" do
    # The compiler has to be able to split a message, and each piece has to keep
    # its OWN weight and its OWN timing. A design that quietly collapses these
    # into one record loses the two that mattered least at write time and most
    # a week later.
    it "gives each thing its own severity, tags and timing" do
      flare
      stub_client({
        memories: [
          { content: "Their CSCR has flared up.", severity: 55, tags: %w[health eyes], check_in_days: 3 },
          { content: "They are stressed by it landing at once.", severity: 60, tags: %w[wellbeing], check_in_days: 0 },
          { content: "They lose their job before the year is out.", severity: 85, tags: %w[work money], check_in_days: 7 },
        ],
      })

      written = described_class.run!(convo).sort_by(&:severity)

      expect(written.map(&:severity)).to eq([55, 60, 85])
      expect(written.map { |m| m.tag_list.sort }).to eq([%w[eyes health], %w[wellbeing], %w[money work]])
      expect(written.map(&:check_in_at)).to all(be_present)
      expect(written.map(&:check_in_at).uniq.size).to eq(3)
    end

    it "spaces them out instead of stacking three onto one evening" do
      flare
      stub_client({
        memories: [
          { content: "Eye thing.", severity: 55, check_in_days: 3 },
          { content: "Stress thing.", severity: 60, check_in_days: 0 },
          { content: "Job thing.", severity: 85, check_in_days: 7 },
        ],
      })

      described_class.run!(convo)

      times = BuddyMemory.where(user: user).order(:check_in_at).pluck(:check_in_at)
      times.each_cons(2) { |a, b| expect(b - a).to be >= Buddy::CheckIns::MIN_GAP }
    end

    it "splits a long unburdening into one record per thing, weighted separately" do
      say("god, today. the car failed its MOT, my sister's finally out of hospital which is a relief, " \
          "and I completely forgot Dan's birthday again")
      say("That's a lot in one day.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_client({
        memories: [
          { content: "Their car failed its MOT.", severity: 30, tags: %w[car], check_in_days: 5 },
          { content: "Their sister is out of hospital.", severity: 50, tags: %w[family health], check_in_days: 2 },
          { content: "They forgot Dan's birthday again and it bothers them.", severity: 20,
            tags: %w[dan], check_in_days: nil },
        ],
      })

      written = described_class.run!(convo)

      expect(written.size).to eq(3)
      expect(written.select(&:check_in_at).size).to eq(2)
      expect(written.find { |m| m.tag_list.include?("dan") }).to be_kind_concept
    end

    it "keeps the mix when only some of them warrant asking about" do
      flare
      stub_client({
        memories: [
          { content: "They use the north door now.", severity: 5, check_in_days: nil },
          { content: "Their mother is having surgery.", severity: 80, relevant_in_days: 6, check_in_days: 7 },
        ],
      })

      written = described_class.run!(convo)

      expect(written.map(&:kind)).to contain_exactly("concept", "followup")
      expect(written.find(&:kind_followup?).relevant_at).to be_present
    end
  end

  describe "an update they volunteered themselves" do
    let!(:mood_check) {
      user.buddy_memories.create!(
        kind: :followup, content: "They had a genuinely rough day.", summary: "Rough day",
        severity: 55, tags: %w[wellbeing], check_in_at: 6.hours.from_now,
      )
    }

    # The worst version of this feature is a companion that asks how you're
    # feeling six hours after you told it.
    it "resolves an emotional check-in when they say how they are first" do
      say("feeling a lot better today actually, the walk helped")
      say("Ah, that's good to hear.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_client({
        memories: [],
        updates:  [{ id: mood_check.id, action: "resolved", note: "Said they felt better after a walk." }],
      })

      described_class.run!(convo)

      expect(mood_check.reload).to be_status_done
      expect(mood_check.check_in_at).to be_nil
      expect(mood_check.notes.map(&:body)).to eq(["Said they felt better after a walk."])
    end

    # "Still in hospital, doing okay for now" is not a resolution.
    it "re-arms one they updated without closing out" do
      say("cat's still in the hospital but she's doing okay for now")
      say("Glad she's stable.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_client({
        memories: [],
        updates:  [{ id: mood_check.id, action: "answered", check_in_days: 2,
                     note: "Cat still in hospital, stable." }],
      })

      described_class.run!(convo)

      expect(mood_check.reload).to be_status_active
      expect(mood_check.check_in_at).to be > 1.day.from_now
      expect(mood_check.notes.first.body).to include("still in hospital")
    end

    it "stops asking when their update reads like the end of it" do
      say("all sorted now, nothing to worry about")
      say("Good.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_client({ memories: [], updates: [{ id: mood_check.id, action: "answered", check_in_days: nil }] })

      described_class.run!(convo)

      expect(mood_check.reload.check_in_at).to be_nil
      expect(mood_check).to be_status_active
    end

    it "drops one that stopped being worth asking about" do
      flare
      stub_client({ memories: [], updates: [{ id: mood_check.id, action: "dropped" }] })

      described_class.run!(convo)

      expect(mood_check.reload).to be_status_dropped
      expect(mood_check.check_in_at).to be_nil
    end

    it "leaves alone the ones the conversation didn't touch" do
      other = user.buddy_memories.create!(
        kind: :followup, content: "The deck project.", severity: 40, check_in_at: 3.days.from_now,
      )
      say("feeling better today")
      stub_client({ memories: [], updates: [{ id: mood_check.id, action: "resolved" }] })

      described_class.run!(convo)

      expect(other.reload.check_in_at).to be_present
      expect(other).to be_status_active
    end

    it "never touches another person's follow-up, whatever id comes back" do
      stranger = create(:user)
      theirs = stranger.buddy_memories.create!(
        kind: :followup, content: "Their own thing.", severity: 60, check_in_at: 1.day.from_now,
      )
      flare
      stub_client({ memories: [], updates: [{ id: theirs.id, action: "dropped" }] })

      described_class.run!(convo)

      expect(theirs.reload).to be_status_active
    end

    it "shows the model what is already pending, by id" do
      flare
      fake = stub_client({ memories: [] })

      described_class.run!(convo)

      expect(fake.calls.first.input.first[:content]).to include("##{mood_check.id}", "Rough day")
    end
  end

  describe "the check-in floor" do
    # Without this, "they prefer big mugs" becomes an unprompted question three
    # days later.
    it "refuses to arm a check-in on something trivial even when one is asked for" do
      flare
      stub_client({ memories: [{ content: "They prefer a big mug.", severity: 5, check_in_days: 3 }] })

      expect(described_class.run!(convo).first.check_in_at).to be_nil
    end

    # Severe now, actionable next week. Asking tomorrow is the failure.
    it "holds a dated thing until it is actually relevant" do
      flare
      stub_client({
        memories: [{ content: "Their mother has surgery next week.", severity: 80,
                     relevant_in_days: 7, check_in_days: 1 }],
      })

      written = described_class.run!(convo).first

      expect(written.relevant_at).to be_within(1.day).of(7.days.from_now)
      expect(written.check_in_at).to be >= written.relevant_at
    end
  end

  describe "the stale face" do
    # Prod 3908: the right words about a health flare and a job loss, delivered
    # wearing `happy`, because the turn emitted no marker and the mood persists
    # until something deliberately changes it.
    it "corrects a face that contradicts what was actually said" do
      convo.update_columns(buddy_expression: "happy")
      flare
      stub_client({ memories: [], face: "sad" })

      described_class.run!(convo)

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "leaves a face alone when it already fits" do
      convo.update_columns(buddy_expression: "sad")
      flare
      stub_client({ memories: [], face: nil })

      described_class.run!(convo)

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "ignores a face that isn't one this pet has" do
      convo.update_columns(buddy_expression: "happy")
      flare
      stub_client({ memories: [], face: "elated_beyond_measure" })

      described_class.run!(convo)

      expect(convo.reload.buddy_expression).to eq("happy")
    end
  end

  describe "what it reads" do
    it "skips hidden seeds, chips and watch-fired posts" do
      flare
      say("hidden seed", meta: { "hidden" => true, "kind" => "buddy_trigger" })
      say("chip", direction: :inbound, meta: { "kind" => "buddy_activity" })
      fake = stub_client({ memories: [] })

      described_class.run!(convo)

      sent = fake.calls.first.input.first[:content]
      expect(sent).to include("CSCR has flared up")
      expect(sent).not_to include("hidden seed", "chip")
    end

    it "shows the model what is already held so it doesn't write a fourth copy" do
      user.buddy_memories.create!(kind: :concept, content: "Their cat is called Fae.", summary: "Cat is Fae")
      flare
      fake = stub_client({ memories: [] })

      described_class.run!(convo)

      expect(fake.calls.first.input.first[:content]).to include("Cat is Fae")
    end

    it "bills its own usage kind rather than muddying turn numbers" do
      flare
      stub_client({ memories: [] })

      expect { described_class.run!(convo) }.to change { BuddyUsage.where(kind: :compile).count }.by(1)
    end
  end
end
