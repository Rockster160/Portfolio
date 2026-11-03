require "rails_helper"

RSpec.describe "Buddy idea threads" do
  # A held idea you can come back to: the seed stays as it was said, and each
  # later visit lands as a note on it.
  describe "threads" do
    let(:user)  { User.me }
    let(:convo) { user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }

    def ctx = Buddy::ToolContext.new(user)

    def idea!(body, summary: nil, status: :active, created: 3.days.ago, category: :home)
      BuddyMemory.create!(
        kind:     :stash,
        user: user, content: body, summary: summary, status: status,
        category: category, created_at: created, last_touched_at: created
      )
    end

    def elaborate(payload)
      tool = Buddy::Tools[:elaborate_idea]
      confirm = tool[:confirm].call(payload, ctx)
      [tool[:execute].call(payload.merge(confirm[:resolved]), ctx), confirm]
    end

    def answer(name, payload={})
      Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[name],
        { call_id: "call_1", name: name, arguments: payload },
        user: user, conversation: convo,
      )
    end

    # Ages are counted in local calendar days, so a clock near midnight or a DST
    # change would move "10.days.ago" onto a different day.
    around { |example| travel_to(Time.utc(2026, 9, 16, 18, 0)) { example.run } }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(ActionCable.server).to receive(:broadcast)
      BuddyMemory.where(user: user).destroy_all
    end

    describe "elaborate_idea" do
      # last_touched_at is when the PERSON last put something in, which is what
      # says whether a thread is alive; updated_at moves for bookkeeping too.
      it "stacks notes oldest-first without touching the seed, and moves last_touched_at", :aggregate_failures do
        idea = idea!("slime colony game", created: 40.days.ago)
        expect(idea.thread_label).to be_nil

        result, = elaborate({ id: idea.id, note: "passive idle mechanic" })
        elaborate({ id: idea.id, note: "colonies should merge" })

        expect(result[:count]).to eq(1)
        idea.reload
        expect(idea.content).to eq("slime colony game")
        expect(idea.notes.map(&:body)).to eq(["passive idle mechanic", "colonies should merge"])
        expect(idea.last_touched_at).to be_within(5.seconds).of(Time.current)
        expect(idea.thread_label).to eq("2 notes, last today")
      end

      it "marks a companion note as yours so it is never read back as theirs" do
        idea = idea!("basement lights")

        elaborate({ id: idea.id, note: "they keep circling the wiring cost", mine: true })

        expect(idea.reload.notes.first).to be_from_companion
        expect(idea.transcript).to include("[you, today] they keep circling the wiring cost")
      end

      # Coming back to something they'd closed out is them picking it back up.
      # Leaving it done means the note lands somewhere they will never see again.
      it "reopens a finished thread" do
        idea = idea!("call the roofer", status: :done)

        elaborate({ id: idea.id, note: "he never called back" })

        expect(idea.reload).to be_status_active
      end

      it "hands back an undo that removes just that note" do
        idea = idea!("greenhouse")
        elaborate({ id: idea.id, note: "first thought" })
        result, = elaborate({ id: idea.id, note: "mistyped nonsense" })

        expect(Buddy::Reverter.reversible?(result[:revert])).to be(true)
        Buddy::Reverter.call(result[:revert])

        expect(idea.reload.notes.map(&:body)).to eq(["first thought"])
      end

      it "refuses an id that isn't theirs, or an empty note", :aggregate_failures do
        theirs = BuddyMemory.create!(kind: :stash, user: create(:user), content: "not mine", status: :active)
        idea = idea!("greenhouse")
        tool = Buddy::Tools[:elaborate_idea]

        expect { tool[:confirm].call({ id: theirs.id, note: "x" }, ctx) }.to raise_error(RuntimeError)
        expect { tool[:confirm].call({ id: idea.id, note: "  " }, ctx) }.to raise_error(RuntimeError)
        expect(theirs.notes.count).to eq(0)
      end
    end

    describe "read_idea" do
      # The frame around an answer beats the answer's own keys, so a payload
      # reporting its own `state` can't overwrite the flag that says the lookup
      # worked.
      it "hands back the seed and every note, oldest first, as answered" do
        idea = idea!("greenhouse needs sorting", summary: "Greenhouse plan", created: 10.days.ago)
        elaborate({ id: idea.id, note: "solar would be cheaper" })
        elaborate({ id: idea.id, note: "check the south wall" })

        out = answer(:read_idea, { id: idea.id })

        expect(out[:status]).to eq(:answered)
        expect(out[:state]).to eq("active")
        expect(out[:label]).to eq("Greenhouse plan")
        expect(out[:note_count]).to eq(2)
        expect(out[:thread]).to include("[seed, 10 days] greenhouse needs sorting")
        expect(out[:thread].index("solar would be cheaper")).to be < out[:thread].index("check the south wall")
      end

      it "reports nothing found for an id that isn't there" do
        expect(answer(:read_idea, { id: 999_999 })[:found]).to be(false)
      end
    end

    describe "search_ideas" do
      # The words somebody remembers about a long thread are usually in what they
      # added later, not in the sentence that started it.
      it "matches the seed, the summary, and note text, requiring every word", :aggregate_failures do
        by_seed    = idea!("sort out the greenhouse solar panels")
        by_summary = idea!("something else", summary: "Greenhouse wiring")
        by_note    = idea!("that garden thing")
        elaborate({ id: by_note.id, note: "hydroponics in the greenhouse" })
        idea!("unrelated pile")

        out = answer(:search_ideas, { query: "greenhouse" })
        expect(out[:total]).to eq(3)
        expect(out[:ideas].join(" ")).to include("##{by_seed.id}", "##{by_summary.id}", "##{by_note.id}")

        out = answer(:search_ideas, { query: "greenhouse solar" })
        expect(out[:total]).to eq(1)
        expect(out[:ideas].first).to include("##{by_seed.id}")
      end

      # Somebody asking about an old thought rarely remembers whether they ever
      # closed it out, so closed ones are in by default.
      it "includes finished and dropped threads by default" do
        idea!("done thing", status: :done)
        idea!("dropped thing", status: :dropped)

        expect(answer(:search_ideas, { query: "thing" })[:total]).to eq(2)
        expect(answer(:search_ideas, { query: "thing", open_only: true })[:total]).to eq(0)
      end

      it "can narrow to the ones actually being built on" do
        plain = idea!("never revisited")
        thread = idea!("kept coming back")
        elaborate({ id: thread.id, note: "more" })

        out = answer(:search_ideas, { threads_only: true })

        expect(out[:ideas].join(" ")).to include("##{thread.id}")
        expect(out[:ideas].join(" ")).not_to include("##{plain.id}")
      end

      it "orders by most recently touched, not by age" do
        old_thread = idea!("older seed", created: 30.days.ago)
        idea!("newer seed", created: 1.day.ago)
        elaborate({ id: old_thread.id, note: "just added to this" })

        out = answer(:search_ideas, {})

        expect(out[:ideas].first).to include("##{old_thread.id}")
      end

      it "does not reach another person's pile" do
        other = create(:user)
        BuddyMemory.create!(kind: :stash, user: other, content: "their private greenhouse thought", status: :active)

        expect(answer(:search_ideas, { query: "greenhouse" })[:total]).to eq(0)
      end

      # A bare `%` reaching ILIKE unescaped matches every row, which would turn a
      # typo into "here is your entire history".
      it "treats SQL wildcards as literal characters" do
        idea!("100% done with this")
        idea!("no percent sign here")

        expect(answer(:search_ideas, { query: "100%" })[:total]).to eq(1)
        expect(answer(:search_ideas, { query: "%" })[:total]).to eq(1)
        expect(answer(:search_ideas, { query: "_" })[:total]).to eq(0)
      end
    end

    describe "the prompt's held-items block" do
      let(:prompt) { Buddy::Personality.for(user, conversation: convo) }

      it "reports a thread by what's in it rather than by how long it has sat" do
        idea = idea!("greenhouse", summary: "Greenhouse plan", created: 21.days.ago)
        elaborate({ id: idea.id, note: "solar" })
        elaborate({ id: idea.id, note: "south wall" })

        expect(prompt).to include("`##{idea.id}` (home, 2 notes, last today) Greenhouse plan")
      end

      it "still reports a plain held item by age" do
        idea = idea!("one-liner", created: 3.days.ago)

        expect(prompt).to include("`##{idea.id}` (home, 3 days) one-liner")
      end
    end

    describe "the stashed_ideas context section" do
      it "carries a note count only for threads" do
        plain  = idea!("plain one")
        thread = idea!("thread one")
        elaborate({ id: thread.id, note: "more" })

        rows = Buddy::Context.full(user, convo)[:stashed_ideas]

        expect(rows.find { |r| r[:id] == plain.id }).not_to have_key(:notes)
        expect(rows.find { |r| r[:id] == thread.id }[:notes]).to eq(1)
        expect(rows.find { |r| r[:id] == thread.id }[:last_touched]).to eq("1 note, last today")
      end
    end
  end

  describe "the open-loops block" do
    let(:user) { create(:user) }

    # The subject is only checkable if it's on the line, so the block prints
    # the idea's own summary.
    it "prints each idea's own summary, and costs nothing for someone holding none", :aggregate_failures do
      user.buddy_memories.create!(
        kind:     :stash,
        content:  "Glimmer iPad idea: control lights, playlist, projector, big button for mode",
        summary:  "Glimmer iPad controls",
        category: :home,
        status:   :active,
      )

      expect(Buddy::Personality.open_loops_block(user)).to include("Glimmer iPad controls")
      expect(Buddy::Personality.open_loops_block(create(:user))).to be_nil
    end
  end
end
