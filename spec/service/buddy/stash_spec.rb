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

      expect(idea).to have_attributes(category: "work", content: "ship the invoice tool", status: "active")
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

    # An armed latch swallows whatever comes next, and what comes next is
    # sometimes just manners. Prod filed "Thanks!" onto Eve's Me pile and told
    # her so; every later read of that pile then has to step over it.
    describe "a bare pleasantry" do
      %w[Thanks! thanks ty Okay ok 👍 Cool Perfect].each { |word|
        it "declines to file #{word.inspect}" do
          described_class.arm!(convo, "me")

          expect { described_class.capture!(user, convo, message(word), "me") }
            .not_to change(BuddyMemory, :count)
        end
      }

      it "clears the latch anyway, so they aren't stuck in capture mode" do
        described_class.arm!(convo, "me")
        described_class.capture!(user, convo, message("Thanks!"), "me")

        expect(described_class.armed_category(convo.reload)).to be_nil
      end

      # Gratitude with something attached is still the thought.
      it "files it when there's anything more to it" do
        described_class.arm!(convo, "me")

        expect { described_class.capture!(user, convo, message("thanks for the shelf idea"), "me") }
          .to change(BuddyMemory, :count).by(1)
      end
    end

    it "applies Buddy's sort from a sort_stash call" do
      idea = BuddyMemory.create!(kind: :stash, user: user, content: "garage shelves", status: :active)
      Buddy::SideEffects.call(convo, :sort_stash, {
        "id" => idea.id, "category" => "home", "summary" => "build garage shelves"
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
        BuddyMemory.create!(kind: :stash, user: user, content: "yesterday's thing", status: :active, created_at: 5.hours.ago)

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

    # A dump lands on the pile because the latch swallows whatever comes next,
    # not because the pile is where it belongs. Prod: "Please remind me at 3:35
    # to uncover the tomatoes" became a Home pile entry answered with "Done! I
    # parked the tomatoes reminder on your Home pile" — and 3:35 went past with
    # nothing set, because a pile entry is not a reminder.
    describe "what the sort turn is asked to decide" do
      let!(:list) { user.lists.create!(name: "Ongoing TO DO").tap { |l| user.user_lists.create!(list: l) } }

      def seed_for(body, category: "home")
        described_class.arm!(convo, category)
        described_class.capture!(user, convo, message(body), category)
        convo.byte_messages.where("metadata->>'source' = 'stash_response'").order(:id).last.body
      end

      it "asks what the thing is before asking which bucket" do
        seed = seed_for("Please remind me at 3:35 to uncover the tomatoes")

        expect(seed).to include("WHAT IS IT?")
        # Anchored on the filing instruction itself rather than the word
        # "bucket": this fixture names a time, so it now takes the time-bound
        # closing (which is the whole point of the case), and "bucket" only ever
        # appeared here by way of the ordinary talk-it-through closing.
        expect(seed.index("WHAT IS IT?")).to be < seed.index("If it IS a thought:")
      end

      it "tells it to do the real thing and take it off the pile" do
        seed = seed_for("Please remind me at 3:35 to uncover the tomatoes")

        expect(seed).to include("schedule_reminder", "drop: true")
      end

      it "forbids calling a pile entry a handled reminder" do
        expect(seed_for("Please remind me at 3:35 to uncover the tomatoes"))
          .to include("Never tell them it's handled unless you actually did the thing")
      end

      it "offers their real lists by name for a job with no thinking left in it" do
        seed = seed_for("bring out a meat thermometer to check the tomatoes")

        expect(seed).to include("add_list_item", "Ongoing TO DO")
      end

      it "says nothing about lists for someone who has none" do
        user.user_lists.destroy_all

        expect(seed_for("bring out a meat thermometer")).not_to include("add_list_item")
      end

      it "still tells it a thought stays on the pile" do
        expect(seed_for("that garage shelf thing")).to include("A thought worth holding")
      end

      # The seed used to instruct a `[[stash: ...]]` marker, which Turn strips
      # as a stray and never applies — so the sort it asked for could only land
      # if the model reached past the instruction to the real function.
      it "names the function rather than a marker that gets stripped" do
        seed = seed_for("that garage shelf thing")

        expect(seed).to include("sort_stash(id:")
        expect(seed).not_to include("[[stash:")
      end
    end

    it "takes it off the pile once it's been filed somewhere real" do
      idea = BuddyMemory.create!(kind: :stash, user: user, content: "remind me at 3:35 to uncover the tomatoes", status: :active)

      Buddy::SideEffects.call(convo, :sort_stash, { "id" => idea.id, "drop" => true })

      expect(idea.reload.status).to eq("dropped")
    end

    it "leaves a sort alone when drop isn't set" do
      idea = BuddyMemory.create!(kind: :stash, user: user, content: "garage shelves", status: :active)

      Buddy::SideEffects.call(convo, :sort_stash, { "id" => idea.id, "category" => "home", "drop" => false })

      expect(idea.reload).to have_attributes(status: "active", category: "home")
    end

    it "offers drop to the model as part of sort_stash" do
      schema = Buddy::SideEffects.function_schemas.find { |s| s[:name].to_s == "sort_stash" }

      expect(schema.to_json).to include("drop")
    end

    it "refines just the summary from a talk-through (summary-only call)" do
      idea = BuddyMemory.create!(kind: :stash, user: user, category: :home, summary: "shelves", content: "garage shelves", status: :active)
      Buddy::SideEffects.call(convo, :sort_stash, {
        "id" => idea.id, "summary" => "floating oak shelves over the bench"
      })

      expect(idea.reload).to have_attributes(category: "home", summary: "floating oak shelves over the bench")
    end
  end

  describe "management tools" do
    let!(:idea) { BuddyMemory.create!(kind: :stash, user: user, category: :me, content: "learn rust", status: :active) }

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

    it "defer_idea sets a relevant_at and defers it" do
      run(:defer_idea, { id: idea.id })
      expect(idea.reload).to have_attributes(status: "deferred")
      expect(idea.relevant_at).to be_present
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

      held = user.buddy_memories.last
      expect(held).to have_attributes(
        content: "call Mel back about the fish tank", category: "home", summary: "call Mel re: fish tank", status: "active",
      )
    end

    it "unchecking the row lets it go rather than deleting the record" do
      result = catch!({ idea: "sort out the greenhouse" })
      action = result[:action]
      held   = user.buddy_memories.last

      Buddy::ProposalExecutor.undo!(action.id, action.buttons.first["id"])

      expect(held.reload.status).to eq("dropped")
    end

    # The latch refuses these; this is the other door into the same pile, and
    # it was standing open.
    it "refuses a bare pleasantry here too" do
      expect { catch!({ idea: "Thanks!", category: :me }) }.not_to change(BuddyMemory, :count)
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

      expect(user.buddy_memories.live.pluck(:category)).to match_array(%w[me home work])
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

      expect(user.buddy_memories.live.count).to eq(1)
    end
  end

  # A held item behind a get_context call only surfaces on a turn where Buddy
  # already thought to look, which is never the turn one goes missing.
  describe "what's being held rides in the prompt every turn" do
    it "lists live items with their id and how long they've waited" do
      BuddyMemory.create!(kind: :stash, user: user, category: :home, content: "fix the gate", status: :active, created_at: 3.days.ago)

      block = Buddy::Personality.open_loops_block(user)

      expect(block).to include("Things you're holding")
      expect(block).to include("fix the gate", "home", "3 days")
      expect(block).to match(/`#\d+`/)
    end

    it "costs nothing for someone holding nothing" do
      BuddyMemory.create!(kind: :stash, user: user, content: "done with this", status: :done)
      BuddyMemory.create!(kind: :stash, user: user, content: "never mind", status: :dropped)

      expect(Buddy::Personality.open_loops_block(user)).to be_nil
    end

    it "puts the oldest first, since that's the one at risk" do
      BuddyMemory.create!(kind: :stash, user: user, content: "newer thing", status: :active, created_at: 1.hour.ago)
      BuddyMemory.create!(kind: :stash, user: user, content: "older thing", status: :active, created_at: 9.days.ago)

      block = Buddy::Personality.open_loops_block(user)

      expect(block.index("older thing")).to be < block.index("newer thing")
    end

    it "reaches the real system prompt, not just the helper" do
      BuddyMemory.create!(kind: :stash, user: user, category: :work, content: "chase the invoice", status: :active)

      expect(Buddy::Personality.for(user, conversation: convo)).to include("chase the invoice")
    end
  end

  it "surfaces surfaceable ideas in context, hiding dropped + not-yet-due defers" do
    live = BuddyMemory.create!(kind: :stash, user: user, category: :home, content: "fix the gate", summary: "fix the gate", status: :active)
    BuddyMemory.create!(kind: :stash, user: user, category: :me, content: "gone", status: :dropped)
    BuddyMemory.create!(kind: :stash, user: user, category: :work, content: "later", status: :deferred, relevant_at: 3.days.from_now)

    listed = Buddy::Context.send(:stashed_ideas, user)
    expect(listed.pluck(:id)).to eq([live.id])
    expect(listed.first).to include(category: "home", idea: "fix the gate", waiting: "today")
  end
end
