require "rails_helper"

RSpec.describe "Buddy brain-dump (stash)" do
  # Brain-dump capture: arm a bucket, the next message becomes an idea; "anything"
  # is sorted by Buddy; ideas resurface in context and can be managed by tools.
  describe "the pile" do
    let(:user) { create(:user) }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    def message(body)
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    end

    # Prod memory 60 was "After that, clear out the entire pantry." — one half of
    # a sentence she said in one breath, split into a row that means nothing on
    # its own. The pile is unordered and its rows are never read side by side.
    describe "the stash_idea tool's own instructions" do
      it "requires each split-out piece to still say something" do
        tool = Buddy::Tools.all.find { |t| t[:name] == :stash_idea }

        expect(tool[:description]).to match(/EACH ONE HAS TO\s+STAND ALONE/)
        expect(tool[:description]).to match(/Splitting their sentence is only half the job/)
      end
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

      # Prod 4723 / 4739, 26 Aug. The vobot dock link went onto the pile at
      # 14:47 as BuddyMemory 113. Eighty-two minutes later a message about the
      # Before Bed list - nothing to do with docks - stashed it again as 115,
      # reworded: "a cool Dock/Clock/Hub I may want to buy" the first time, "a
      # Dock/Clock/Hub to probably buy" the second. Content equality was the
      # whole dedupe, so both doors missed. Rocco said twice that it didn't
      # belong and got two apologies; neither turn removed anything.
      describe "the same link, described differently" do
        let(:first)  { "https://dock.myvobot.com/ — a cool Dock/Clock/Hub I may want to buy and integrate into HASS at some point." }
        let(:second) { "https://dock.myvobot.com/ - a Dock/Clock/Hub to probably buy and integrate into HASS later." }

        it "does not start a second pile entry" do
          catch!({ idea: first, summary: "Possible HASS dock integration" })

          expect { catch!({ idea: second, summary: "Dock/Clock/Hub for HASS" }) }
            .not_to change { user.buddy_memories.live.count }
        end

        it "keeps the wording that was there first" do
          catch!({ idea: first })
          catch!({ idea: second })

          expect(user.buddy_memories.live.first.content).to eq(first)
        end

        it "fills in a label the first telling didn't carry" do
          catch!({ idea: first })
          catch!({ idea: second, summary: "Dock/Clock/Hub for HASS" })

          expect(user.buddy_memories.live.first.summary).to eq("Dock/Clock/Hub for HASS")
        end

        it "ignores a trailing slash and a query string" do
          catch!({ idea: "https://dock.myvobot.com/ - worth a look" })

          expect { catch!({ idea: "https://dock.myvobot.com?ref=twitter - worth a look, actually" }) }
            .not_to change { user.buddy_memories.live.count }
        end

        it "still holds a DIFFERENT link" do
          catch!({ idea: first })

          expect { catch!({ idea: "https://shop.pimoroni.com/ - this one instead" }) }
            .to change { user.buddy_memories.live.count }.by(1)
        end

        # The link is what can't drift; two link-less thoughts that merely share
        # a subject are still two thoughts.
        it "leaves two unlinked thoughts about one subject alone" do
          catch!({ idea: "a dock for HASS would be nice" })

          expect { catch!({ idea: "some sort of clock hub for HASS, maybe" }) }
            .to change { user.buddy_memories.live.count }.by(1)
        end

        it "collapses two of the same link inside one turn" do
          msg = convo.byte_messages.create!(
            user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
          )
          Buddy::ProposalBuilder.create(
            user:         user,
            byte_message: msg,
            markers:      [
              { tool_name: :stash_idea, payload: { idea: first } },
              { tool_name: :stash_idea, payload: { idea: second } },
            ],
          )

          expect(user.buddy_memories.live.count).to eq(1)
        end

        it "does not reach a dropped one and resurrect it" do
          catch!({ idea: first })
          user.buddy_memories.last.update!(status: :dropped)

          expect { catch!({ idea: second }) }.to change { user.buddy_memories.live.count }.by(1)
        end
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

  # Pile entries that were never thoughts.
  #
  # `destination` ("WHAT IS IT?") landed on 6 Aug and tells the model to DO a
  # thing with a clock on it rather than file it. It works most of the time. Two
  # gaps it can't close on its own:
  #
  #   1. Nothing deterministic marks a one-off with a moment in it, the way
  #      RECURRING_RX marks a repeating one. The one shape where hesitating costs
  #      the whole thing had the loosest handling.
  #   2. A capture-time fix only ever helps things captured after it ships.
  #      Everything already on the pile stayed exactly as mis-filed as the day it
  #      arrived, and nothing ever went back.
  describe "mis-filing" do
    let(:user) { User.me }

    def held(content, summary: nil)
      BuddyMemory.create!(kind: :stash, user: user, status: :active, content: content, summary: summary)
    end

    before { BuddyMemory.where(user: user).destroy_all }

    describe "Buddy::Stash.misfiled_kind" do
      it "spots something that repeats" do
        expect(Buddy::Stash.misfiled_kind(held("Feed fish daily"))).to eq(:recurring)
        expect(Buddy::Stash.misfiled_kind(held("Check propagations every 4 days."))).to eq(:recurring)
        expect(Buddy::Stash.misfiled_kind(held("check the front flower bed daily"))).to eq(:recurring)
      end

      # Every one of these is a real pile entry whose moment went past with
      # nothing set.
      it "spots something that names a moment" do
        expect(Buddy::Stash.misfiled_kind(held("Pick out my outfit before 3:45"))).to eq(:timed)
        expect(Buddy::Stash.misfiled_kind(held("Write Doug's card before 3:45"))).to eq(:timed)
        expect(Buddy::Stash.misfiled_kind(held("Banana juice can go on the Home list, and set reminder for 8pm"))).to eq(:timed)
        expect(Buddy::Stash.misfiled_kind(held("Please remind me at 8pm to water the tomatoes"))).to eq(:timed)
        expect(Buddy::Stash.misfiled_kind(held("Chuck the old plastic pots tomorrow, it's trash day"))).to eq(:timed)
      end

      it "reads the summary as well as the body, since that's where the shape often shows" do
        memory = held("Oh right!! Thank you! thank you! Please ping me when it's time to do that!",
          summary: "Noon plant check ping")

        expect(Buddy::Stash.misfiled_kind(memory)).to eq(:timed)
      end

      # The regexes have to stay narrow or they swallow the pile they're meant to
      # clean. These are all real entries that genuinely belong where they are.
      it "leaves a genuine thought alone" do
        [
          "automatic kennel open/close and treat dispenser with an inside sensor",
          "Figure out a way to subtract an image so the base slime can be separated from items",
          "Work on bedroom",
          "Weeds in the front rocky area",
          "send the squash photo to ChatGPT to find out what it is",
          "I'm trying to make the lounge feel better, and the Ikea shelf set needs a home",
          "Add storage with drawers and glass door faces by his work desk",
          "Look up on YouTube whether blueberry bushes need phosphorus",
        ].each { |content| expect(Buddy::Stash.misfiled_kind(held(content))).to be_nil }
      end

      it "reads repeating as repeating even when it also names a time" do
        expect(Buddy::Stash.misfiled_kind(held("water the plants daily at 8pm"))).to eq(:recurring)
      end
    end

    describe "what rides in the prompt" do
      it "marks a repeating one so there is somewhere to notice it" do
        held("Feed fish daily", summary: "Daily fish feeding")

        block = Buddy::Personality.open_loops_block(user)

        expect(block).to include("REPEATS")
        expect(block).to match(/never a thought/i)
        expect(block).to include("schedule_reminder")
      end

      it "marks one that names a moment" do
        held("Pick out my outfit before 3:45")

        expect(Buddy::Personality.open_loops_block(user)).to include("NAMES A TIME")
      end

      # A pile is not a thing to audit at somebody.
      it "tells it to wait for the subject to come up rather than raising them cold" do
        held("Feed fish daily")

        expect(Buddy::Personality.open_loops_block(user)).to match(/don't raise them out of nowhere/i)
      end

      it "offers dropping instead when the moment has already gone" do
        held("Write Doug's card before 3:45")

        expect(Buddy::Personality.open_loops_block(user)).to include("drop_idea")
      end

      # The common prompt has to be unchanged for a pile that's all real thoughts.
      it "says nothing at all when nothing is mis-filed" do
        held("automatic kennel open/close with an inside sensor")

        block = Buddy::Personality.open_loops_block(user)

        expect(block).not_to include("REPEATS", "NAMES A TIME")
        expect(block).not_to match(/never a thought/i)
      end

      it "reaches the real system prompt, not just the helper" do
        held("Feed fish daily")
        convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

        expect(Buddy::Personality.for(user, conversation: convo)).to include("REPEATS")
      end
    end

    describe "the closing at capture" do
      def closing_for(content)
        Buddy::Stash.send(:closing, user, held(content))
      end

      # Not an offer. The moment arrives whether or not anyone gets round to
      # discussing it, and "want me to set that?" answered twenty minutes later is
      # a reminder that already missed.
      it "tells it to SET a one-off rather than offer one" do
        text = closing_for("Please remind me at 8pm to water the tomatoes")

        expect(text).to include("schedule_reminder")
        expect(text).to match(/do not offer and wait/i)
        expect(text).to include("drop: true")
      end

      it "sends it to check for one that already covers it first" do
        expect(closing_for("ping me at 8pm about the tomatoes")).to include("upcoming_reminders")
      end

      it "still merely OFFERS for a repeating one, which can wait" do
        text = closing_for("Feed fish daily")

        expect(text).to match(/offer/i)
        expect(text).to match(/repeating reminder/i)
      end

      it "leaves a genuine thought on the ordinary path" do
        text = closing_for("Figure out a way to subtract an image from the base slime")

        expect(text).not_to match(/do not offer and wait/i)
      end
    end
  end

  # Prod 3332-3337, which was one failure wearing three faces.
  #
  # "That's actually more of a home one" refiled a stashed idea out of Work
  # correctly, via the `sort_stash` side effect. Side effects are silent by
  # design, so it left no chip and no row — the only trace was the sentence
  # "Kk! Moved it to home." Told that was a lie, Buddy looked for evidence of its
  # own doing, found none (that is exactly what `recent_actions` reads), agreed,
  # and then invented a reason: "it's already in home, so there wasn't anything
  # to move" — contradicting the Work receipt it had given five messages earlier.
  # And it said all that twice, reworded in the middle, because the paragraph
  # dedupe only caught byte-identical repeats.
  #
  # The design tension underneath: silence is RIGHT when an idea is first filed
  # (the stash chip above it already says where it landed) and wrong when one is
  # moved out of a bucket it was already in. Those had the same code path.
  describe "refile receipts" do
    let(:user) { create(:user) }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    def chips
      convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").order(:created_at)
    end

    describe "moving one that was already filed" do
      let!(:idea) {
        user.buddy_memories.create!(
        kind:     :stash,
          content: "recipe cards need total/prep/cook times", summary: "Recipe card time clarity",
          category: :work, status: :active
        )
      }

      it "really moves it" do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)

        expect(idea.reload.category).to eq("home")
      end

      it "leaves a receipt naming where it went" do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)

        expect(chips.count).to eq(1)
        expect(chips.last.body).to eq("Moved Recipe card time clarity to Home")
        expect(chips.last.metadata["tool_name"]).to eq("sort_stash")
      end

      # The chip is not decoration — `Buddy::Context#recent_actions` reads exactly
      # this, and the persona tells Buddy that anything missing from it did not
      # happen. That rule is what turned a silent success into a confession.
      it "shows up in the record Buddy checks when accused of not doing it" do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)
        did = Buddy::Context.build(user, convo)[:recent_actions].pluck(:did)

        expect(did).to include("Moved Recipe card time clarity to Home")
      end

      it "reports that something changed, so a true claim survives the guard" do
        changed = Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id, category: "home" })

        expect(changed).to be(true)
      end

      it "says nothing when it's already in that bucket" do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "work" }, conversation: convo)

        expect(chips.count).to eq(0)
      end
    end

    # Silence is correct here: Stash#capture! already posted "📥 Stashed to Home"
    # above this, and a second receipt saying the same thing is noise.
    describe "filing a fresh dump for the first time" do
      let!(:idea) { user.buddy_memories.create!(kind: :stash, content: "garage shelves", category: nil, status: :active) }

      it "files it silently" do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)

        expect(idea.reload.category).to eq("home")
        expect(chips.count).to eq(0)
      end

      # The persona promises this one out loud: "Never announce that you're
      # updating it."
      it "sharpens a summary silently" do
        Buddy::Stash.apply_sort(user, { id: idea.id, summary: "Garage shelf plan" }, conversation: convo)

        expect(idea.reload.summary).to eq("Garage shelf plan")
        expect(chips.count).to eq(0)
      end

      it "still reports the change even with nothing to show" do
        expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id, category: "home" })).to be(true)
      end
    end

    describe "taking one off the pile" do
      let!(:idea) { user.buddy_memories.create!(kind: :stash, content: "uncover the tomatoes", category: :home, status: :active) }

      # It went somewhere it can be acted on. Buddy is told never to say a pile
      # entry is handled, so the chip says what actually happened to the ENTRY.
      it "leaves a receipt for that too" do
        Buddy::Stash.apply_sort(user, { id: idea.id, drop: true }, conversation: convo)

        expect(idea.reload.status).to eq("dropped")
        expect(chips.last.body).to eq("Took uncover the tomatoes off the pile")
      end
    end

    describe "when nothing is asked for" do
      let!(:idea) { user.buddy_memories.create!(kind: :stash, content: "something", category: :home, status: :active) }

      it "reports no change, so it can't back a claim" do
        expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id })).to be(false)
      end

      it "reports no change for an idea that isn't theirs" do
        expect(Buddy::SideEffects.call(convo, :sort_stash, { id: -1, category: "work" })).to be(false)
      end
    end

    # set_mood moves a face and nothing else. Letting it count as having acted
    # would hand every reply a free pass past the retraction guard, since Buddy
    # sets its mood on nearly all of them.
    describe "a side effect that changes nothing in the world" do
      it "does not report a change for set_mood" do
        expect(Buddy::SideEffects.call(convo, :set_mood, { expression: "happy" })).to be(false)
      end
    end

    # A conversation-level guard belongs with the paragraph dedupe it protects.
    describe "saying it twice" do
      subject(:deduped) {
        Buddy::GPT::Turn.new(
          convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hi"),
          client: FakeBuddyClient.new([]),
        ).send(:display_body, body)
      }

      # The em dash rule is written down in the persona and in every tone
      # profile, and em dashes still come out - two in one 100-turn eval. Four
      # statements of a rule is where a fifth stops being the fix.
      # Prod 4202: "Log 4 more Build Furniture for the Wayfair Desk" came back
      # with History#form_standin's marker as the ENTIRE reply, and the
      # instruction was dropped. Same family as the mood marker and the relay
      # framing, both already scrubbed here.
      context "when the model echoes the form marker it was given to read" do
        let(:body) { "[form you put up: Who did: Puppy Down? - answered]" }

        it "takes it out" do
          expect(deduped).to eq("")
        end
      end

      context "when the marker is buried in a real sentence" do
        let(:body) { "Kk, four of them. [form you put up: Who did: Puppy Down? - answered] Done." }

        it "leaves the sentence" do
          expect(deduped).to eq("Kk, four of them.  Done.")
        end
      end

      context "when the model uses an em dash anyway" do
        let(:body) { "Done — your Today briefing is up." }

        it "hands over the hyphen every profile actually asks for" do
          expect(deduped).to eq("Done - your Today briefing is up.")
        end
      end

      context "when the em dash is already sitting in spaces" do
        let(:body) { "Kk! Fan's on low  —  living room one." }

        it "doesn't leave a puddle of spaces behind" do
          expect(deduped).to eq("Kk! Fan's on low - living room one.")
        end
      end

      context "when the second copy is reworded in the middle" do
        let(:body) {
          "Ahh, yep. You're right - it's still sitting in home already, so there wasn't anything " \
            "to move. The recipe card one is home now.\n\nAhh, yep. You're right - it's already in " \
            "home, so there wasn't anything to move. The recipe card one is home now."
        }

        it "keeps one of them" do
          expect(deduped.scan(/Ahh, yep/).size).to eq(1)
        end
      end

      context "when two paragraphs genuinely say different things" do
        let(:body) {
          "The recipe card one is in home now, so it'll come up with the house stuff.\n\n" \
            "Want me to pull the other two out of work while I'm in there, or leave those?"
        }

        it "keeps both" do
          expect(deduped.split("\n\n").size).to eq(2)
        end
      end

      # Short replies are mostly stock phrases and would collide constantly under
      # a similarity test. Below the floor, only an exact repeat is a repeat.
      context "when two short paragraphs are similar but not the same" do
        let(:body) { "Okie!\n\nOk!" }

        it "keeps both" do
          expect(deduped.split("\n\n").size).to eq(2)
        end
      end

      context "when a long paragraph is repeated word for word" do
        let(:body) { "Moved it over to home for you, that's where the rest of the house stuff lives.\n\n" * 2 }

        it "keeps one" do
          expect(deduped.split("\n\n").size).to eq(1)
        end
      end
    end
  end
end
