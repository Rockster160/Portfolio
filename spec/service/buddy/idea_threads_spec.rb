require "rails_helper"

RSpec.describe "Buddy idea threads" do
  # A held idea you can come back to.
  #
  # A BuddyMemory used to be one immutable `body`, so the second and third visits to
  # a thought had nowhere to land — stash_idea dedupes on lowercased body, so
  # re-saying it merged onto the original row and the new detail was dropped on
  # the floor. Notes are the place it lands now.
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

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(ActionCable.server).to receive(:broadcast)
      BuddyMemory.where(user: user).destroy_all
    end

    describe "elaborate_idea" do
      it "adds a note without touching the seed" do
        idea = idea!("greenhouse needs sorting out")

        result, confirm = elaborate({ id: idea.id, note: "should probably be solar" })

        expect(confirm[:summary]).to include("greenhouse needs sorting out")
        expect(result[:count]).to eq(1)
        expect(idea.reload.content).to eq("greenhouse needs sorting out")
        expect(idea.notes.map(&:body)).to eq(["should probably be solar"])
      end

      it "stacks notes oldest-first across separate visits" do
        idea = idea!("slime colony game")

        elaborate({ id: idea.id, note: "passive idle mechanic" })
        elaborate({ id: idea.id, note: "colonies should merge" })
        elaborate({ id: idea.id, note: "maybe a prestige loop" })

        expect(idea.reload.notes.map(&:body))
          .to eq(["passive idle mechanic", "colonies should merge", "maybe a prestige loop"])
      end

      # updated_at moves for bookkeeping (a summary rewrite, a recategorize).
      # last_touched_at answers a different question: when the PERSON last put
      # something in, which is what says whether a thread is alive.
      it "moves last_touched_at, which is what makes a thread read as alive" do
        idea = idea!("old thought", created: 40.days.ago)
        expect(idea.thread_label).to be_nil

        elaborate({ id: idea.id, note: "still thinking about this" })

        expect(idea.reload.last_touched_at).to be_within(5.seconds).of(Time.current)
        expect(idea.thread_label).to eq("1 note, last today")
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

      it "refuses an id that isn't theirs" do
        theirs = BuddyMemory.create!(kind: :stash, user: create(:user), content: "not mine", status: :active)
        tool = Buddy::Tools[:elaborate_idea]

        expect { tool[:confirm].call({ id: theirs.id, note: "x" }, ctx) }.to raise_error(/no held idea/)
      end

      it "refuses an empty note" do
        idea = idea!("greenhouse")
        tool = Buddy::Tools[:elaborate_idea]

        expect { tool[:confirm].call({ id: idea.id, note: "  " }, ctx) }.to raise_error(/nothing to add/)
      end
    end

    describe "read_idea" do
      it "settles in the turn rather than leaving a row to tap" do
        expect(Buddy::Tools.answers?(Buddy::Tools[:read_idea])).to be(true)
      end

      # The frame around an answer beats the answer's own keys. A tool reporting
      # something it happens to call `status` must not be able to overwrite the
      # flag that says the lookup worked.
      it "cannot have its answered flag overwritten by its own payload" do
        idea = idea!("anything")

        out = answer(:read_idea, { id: idea.id })

        expect(out[:status]).to eq(:answered)
        expect(out[:note]).to include("what's above is what came back")
      end

      it "hands back the seed and every note, oldest first" do
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

      it "says plainly when there is nothing there rather than inventing one" do
        out = answer(:read_idea, { id: 999_999 })

        expect(out[:found]).to be(false)
        expect(out[:how]).to include("don't invent one")
      end

      it "warns the model off implying history a bare seed doesn't have" do
        idea = idea!("one-liner")

        out = answer(:read_idea, { id: idea.id })

        expect(out[:note_count]).to eq(0)
        expect(out[:how]).to include("Don't imply")
      end
    end

    describe "search_ideas" do
      it "settles in the turn rather than leaving a row to tap" do
        expect(Buddy::Tools.answers?(Buddy::Tools[:search_ideas])).to be(true)
      end

      # The words somebody remembers about a long thread are usually in what they
      # added later, not in the sentence that started it.
      it "matches on note text, not just the seed" do
        idea = idea!("that garden thing")
        elaborate({ id: idea.id, note: "hydroponics might be the answer" })
        idea!("unrelated pile")

        out = answer(:search_ideas, { query: "hydroponics" })

        expect(out[:total]).to eq(1)
        expect(out[:ideas].first).to include("##{idea.id}")
      end

      it "matches the seed and the summary too" do
        a = idea!("sort out the greenhouse")
        b = idea!("something else", summary: "Greenhouse wiring")

        out = answer(:search_ideas, { query: "greenhouse" })

        expect(out[:total]).to eq(2)
        expect(out[:ideas].join(" ")).to include("##{a.id}").and include("##{b.id}")
      end

      it "requires every word, so two terms narrow rather than widen" do
        idea!("greenhouse solar panels")
        idea!("greenhouse water butt")

        expect(answer(:search_ideas, { query: "greenhouse" })[:total]).to eq(2)
        expect(answer(:search_ideas, { query: "greenhouse solar" })[:total]).to eq(1)
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

      it "tells the model that empty is the answer" do
        out = answer(:search_ideas, { query: "nothing like this exists" })

        expect(out[:ideas]).to be_empty
        expect(out[:how]).to include("Nothing matched, and that IS the answer")
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

      it "sends the model to read_idea before it speaks about a thread" do
        idea!("anything")

        expect(prompt).to include("Anything tagged with a note count is a THREAD")
        expect(prompt).to include("`read_idea` it")
        expect(prompt).to include("that's `elaborate_idea` and NOT a second `stash_idea`")
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

  # Prod 3350. "What were the buttons I wanted to add to Whisper's app?" was
  # answered "Lights, playlist, projector, and a big mode button" — which is a
  # different idea entirely, stashed three hours earlier, that names another
  # subject on its own summary line. There was no held idea about that app at all.
  #
  # The question named a subject and the answer matched a shape: one held idea was
  # about buttons, so it became the answer to a question about buttons. The right
  # answer was the one Buddy gave on the retry — nothing on that one, and here's
  # what the buttons one actually was.
  #
  # `search_ideas` already tells the model that nothing matching IS the answer.
  # The list carried in every prompt said nothing of the kind, and that list is
  # where this was answered from — no tool was called on the turn at all.
  #
  # The first fix wrote the whole incident into the prompt, both real names
  # included, as the illustration of what not to do. That is the one thing this
  # codebase has learned repeatedly not to do: every concrete example ever put in
  # a prompt here came back out of it, and a rule whose example pairs two real
  # subjects hands the model that pairing. Rewritten as a shape, and this file is
  # what keeps the names out.
  describe "matching a thread by subject" do
    let(:user) { create(:user) }

    def block
      Buddy::Personality.open_loops_block(user)
    end

    before do
      user.buddy_memories.create!(
        kind:     :stash,
        content:     "Glimmer iPad idea: control lights, playlist, projector, big button for mode",
        summary:  "Glimmer iPad controls",
        category: :home,
        status:   :active,
      )
    end

    it "tells the model the named thing has to be in the idea" do
      expect(block).to match(/that name has to appear in the idea itself/i)
    end

    it "says why the wrong one is unrecoverable rather than merely wrong" do
      expect(block).to match(/reads back exactly like the right one/i)
      expect(block).to match(/subject first, shape second/i)
    end

    # The rule is stated with no case attached, because a case is a pair of real
    # subjects sitting in the prompt for the model to reach for. What's left has
    # to still be actionable, which is the two lines above.
    it "carries no record names, only the shape of the mistake" do
      rule = block[/\*\*When they ask what you're holding.*/, 0]

      expect(rule).not_to include("Whisper", "Glimmer", "prod 3350")
    end

    it "asks for the near miss to be named rather than offered as the answer" do
      expect(block).to match(/not this, but here's what I've got/i)
    end

    it "points at search_ideas, which answers a miss the same way" do
      expect(block).to include("search_ideas")

      tool  = Buddy::Tools[:search_ideas]
      empty = tool[:execute].call({ query: "whisper app buttons" }, Buddy::ToolContext.new(user))

      expect(empty[:ideas]).to be_empty
      expect(empty[:how]).to match(/nothing matched, and that IS the answer/i)
    end

    # The subject is only checkable if it's on the line. A summary is what the
    # block prints, so a summary that drops the subject would hide it again.
    it "prints the idea's own summary, which names its subject" do
      expect(block).to include("Glimmer iPad controls")
    end

    it "costs nothing for someone holding no ideas" do
      expect(Buddy::Personality.open_loops_block(create(:user))).to be_nil
    end
  end
end
