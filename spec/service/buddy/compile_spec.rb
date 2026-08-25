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

    it "does nothing while the target is still ahead, without touching the model" do
      convo.update_columns(buddy_compile_after: 5.minutes.from_now)
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

  # Suki's first run on 19 Aug reached back three days and wrote two memories
  # off things asked for, actioned and finished at the time — a 3pm errand
  # became an undated permanent concept saying she visits Doug at 3pm forever.
  #
  # The fix used to be a six-hour floor on how far a first run could read. That
  # was a guess about meaning made from a clock, and it cut real context off
  # conversations people had simply come back to. What replaces it is showing
  # the model what it needs to make the judgement itself: how old each line is,
  # and what was actually carried out.
  describe "a first run on a thread with history behind it" do
    it "reads the older exchange rather than cutting it off" do
      old = say("I need to leave around 3 to visit Doug.", at: 3.days.ago)
      say("On the calendar for 3:00 PM.", direction: :inbound, at: 3.days.ago, meta: { "kind" => "buddy" })
      say("The fence gate is sticking again.")
      say("Oh, that one.", direction: :inbound, meta: { "kind" => "buddy" })
      convo.update_columns(buddy_compiled_at: nil)
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).to include(old.body)
    end

    it "shows how old it is, so a three-day-old errand reads as one" do
      say("I need to leave around 3 to visit Doug.", at: 3.days.ago)
      say("On the calendar for 3:00 PM.", direction: :inbound, at: 3.days.ago, meta: { "kind" => "buddy" })
      say("The fence gate is sticking again.")
      convo.update_columns(buddy_compiled_at: nil)
      client = stub_quiet

      described_class.run!(convo)

      stamp = 3.days.ago.in_time_zone(Buddy::Day.zone(user)).strftime("%a %-d %b")
      expect(client.calls.first.input.first[:content]).to include(stamp)
    end

    # And it can go looking rather than deciding from what it was handed:
    # `read_conversation` pages backwards as many times as it takes.
    it "is told to page back until it has the part that explains things" do
      flare
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.instructions).to match(/GO AND LOOK before you write/)
      expect(client.calls.first.instructions).to match(/paging back with `before`/)
      expect(client.calls.first.instructions).to match(/Deciding from half a\s+conversation/)
    end

    it "takes several rounds of looking before it has to be finished" do
      say("Something.")
      say("Mm.", direction: :inbound, meta: { "kind" => "buddy" })
      rounds = Array.new(3) { [{ name: :read_conversation, args: {} }] }
      stub_rounds(*rounds)

      expect { described_class.run!(convo) }.not_to raise_error
    end

    # The rule that keeps the Suki case from recurring now that the window
    # doesn't: a dated one-off already dealt with is nothing to keep.
    it "is told a dated one-off that has been and gone is nothing" do
      flare
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.instructions).to include("A CLOCK TIME OR A DATE MEANS IT IS NOT A CONCEPT")
      expect(client.calls.first.instructions).to match(/already been and gone/)
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

  # Prod memory 64: the attribution form went up at 15:04 ("Who did: Puppy
  # Up?"), Rocco typed an unrelated printer command at 15:13, and the compile
  # read them as one exchange — writing down that "Puppy Up" MEANS "print game
  # tray vase". A widget with buttons is not the companion asking a question.
  describe "app widgets that look like conversation" do
    it "keeps a form prompt out of the stretch it reads" do
      say("Who did: Puppy Up?", direction: :inbound, meta: { "kind" => "buddy_reply", "source" => "form" })
      say("print game tray vase")
      say("It's printing.", direction: :inbound, meta: { "kind" => "buddy" })
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).not_to include("Puppy Up")
    end
  end

  # A memory told to write dates absolutely needs a date to write them from.
  # `buddy_memories` 105 froze "tomorrow at 10:00 AM" into a row with no expiry
  # and a check-in the following evening; the pass runs an hour after the
  # conversation ends and the only clock in the brief was the timestamp on each
  # transcript line.
  it "tells the pass what day it is" do
    travel_to(Time.utc(2026, 8, 25, 18, 0)) do
      # Inside the travel, not in the `before` hook. Out there it is stamped
      # from the real clock, so once the wall clock passed 8pm UTC the target
      # sat in this example's FUTURE, run! returned early, and a test that had
      # been green all day started failing for reasons that had nothing to do
      # with it.
      convo.update_columns(buddy_compile_after: 2.hours.ago)
      say("Eve's therapist thing is tomorrow at 10.")
      say("Noted.", direction: :inbound, meta: { "kind" => "buddy" })
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).to include("TODAY: Tuesday 25 Aug 2026")
    end
  end

  # Prod memory 67: Eve asked for a daily nudge, Suki set the reminder and
  # posted a receipt saying so, and the compile — which never sees receipts —
  # wrote "she wants a daily reminder to let things go" as a standing
  # preference. The same request now existed twice, and the copy in memories had
  # no way to be cancelled when she changed her mind about the real one.
  describe "things the companion already handled" do
    it "shows the model what it did, even though receipts stay out of the transcript" do
      say("Please remind me every day to let things go.")
      say("Done!! I set that to repeat every day.", direction: :inbound, meta: { "kind" => "buddy" })
      say("Suki will remind you every day at 9am", direction: :inbound, meta: { "kind" => "buddy_activity" })
      client = stub_quiet

      described_class.run!(convo)

      brief = client.calls.first.input.first[:content]
      expect(brief).to include("ALREADY DONE IN THIS STRETCH")
      expect(brief).to include("Suki will remind you every day at 9am")
      # Still not part of the conversation it reads — that filter is what stops
      # a doorbell notification voting on the subject.
      expect(brief[/THE CONVERSATION:.*/m]).not_to include("will remind you every day")
    end

    it "says a carried-out request is not a preference" do
      say("Anything at all.")
      say("Sure.", direction: :inbound, meta: { "kind" => "buddy" })
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.instructions).to include("A REQUEST THAT WAS CARRIED OUT IS NOT A PREFERENCE")
    end

    it "says so plainly when nothing was done" do
      flare
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).to match(/ALREADY DONE IN THIS STRETCH[^\n]*\n\(none\)/)
    end
  end

  # Three rows in prod carried handling instructions instead of facts: a
  # correction stored after it had been applied, a sentence leaning on the row
  # beside it, and a "don't remind her about this" that nothing could act on.
  # Content is handed over as something TRUE ABOUT THE PERSON, so anything else
  # comes back out as a claim about them and the thing it asked for never
  # happens.
  # Suki told Eve three things once and remembered each of them twice: the
  # inline `remember` path writes immediately, then compile re-reads the same
  # turns half an hour later. `duplicate?` is what should have caught the second
  # write, and it had two holes.
  describe ".duplicate?" do
    it "sees a stash row, which is how 88 got written over an identical 84" do
      BuddyMemory.create!(user: user, kind: :stash, status: :active,
                          content: "She is working on kitchen cupboards and wants to keep at it")

      expect(described_class.send(:duplicate?, user, "She is working on kitchen cupboards and wants to keep at it"))
        .to be(true)
    end

    it "reads naptime and nap time as the same fact" do
      BuddyMemory.create!(user: user, kind: :preference,
                          content: "She avoids the hose when Whisper's naptime is close")

      expect(described_class.send(:duplicate?, user, "She avoids the hose when Whisper's nap time is close"))
        .to be(true)
    end

    it "still lets a genuinely different fact through" do
      BuddyMemory.create!(user: user, kind: :preference, content: "She checks the schedule when working outside")

      expect(described_class.send(:duplicate?, user, "She avoids the hose during the last nap of the day"))
        .to be(false)
    end

    # Memories 92 and 99, both on the pile, one job. "watch" against "watching"
    # was the whole of the difference and it put the overlap at 0.778, under
    # the gate by a fifth of a word.
    it "reads watch and watching as the same word" do
      BuddyMemory.create!(user: user, kind: :stash, status: :active,
                          content: "Go through the 2 bins of bathroom and first aid supplies later while we watch TV")

      expect(
        described_class.send(
          :duplicate?, user,
          "Two bins of bathroom and first aid supplies are set aside to sort later while watching TV",
        ),
      ).to be(true)
    end

    it "leaves a word alone when stripping -ing would gut it" do
      expect(Buddy::SideEffects.stem("thing")).to eq("thing")
      expect(Buddy::SideEffects.stem("watching")).to eq("watch")
    end

    # Memory 97, written half an hour after feature request 1 was created with
    # a receipt chip saying so. A note about a row is not the row.
    it "sees a feature request that already exists in its own table" do
      FeatureRequest.create!(user: user, title: "Inventory access", body: "Wants to see what is in stock")

      expect(described_class.send(:duplicate?, user, "Rocco needs a feature request for Inventory access"))
        .to be(true)
    end

    it "does not read a shipped request as still standing" do
      FeatureRequest.create!(user: user, title: "Inventory access", body: "x", status: :shipped)

      expect(described_class.send(:duplicate?, user, "Rocco needs a feature request for Inventory access"))
        .to be(false)
    end

    # Memory 91 was the single word "pantry", written off "Keep the pantry on
    # the stash pile" - a sentence asking to KEEP memory 60. Too short for the
    # string tests, which used to answer false and let it through.
    it "catches a one-word restatement of something already held" do
      BuddyMemory.create!(user: user, kind: :stash, status: :active,
                          content: "Once the bedroom is sorted, clear out the entire pantry")

      expect(described_class.send(:duplicate?, user, "pantry")).to be(true)
    end

    it "does not let a short entry collide with a word that merely contains it" do
      BuddyMemory.create!(user: user, kind: :stash, status: :active, content: "Buy buttermilk for the pancakes")

      expect(described_class.send(:duplicate?, user, "milk")).to be(false)
    end
  end

  describe "what a row is allowed to be" do
    let(:instructions) {
      say("Anything at all.")
      say("Sure.", direction: :inbound, meta: { "kind" => "buddy" })
      client = stub_quiet
      described_class.run!(convo)
      client.calls.first.instructions
    }

    it "requires every row to make sense with nothing beside it" do
      expect(instructions).to include("EVERY ROW HAS TO STAND ALONE")
      expect(instructions).to match(/never read in order, never read\s+beside each other/)
    end

    it "forbids storing an instruction where a fact belongs" do
      expect(instructions).to include("WRITE THE FACT, NOT A NOTE ABOUT THE FACT")
      expect(instructions).to match(/nothing reads content and acts on it/)
    end

    it "says a correction is applied rather than kept" do
      expect(instructions).to include("A CORRECTION IS NOT A MEMORY")
      expect(instructions).to match(/written once,\s+correctly/)
    end

    # It has no tools — `distill` sends instructions and input and nothing
    # else — so a rule that ends "go and do it" would leave it stuck. Its two
    # levers are `check_in_days` and `updates`, and it has to be told so.
    # It has real tools now, so the rule has to point at them rather than at a
    # JSON field that no longer exists.
    it "points each forbidden shape at the tool that handles it" do
      expect(instructions).to match(/something to come back to is `set_check_in`/)
      expect(instructions).to match(/no longer worth holding is `close_memory`/)
      expect(instructions).to match(/row that is wrong is `revise_memory`/)
    end
  end

  # Until now this pass could only ADD and retire. Two rows that turned out to
  # be one thing, or a row that only made sense beside its neighbour, had no way
  # to be fixed — so the pile could only ever grow more tangled.
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

    it "ignores a revise with nothing to write" do
      revise!({ id: held.id, action: "revised", content: "  " })

      expect(held.content).to eq("After that, clear out the pantry.")
      expect(held.notes).to be_empty
    end

    it "leaves an unchanged row alone rather than noting a no-op" do
      revise!({ id: held.id, action: "revised", content: "After that, clear out the pantry." })

      expect(held.notes).to be_empty
    end

    # Consolidation is a revise plus a drop, so it needs to be able to name both.
    it "shows every held row with its id and full wording" do
      flare
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.input.first[:content]).to match(/- ##{held.id} \[concept\] After that, clear out the pantry\./)
    end

    it "tells the model to tidy only what this conversation touched" do
      flare
      client = stub_quiet

      described_class.run!(convo)

      expect(client.calls.first.instructions).to include("TIDY WHAT IS ALREADY THERE")
      expect(client.calls.first.instructions).to match(/Only\s+revise when THIS conversation gave you a reason to/)
    end
  end

  describe "writing what mattered" do
    # The point of the whole thing: one message, several records, each with its
    # own weight and its own timing.
    it "writes every separate thing one message carried" do
      flare
      stub_calls(
        held("Their CSCR has flared up.", summary: "CSCR flare", kind: "concept", severity: 55, tags: %w[health], check_in_days: 3),
        held("They are stressed about it all landing at once.", summary: "Stress", kind: "concept", severity: 60, tags: %w[wellbeing], check_in_days: 0),
        held("They will be out of a job before the end of the year.", summary: "Job ending", kind: "concept", severity: 85, tags: %w[work], check_in_days: 7),
      )

      written = described_class.run!(convo)

      expect(written.size).to eq(3)
      expect(written.map(&:severity)).to contain_exactly(55, 60, 85)
      expect(written.map(&:tag_list).flatten).to contain_exactly("health", "wellbeing", "work")
      expect(written.map(&:kind).uniq).to eq(["followup"])
    end

    it "keeps a plain memory as a memory when nothing needs asking about" do
      flare
      stub_calls(held("They forgot the sleeping bags camping.", kind: "concept", severity: 10, tags: %w[camping]))

      written = described_class.run!(convo)

      expect(written.first).to be_kind_concept
      expect(written.first.check_in_at).to be_nil
      expect(written.first.tag_list).to eq(["camping"])
    end

    it "writes nothing when the stretch carried nothing worth keeping" do
      flare
      stub_quiet

      expect(described_class.run!(convo)).to be_empty
      expect(BuddyMemory.where(user: user).count).to eq(0)
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

    # Degrading to silence is right: a compile is invisible, so a parse failure
    # should look exactly like a compile that found nothing.
    it "writes nothing and stays quiet when the output can't be parsed" do
      flare
      stub_quiet

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
      stub_quiet

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
    end

    it "spaces them out instead of stacking three onto one evening" do
      flare
      stub_calls(
        held("Eye thing.", severity: 55, check_in_days: 3),
        held("Stress thing.", severity: 60, check_in_days: 0),
        held("Job thing.", severity: 85, check_in_days: 7),
      )

      described_class.run!(convo)

      times = BuddyMemory.where(user: user).order(:check_in_at).pluck(:check_in_at)
      times.each_cons(2) { |a, b| expect(b - a).to be >= Buddy::CheckIns::MIN_GAP }
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

    it "shows the model what is already pending, by id" do
      flare
      fake = stub_quiet

      described_class.run!(convo)

      expect(fake.calls.first.input.first[:content]).to include("##{mood_check.id}", "Rough day")
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


  # An async job an hour — or fifteen minutes — after the conversation ended
  # has no business changing how the companion looks. The face belongs to the
  # live turn: set from here it would change out of nowhere, while the person is
  # somewhere else entirely, about something they have stopped thinking about.
  describe "the face" do
    it "is not something this pass can touch at all" do
      expect(described_class::Toolbox.schemas.map { |t| t[:name] }).not_to include("set_face")
      expect(described_class).not_to respond_to(:apply_face)
    end

    it "leaves the expression exactly where the conversation left it" do
      convo.update_columns(buddy_expression: "happy")
      flare
      stub_calls({ name: :set_face, args: { face: "sad" } })

      described_class.run!(convo)

      expect(convo.reload.buddy_expression).to eq("happy")
    end
  end

  describe "what it reads" do
    # A chip is still not somebody talking — it just isn't invisible any more.
    # It's listed under ALREADY DONE so the model can tell a request that was
    # carried out from one that wasn't; what it must never be is a line in the
    # conversation, where it would vote on what the stretch was about.
    it "skips hidden seeds, chips and watch-fired posts" do
      flare
      say("hidden seed", meta: { "hidden" => true, "kind" => "buddy_trigger" })
      say("chip", direction: :inbound, meta: { "kind" => "buddy_activity" })
      fake = stub_quiet

      described_class.run!(convo)

      sent = fake.calls.first.input.first[:content]
      talk = sent[/THE CONVERSATION:.*/m]
      expect(sent).to include("CSCR has flared up")
      expect(sent).not_to include("hidden seed")
      expect(talk).not_to include("chip")
    end

    # Full wording rather than the summary label: overlap can't be judged off
    # "Cat is Fae", and a row can't be revised without seeing what it says.
    it "shows the model what is already held so it doesn't write a fourth copy" do
      user.buddy_memories.create!(kind: :concept, content: "Their cat is called Fae.", summary: "Cat is Fae")
      flare
      fake = stub_quiet

      described_class.run!(convo)

      expect(fake.calls.first.input.first[:content]).to include("Their cat is called Fae.")
    end

    it "bills its own usage kind rather than muddying turn numbers" do
      flare
      stub_quiet

      expect { described_class.run!(convo) }.to change { BuddyUsage.where(kind: :compile).count }.by(1)
    end
  end
end
