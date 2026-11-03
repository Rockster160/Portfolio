require "rails_helper"

# The background pass that reads a finished stretch and writes down what was
# worth keeping.
RSpec.describe Buddy::Compile do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def say(body, direction: :outbound, at: Time.current, meta: {})
    convo.byte_messages.create!(
      user: user, direction: direction, state: :delivered,
      body: body, metadata: meta, created_at: at,
    )
  end

  # The pass answers with TOOL CALLS now, not a JSON blob — it looks things up,
  # writes, revises and retires across as many rounds as it needs. A round is
  # one array of calls; an empty round (or none) is it saying it's finished.
  def stub_rounds(*rounds)
    scripted = rounds.map { |calls|
      {
        tool_calls: Array(calls).each_with_index.map { |call, i|
          { name: call[:name], call_id: "c#{i}", arguments: call[:args].stringify_keys }
        },
      }
    }
    fake = FakeBuddyClient.new(scripted + [{ text: "done" }])
    allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
    fake
  end

  # One round of calls, then finished — the shape nearly every example wants.
  def stub_calls(*calls) = stub_rounds(calls)

  # No tools at all: it read the stretch and decided nothing had changed.
  def stub_quiet
    fake = FakeBuddyClient.new([{ text: "nothing to keep" }])
    allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
    fake
  end

  def held(content, **args)
    { name: :write_memory, args: { content: content }.merge(args) }
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
    it "sets a target a quarter of an hour out" do
      convo.update_columns(buddy_compile_after: nil)

      described_class.flag!(convo)

      expect(convo.reload.buddy_compile_after).to be_within(1.minute).of(Buddy::Compile::QUIET_PERIOD.from_now)
    end

    # Every message re-flags, so one compile covers a conversation rather than
    # one per message.
    it "pushes the target back when another message lands" do
      # Relative to the period, not a fixed offset: at a 15-minute debounce a
      # target set 30 minutes ago is already due, and the worker runs it inline
      # and clears the flag out from under the assertion.
      described_class.flag!(convo, now: 1.minute.ago)
      first = convo.reload.buddy_compile_after

      described_class.flag!(convo)

      expect(convo.reload.buddy_compile_after).to be > first
    end

    it "does nothing, without touching the model, while the target is ahead or was never set" do
      flare
      expect(Buddy::GPT::Client).not_to receive(:new)

      convo.update_columns(buddy_compile_after: 5.minutes.from_now)
      expect(described_class.run!(convo)).to be_empty

      convo.update_columns(buddy_compile_after: nil)
      expect(described_class.run!(convo)).to be_empty
    end
  end

  # What the pass is handed: the stretch with each line's age, what the
  # companion already carried out (kept out of the conversation itself), and
  # today's date to write dates absolutely from.
  describe "the brief" do
    def brief_for
      client = stub_quiet
      described_class.run!(convo)
      client.calls.first.input.first[:content]
    end

    it "reads older history with its age, and today's date, on a first run", :aggregate_failures do
      travel_to(Time.utc(2026, 8, 25, 18, 0)) do
        # Inside the travel: stamped from the real clock, the target could sit
        # in this example's future.
        convo.update_columns(buddy_compile_after: 2.hours.ago, buddy_compiled_at: nil)
        old = say("I need to leave around 3 to visit Doug.", at: 3.days.ago)
        say("On the calendar for 3:00 PM.", direction: :inbound, at: 3.days.ago, meta: { "kind" => "buddy" })
        say("The fence gate is sticking again.")
        say("Oh, that one.", direction: :inbound, meta: { "kind" => "buddy" })

        brief = brief_for

        expect(brief).to include(old.body)
        expect(brief).to include(3.days.ago.in_time_zone(Buddy::Day.zone(user)).strftime("%a %-d %b"))
        expect(brief).to include("TODAY: Tuesday 25 Aug 2026")
      end
    end

    # A chip is listed under ALREADY DONE so the model can tell a request that
    # was carried out from one that wasn't; it must never be a line in the
    # conversation, where it would vote on what the stretch was about. A form
    # prompt and a hidden seed are not conversation either.
    it "lists what was already done apart from the conversation, and skips widgets and seeds", :aggregate_failures do
      say("Who did: Puppy Up?", direction: :inbound, meta: { "kind" => "buddy_reply", "source" => "form" })
      say("Please remind me every day to let things go.")
      say("Done!! I set that to repeat every day.", direction: :inbound, meta: { "kind" => "buddy" })
      say("Suki will remind you every day at 9am", direction: :inbound, meta: { "kind" => "buddy_activity" })
      say("hidden seed", meta: { "hidden" => true, "kind" => "buddy_trigger" })

      brief = brief_for
      talk  = brief[/THE CONVERSATION:.*/m]

      expect(brief).to include("ALREADY DONE IN THIS STRETCH", "Suki will remind you every day at 9am")
      expect(talk).to include("let things go")
      expect(talk).not_to include("will remind you every day")
      expect(brief).not_to include("Puppy Up", "hidden seed")
    end

    it "says (none) when nothing was done" do
      flare

      expect(brief_for).to match(/ALREADY DONE IN THIS STRETCH[^\n]*\n\(none\)/)
    end

    # Both count days in the PERSON'S zone, as `pending_when` does.
    it "shows every held row by id with its full wording, and pending follow-ups with when and weight", :aggregate_failures do
      concept = user.buddy_memories.create!(kind: :concept, content: "Their cat is called Fae.", summary: "Cat is Fae")
      far     = user.buddy_memories.create!(
        kind: :followup, content: "Far one.", summary: "Rough day", severity: 86,
        check_in_at: user.timezone { 96.days.from_now },
      )
      soon    = user.buddy_memories.create!(
        kind: :followup, content: "Soon one.", summary: "Soon", severity: 40,
        check_in_at: user.timezone { 1.day.from_now.change(hour: 18) },
      )
      armed   = user.buddy_memories.create!(
        kind: :preference, content: "Held inline, and asked about.", summary: "Held and armed",
        severity: 40, check_in_at: 3.days.from_now
      )
      flare

      brief = brief_for

      expect(brief).to match(/- ##{concept.id} \[concept\] Their cat is called Fae\./)
      expect(brief).to include("##{far.id}", "Rough day", "in 96 days", "sev 86")
      expect(brief).to include("##{soon.id}", "[tomorrow,")
      expect(brief).to include("##{armed.id}", "Held and armed")
    end

    it "takes several rounds of looking before it has to be finished" do
      say("Something.")
      say("Mm.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_rounds(*Array.new(3) { [{ name: :read_conversation, args: {} }] })

      expect { described_class.run!(convo) }.not_to raise_error
    end
  end

  # The source stamp has to be where the content actually came from, or absent.
  describe "where a memory says it came from" do
    it "points at the message the content is actually in" do
      origin = say("The fence gate is sticking again and the latch is bent.")
      say("I'll remember that.", direction: :inbound, meta: { "kind" => "buddy" })
      say("I'm off to bed for the night.")
      stub_calls(held("Their fence gate is sticking and the latch is bent.", kind: "concept", severity: 20, tags: %w[home]))

      expect(described_class.run!(convo).first.source_message_id).to eq(origin.id)
    end

    it "leaves it empty rather than pointing somewhere wrong" do
      say("I'm off to bed for the night.")
      say("Night!", direction: :inbound, meta: { "kind" => "buddy" })
      stub_calls(held("Their dentist appointment moved to November.", kind: "concept", severity: 20, tags: %w[health]))

      expect(described_class.run!(convo).first.source_message).to be_nil
    end
  end

  # The inline `remember` path writes immediately, then compile re-reads the
  # same turns, so `duplicate?` is what stops the second write.
  describe ".duplicate?" do
    def duplicate?(text) = described_class.send(:duplicate?, user, text)

    it "matches the same fact across kinds, spacing, -ing and one-word restatements" do
      [
        [:stash, "She is working on kitchen cupboards and wants to keep at it",
         "She is working on kitchen cupboards and wants to keep at it"],
        [:preference, "She avoids the hose when Whisper's naptime is close",
         "She avoids the hose when Whisper's nap time is close"],
        [:stash, "Go through the 2 bins of bathroom and first aid supplies later while we watch TV",
         "Two bins of bathroom and first aid supplies are set aside to sort later while watching TV"],
        [:stash, "Once the bedroom is sorted, clear out the entire pantry", "pantry"],
      ].each { |kind, existing, candidate|
        BuddyMemory.where(user: user).delete_all
        BuddyMemory.create!(user: user, kind: kind, status: :active, content: existing)

        expect(duplicate?(candidate)).to be(true), candidate
      }
    end

    it "lets a genuinely different fact, or a word merely containing a short entry, through" do
      BuddyMemory.create!(user: user, kind: :preference, content: "She checks the schedule when working outside")
      BuddyMemory.create!(user: user, kind: :stash, status: :active, content: "Buy buttermilk for the pancakes")

      expect(duplicate?("She avoids the hose during the last nap of the day")).to be(false)
      expect(duplicate?("milk")).to be(false)
    end

    it "leaves a word alone when stripping -ing would gut it" do
      expect(Buddy::SideEffects.stem("thing")).to eq("thing")
      expect(Buddy::SideEffects.stem("watching")).to eq("watch")
    end

    # A note about a row is not the row.
    it "sees a standing feature request in its own table, but not a shipped one" do
      request = FeatureRequest.create!(user: user, title: "Inventory access", body: "Wants to see what is in stock")
      expect(duplicate?("Rocco needs a feature request for Inventory access")).to be(true)

      request.update!(status: :shipped)
      expect(duplicate?("Rocco needs a feature request for Inventory access")).to be(false)
    end
  end

  # Two rows that turned out to be one thing, or a row that only made sense
  # beside its neighbour, get revised in place.
  describe "tidying what is already held" do
    let!(:held) {
      user.buddy_memories.create!(
        kind: :concept, content: "After that, clear out the pantry.", summary: "Pantry", severity: 10,
      )
    }

    def revise!(row)
      flare
      stub_calls({ name: :revise_memory, args: row })
      described_class.run!(convo)
      held.reload
    end

    it "rewrites a row in place" do
      revise!({
        id: held.id, action: "revised", tags: %w[home],
        content: "Once the bedroom is sorted, clear out the entire pantry.", summary: "Pantry after bedroom",
      })

      expect(held.content).to eq("Once the bedroom is sorted, clear out the entire pantry.")
      expect(held.summary).to eq("Pantry after bedroom")
      expect(held.tag_list).to eq(["home"])
    end

    # A cheap model editing things the person said about themselves. The row is
    # what everything reads, so a bad rewrite is invisible without this.
    it "keeps the wording it replaced on the thread" do
      revise!({ id: held.id, action: "revised", content: "Something quite different." })

      expect(held.notes.map(&:body).join).to include("After that, clear out the pantry.")
    end

    it "ignores a revise with nothing to write, or one that changes nothing" do
      revise!({ id: held.id, action: "revised", content: "  " })
      expect(held.content).to eq("After that, clear out the pantry.")
      expect(held.notes).to be_empty

      convo.update_columns(buddy_compile_after: 2.hours.ago)
      revise!({ id: held.id, action: "revised", content: "After that, clear out the pantry." })
      expect(held.notes).to be_empty
    end
  end

  describe "writing what mattered" do
    it "keeps a plain memory as a memory when nothing needs asking about" do
      flare
      stub_calls(held("They forgot the sleeping bags camping.", kind: "concept", severity: 10, tags: %w[camping]))

      written = described_class.run!(convo)

      expect(written.first).to be_kind_concept
      expect(written.first.check_in_at).to be_nil
      expect(written.first.tag_list).to eq(["camping"])
    end

    # A compile is invisible, so finding nothing just clears the flag.
    it "writes nothing when the stretch carried nothing worth keeping, and clears the flag" do
      flare
      stub_quiet

      expect(described_class.run!(convo)).to be_empty
      expect(BuddyMemory.where(user: user).count).to eq(0)
      expect(convo.reload.buddy_compile_after).to be_nil
      expect(convo.buddy_compiled_at).to be_present
    end

    it "clamps a severity outside the scale rather than failing the write" do
      flare
      stub_calls(held("Something enormous.", severity: 900))

      expect(described_class.run!(convo).first.severity).to eq(100)
    end

    it "does not write the same thing twice across two compiles" do
      flare
      stub_calls(held("They will be out of a job before the year is out.", severity: 80))
      described_class.run!(convo)

      convo.update_columns(buddy_compile_after: 2.hours.ago, buddy_compiled_at: nil)
      stub_calls(held("They will be out of a job before the year is out.", severity: 80))

      expect(described_class.run!(convo)).to be_empty
      expect(BuddyMemory.where(user: user).count).to eq(1)
    end

    it "survives the model call failing outright" do
      flare
      fake = FakeBuddyClient.new([{ error: "rate limited" }])
      allow(Buddy::GPT::Client).to receive(:new).and_return(fake)

      expect(described_class.run!(convo)).to be_empty
      expect(convo.reload.buddy_compile_after).to be_nil
    end
  end

  describe "several follow-ups from one stretch" do
    # One message, several records, each with its own weight and timing.
    it "gives each thing its own severity, tags and spaced-out timing, as follow-ups" do
      flare
      stub_calls(
        held("Their CSCR has flared up.", severity: 55, tags: %w[health eyes], check_in_days: 3),
        held("They are stressed by it landing at once.", severity: 60, tags: %w[wellbeing], check_in_days: 0),
        held("They lose their job before the year is out.", severity: 85, tags: %w[work money], check_in_days: 7),
      )

      written = described_class.run!(convo).sort_by(&:severity)

      expect(written.map(&:severity)).to eq([55, 60, 85])
      expect(written.map { |m| m.tag_list.sort }).to eq([%w[eyes health], %w[wellbeing], %w[money work]])
      expect(written.map(&:check_in_at)).to all(be_present)
      expect(written.map(&:check_in_at).uniq.size).to eq(3)
      expect(written.map(&:kind).uniq).to eq(["followup"])
      written.map(&:check_in_at).sort.each_cons(2) { |a, b| expect(b - a).to be >= Buddy::CheckIns::MIN_GAP }
    end

    it "splits a long unburdening into one record per thing, weighted separately" do
      say("god, today. the car failed its MOT, my sister's finally out of hospital which is a relief, " \
          "and I completely forgot Dan's birthday again")
      say("That's a lot in one day.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_calls(
        held("Their car failed its MOT.", severity: 30, tags: %w[car], check_in_days: 5),
        held("Their sister is out of hospital.", severity: 50, tags: %w[family health], check_in_days: 2),
        held("They forgot Dan's birthday again and it bothers them.", severity: 20,
            tags: %w[dan], check_in_days: nil),
      )

      written = described_class.run!(convo)

      expect(written.size).to eq(3)
      expect(written.select(&:check_in_at).size).to eq(2)
      expect(written.find { |m| m.tag_list.include?("dan") }).to be_kind_concept
    end

    it "keeps the mix when only some of them warrant asking about" do
      flare
      stub_calls(
        held("They use the north door now.", severity: 5, check_in_days: nil),
        held("Their mother is having surgery.", severity: 80, relevant_days: 6, check_in_days: 7),
      )

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
      stub_calls({
        name: :close_memory,
        args: { id: mood_check.id, status: "done", note: "Said they felt better after a walk." },
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
      stub_calls({
        name: :set_check_in,
        args: { id: mood_check.id, days: 2, note: "Cat still in hospital, stable." },
      })

      described_class.run!(convo)

      expect(mood_check.reload).to be_status_active
      expect(mood_check.check_in_at).to be > 1.day.from_now
      expect(mood_check.notes.first.body).to include("still in hospital")
    end

    it "stops asking when their update reads like the end of it" do
      say("all sorted now, nothing to worry about")
      say("Good.", direction: :inbound, meta: { "kind" => "buddy" })
      stub_calls({ name: :set_check_in, args: { id: mood_check.id } })

      described_class.run!(convo)

      expect(mood_check.reload.check_in_at).to be_nil
      expect(mood_check).to be_status_active
    end

    it "drops one that stopped being worth asking about" do
      flare
      stub_calls({ name: :close_memory, args: { id: mood_check.id, status: "dropped" } })

      described_class.run!(convo)

      expect(mood_check.reload).to be_status_dropped
      expect(mood_check.check_in_at).to be_nil
    end

    it "leaves alone the ones the conversation didn't touch" do
      other = user.buddy_memories.create!(
        kind: :followup, content: "The deck project.", severity: 40, check_in_at: 3.days.from_now,
      )
      say("feeling better today")
      stub_calls({ name: :close_memory, args: { id: mood_check.id, status: "done" } })

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
      stub_calls({ name: :close_memory, args: { id: theirs.id, status: "dropped" } })

      described_class.run!(convo)

      expect(theirs.reload).to be_status_active
    end
  end

  describe "the check-in floor" do
    # Without this, "they prefer big mugs" becomes an unprompted question three
    # days later.
    it "refuses to arm a check-in on something trivial even when one is asked for" do
      flare
      stub_calls(held("They prefer a big mug.", severity: 5, check_in_days: 3))

      expect(described_class.run!(convo).first.check_in_at).to be_nil
    end

    # Severe now, actionable next week. Asking tomorrow is the failure.
    it "holds a dated thing until it is actually relevant" do
      flare
      stub_calls(held("Their mother has surgery next week.", severity: 80, relevant_days: 7, check_in_days: 1))

      written = described_class.run!(convo).first

      expect(written.relevant_at).to be_within(1.day).of(7.days.from_now)
      expect(written.check_in_at).to be >= written.relevant_at
    end
  end

  # The face belongs to the live turn; an async pass changing it would change
  # it out of nowhere.
  it "has no face tool, and leaves the expression where the conversation left it" do
    expect(described_class::Toolbox.schemas.map { |t| t[:name] }).not_to include("set_face")
    convo.update_columns(buddy_expression: "happy")
    flare
    stub_calls({ name: :set_face, args: { face: "sad" } })

    described_class.run!(convo)

    expect(convo.reload.buddy_expression).to eq("happy")
  end

  it "bills its own usage kind rather than muddying turn numbers" do
    flare
    stub_quiet

    expect { described_class.run!(convo) }.to change { BuddyUsage.where(kind: :compile).count }.by(1)
  end

  # The pass writes stored facts, so a sample circumstance in its instructions
  # can be filed against somebody as a real one.
  it "hands the pass no circumstance it could file as a real one" do
    planted = [
      "I'm out of a job on 11 Sep",
      "The layoff is happening sooner than we thought",
      "her surgery is in three weeks",
      "she's still in hospital, doing okay for now",
      "forgot the sleeping bags",
      "clear out the pantry",
      "that's in the house words too",
      "do not remind her about this",
      "check on this next week",
    ]

    expect(planted.select { |line| described_class::INSTRUCTIONS.include?(line) }).to be_empty
  end
end
