require "rails_helper"

# Brain-dump capture: arm a bucket, the next message becomes an idea; "anything"
# is sorted by Buddy; ideas resurface in context and can be managed by tools.
RSpec.describe "Buddy brain-dump (stash)" do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  def message(body)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
  end

  describe Buddy::Stash do
    it "arms + reads + expires the latch" do
      described_class.arm!(convo, "home")
      expect(described_class.armed_category(convo.reload)).to eq("home")

      convo.update!(metadata: convo.metadata.merge("stash_armed_at" => 20.minutes.ago.iso8601))
      expect(described_class.armed_category(convo.reload)).to be_nil # past TTL
    end

    it "files a concrete-bucket idea, clears the latch, and runs a response turn" do
      described_class.arm!(convo, "work")
      idea = described_class.capture!(user, convo, message("ship the invoice tool"), "work")

      expect(idea).to have_attributes(category: "work", body: "ship the invoice tool", status: "active")
      expect(described_class.armed_category(convo.reload)).to be_nil
      # Buddy responds (acknowledge + offer to talk it through) even for a
      # concrete bucket.
      expect(BuddyDeliverWorker).to have_received(:perform_async)
    end

    it "saves an 'anything' idea unsorted and dispatches Buddy to sort + respond" do
      described_class.arm!(convo, "anything")
      idea = described_class.capture!(user, convo, message("that garage shelf thing"), "anything")

      expect(idea.category).to be_nil
      expect(BuddyDeliverWorker).to have_received(:perform_async)
    end

    it "applies Buddy's sort from a sort_stash call" do
      idea = BuddyIdea.create!(user: user, body: "garage shelves", status: :active)
      Buddy::SideEffects.call(convo, :sort_stash, {
        "id" => idea.id, "category" => "home", "summary" => "build garage shelves",
      })

      expect(idea.reload).to have_attributes(category: "home", summary: "build garage shelves")
    end

    # What Buddy is told to say AFTER the acknowledgement. It used to be one
    # fixed instruction, so "just leave it there, I don't want to talk about
    # each one" couldn't be honoured: the seed asked again every single time.
    describe "the response seed" do
      def seed_for(body, category: "home")
        described_class.arm!(convo, category)
        described_class.capture!(user, convo, message(body), category)
        convo.byte_messages.where("metadata->>'source' = 'stash_response'").order(:id).last.body
      end

      # The scripted offer itself, rather than the words "talk it through" -
      # the closings that SUPPRESS the offer have to name it to forbid it.
      let(:offer) { "want to think it through" }

      it "offers to talk the first one through" do
        expect(seed_for("that garage shelf thing")).to include(offer)
      end

      it "stops offering once they're mid-dump" do
        seed_for("that garage shelf thing")

        expect(seed_for("check the battery on the smoke alarm")).not_to include(offer)
      end

      it "says why it's staying quiet rather than just going silent" do
        seed_for("that garage shelf thing")

        expect(seed_for("check the battery on the smoke alarm")).to include("mid-dump")
      end

      it "offers again once the run is over" do
        BuddyIdea.create!(user: user, body: "yesterday's thing", status: :active, created_at: 5.hours.ago)

        expect(seed_for("check the battery on the smoke alarm")).to include(offer)
      end

      # A thing that repeats on a static pile is a reminder nobody set. Both of
      # these were parked as one-offs, and the person worked around it by asking
      # for them to be left on the pile forever so she'd see them each day.
      it "offers a repeating reminder for something that plainly repeats" do
        expect(seed_for("Feed fish daily")).to include("repeating reminder")
        expect(seed_for("Check propagations every 4 days")).to include("repeating reminder")
      end

      it "offers the reminder even mid-dump, since that one is worth the interruption" do
        seed_for("that garage shelf thing")

        expect(seed_for("water the greenhouse every morning")).to include("repeating reminder")
      end

      it "leaves a one-off alone" do
        expect(seed_for("Pothos needs repotting")).not_to include("repeating reminder")
      end
    end

    it "refines just the summary from a talk-through (summary-only call)" do
      idea = BuddyIdea.create!(user: user, category: :home, summary: "shelves", body: "garage shelves", status: :active)
      Buddy::SideEffects.call(convo, :sort_stash, {
        "id" => idea.id, "summary" => "floating oak shelves over the bench",
      })

      expect(idea.reload).to have_attributes(category: "home", summary: "floating oak shelves over the bench")
    end
  end

  describe "management tools" do
    let!(:idea) { BuddyIdea.create!(user: user, category: :me, body: "learn rust", status: :active) }

    def run(tool_name, payload)
      tool = Buddy::Tools[tool_name]
      ctx  = Buddy::ToolContext.new(user)
      confirm = tool[:confirm].call(payload, ctx)
      tool[:execute].call(payload.merge(confirm[:resolved] || {}), Buddy::ToolContext.new(user))
    end

    it "move_idea refiles the bucket" do
      run(:move_idea, { id: idea.id, category: :work })
      expect(idea.reload.category).to eq("work")
    end

    it "defer_idea sets a remind_after and defers it" do
      run(:defer_idea, { id: idea.id })
      expect(idea.reload).to have_attributes(status: "deferred")
      expect(idea.remind_after).to be_present
    end

    it "drop_idea forgets it" do
      run(:drop_idea, { id: idea.id })
      expect(idea.reload.status).to eq("dropped")
    end

    it "finish_idea ticks it off, and undoing that puts it back on the pile" do
      result = run(:finish_idea, { id: idea.id })
      expect(idea.reload.status).to eq("done")

      Buddy::Reverter.call(result[:revert])
      expect(idea.reload.status).to eq("active")
    end

    it "finish_idea refuses an id that isn't a live one" do
      idea.update!(status: :dropped)

      expect { run(:finish_idea, { id: idea.id }) }.to raise_error(/no held item/)
    end
  end

  # The capture path Buddy drives itself, as opposed to the hero chip. Without
  # it the only way anything gets held is a deliberate tap, which is no use to
  # someone who just talks.
  describe "catching one mid-conversation (stash_idea)" do
    def catch!(payload)
      msg = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
      )
      Buddy::ProposalBuilder.create(
        user:         user,
        byte_message: msg,
        markers:      [{ tool_name: :stash_idea, payload: payload }],
      )
    end

    it "holds it the moment it's said, without waiting for a tap" do
      catch!({ idea: "call Mel back about the fish tank", category: :home, summary: "call Mel re: fish tank" })

      held = user.buddy_ideas.last
      expect(held).to have_attributes(
        body: "call Mel back about the fish tank", category: "home", summary: "call Mel re: fish tank", status: "active",
      )
    end

    it "unchecking the row lets it go rather than deleting the record" do
      result = catch!({ idea: "sort out the greenhouse" })
      action = result[:action]
      held   = user.buddy_ideas.last

      Buddy::ProposalExecutor.undo!(action.id, action.buttons.first["id"])

      expect(held.reload.status).to eq("dropped")
    end

    it "catches each loose end in a rant separately" do
      msg = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
      )
      Buddy::ProposalBuilder.create(
        user:         user,
        byte_message: msg,
        markers:      [
          { tool_name: :stash_idea, payload: { idea: "call Mel back", category: :me } },
          { tool_name: :stash_idea, payload: { idea: "the greenhouse door", category: :home } },
          { tool_name: :stash_idea, payload: { idea: "chase the invoice", category: :work } },
        ],
      )

      expect(user.buddy_ideas.live.pluck(:category)).to match_array(%w[me home work])
    end

    it "collapses the same thought said twice in one turn" do
      msg = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
      )
      Buddy::ProposalBuilder.create(
        user:         user,
        byte_message: msg,
        markers:      [
          { tool_name: :stash_idea, payload: { idea: "call Mel back" } },
          { tool_name: :stash_idea, payload: { idea: "Call Mel Back" } },
        ],
      )

      expect(user.buddy_ideas.live.count).to eq(1)
    end
  end

  # A held item behind a get_context call only surfaces on a turn where Buddy
  # already thought to look, which is never the turn one goes missing.
  describe "what's being held rides in the prompt every turn" do
    it "lists live items with their id and how long they've waited" do
      BuddyIdea.create!(user: user, category: :home, body: "fix the gate", status: :active, created_at: 3.days.ago)

      block = Buddy::Personality.open_loops_block(user)

      expect(block).to include("Things you're holding")
      expect(block).to include("fix the gate", "home", "3 days")
      expect(block).to match(/`#\d+`/)
    end

    it "costs nothing for someone holding nothing" do
      BuddyIdea.create!(user: user, body: "done with this", status: :done)
      BuddyIdea.create!(user: user, body: "never mind", status: :dropped)

      expect(Buddy::Personality.open_loops_block(user)).to be_nil
    end

    it "puts the oldest first, since that's the one at risk" do
      BuddyIdea.create!(user: user, body: "newer thing", status: :active, created_at: 1.hour.ago)
      BuddyIdea.create!(user: user, body: "older thing", status: :active, created_at: 9.days.ago)

      block = Buddy::Personality.open_loops_block(user)

      expect(block.index("older thing")).to be < block.index("newer thing")
    end

    it "reaches the real system prompt, not just the helper" do
      BuddyIdea.create!(user: user, category: :work, body: "chase the invoice", status: :active)

      expect(Buddy::Personality.for(user, conversation: convo)).to include("chase the invoice")
    end
  end

  it "surfaces surfaceable ideas in context, hiding dropped + not-yet-due defers" do
    live = BuddyIdea.create!(user: user, category: :home, body: "fix the gate", summary: "fix the gate", status: :active)
    BuddyIdea.create!(user: user, category: :me, body: "gone", status: :dropped)
    BuddyIdea.create!(user: user, category: :work, body: "later", status: :deferred, remind_after: 3.days.from_now)

    listed = Buddy::Context.send(:stashed_ideas, user)
    expect(listed.pluck(:id)).to eq([live.id])
    expect(listed.first).to include(category: "home", idea: "fix the gate", waiting: "today")
  end
end
