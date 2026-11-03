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
        expect(BuddyDeliverWorker).to have_received(:perform_async)
      end

      it "saves an 'anything' idea unsorted and dispatches Buddy to sort + respond" do
        described_class.arm!(convo, "anything")
        idea = described_class.capture!(user, convo, message("that garage shelf thing"), "anything")

        expect(idea.category).to be_nil
        expect(BuddyDeliverWorker).to have_received(:perform_async)
      end

      describe "a bare pleasantry" do
        it "is not filed, but still clears the latch", :aggregate_failures do
          %w[Thanks! thanks ty Okay ok 👍 Cool Perfect].each { |word|
            described_class.arm!(convo, "me")

            expect { described_class.capture!(user, convo, message(word), "me") }
              .not_to change(BuddyMemory, :count)
            expect(described_class.armed_category(convo.reload)).to be_nil
          }
        end

        it "files it when there's anything more to it" do
          described_class.arm!(convo, "me")

          expect { described_class.capture!(user, convo, message("thanks for the shelf idea"), "me") }
            .to change(BuddyMemory, :count).by(1)
        end
      end

      describe "sort_stash" do
        it "applies Buddy's category and summary" do
          idea = BuddyMemory.create!(kind: :stash, user: user, content: "garage shelves", status: :active)
          Buddy::SideEffects.call(convo, :sort_stash, {
            "id" => idea.id, "category" => "home", "summary" => "build garage shelves"
          })

          expect(idea.reload).to have_attributes(category: "home", summary: "build garage shelves")
        end

        it "takes it off the pile with drop, which the schema offers", :aggregate_failures do
          idea = BuddyMemory.create!(kind: :stash, user: user, content: "remind me at 3:35 to uncover the tomatoes", status: :active)
          schema = Buddy::SideEffects.function_schemas.find { |s| s[:name].to_s == "sort_stash" }

          Buddy::SideEffects.call(convo, :sort_stash, { "id" => idea.id, "drop" => true })

          expect(idea.reload.status).to eq("dropped")
          expect(schema.to_json).to include("drop")
        end

        it "leaves a sort alone when drop isn't set" do
          idea = BuddyMemory.create!(kind: :stash, user: user, content: "garage shelves", status: :active)

          Buddy::SideEffects.call(convo, :sort_stash, { "id" => idea.id, "category" => "home", "drop" => false })

          expect(idea.reload).to have_attributes(status: "active", category: "home")
        end

        it "refines just the summary from a talk-through (summary-only call)" do
          idea = BuddyMemory.create!(kind: :stash, user: user, category: :home, summary: "shelves", content: "garage shelves", status: :active)
          Buddy::SideEffects.call(convo, :sort_stash, {
            "id" => idea.id, "summary" => "floating oak shelves over the bench"
          })

          expect(idea.reload).to have_attributes(category: "home", summary: "floating oak shelves over the bench")
        end
      end

      # The seed for the turn after capture decides whether to offer a
      # talk-through, and whether to offer a repeating reminder.
      describe "the response seed" do
        def seed_for(body, category: "home")
          described_class.arm!(convo, category)
          described_class.capture!(user, convo, message(body), category)
          convo.byte_messages.where("metadata->>'source' = 'stash_response'").order(:id).last.body
        end

        let(:offer) { "want to think it through" }

        it "offers on the first of a run, stops mid-dump, and still offers a repeating reminder", :aggregate_failures do
          expect(seed_for("that garage shelf thing")).to include(offer)
          expect(seed_for("check the battery on the smoke alarm")).not_to include(offer)
          expect(seed_for("water the greenhouse every morning")).to include("repeating reminder")
        end

        it "offers again once the run is over" do
          BuddyMemory.create!(kind: :stash, user: user, content: "yesterday's thing", status: :active, created_at: 5.hours.ago)

          expect(seed_for("check the battery on the smoke alarm")).to include(offer)
        end

        it "offers a repeating reminder only for something that repeats", :aggregate_failures do
          expect(seed_for("Feed fish daily")).to include("repeating reminder")
          expect(seed_for("Check propagations every 4 days")).to include("repeating reminder")
          expect(seed_for("Pothos needs repotting")).not_to include("repeating reminder")
        end

        context "with a list of their own" do
          before { user.lists.create!(name: "Ongoing TO DO").tap { |l| user.user_lists.create!(list: l) } }

          it "names their real lists, and the sort function rather than a stripped marker", :aggregate_failures do
            seed = seed_for("bring out a meat thermometer to check the tomatoes")

            expect(seed).to include("add_list_item", "Ongoing TO DO")
            expect(seed).to include("sort_stash(id:")
            expect(seed).not_to include("[[stash:")
          end

          it "says nothing about lists for someone who has none" do
            user.user_lists.destroy_all

            expect(seed_for("bring out a meat thermometer")).not_to include("add_list_item")
          end
        end
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

    # The capture path Buddy drives itself, as opposed to the hero chip.
    describe "catching one mid-conversation (stash_idea)" do
      def catch_all!(*payloads)
        msg = convo.byte_messages.create!(
          user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
        )
        Buddy::ProposalBuilder.create(
          user:         user,
          byte_message: msg,
          markers:      payloads.map { |payload| { tool_name: :stash_idea, payload: payload } },
        )
      end

      def catch!(payload) = catch_all!(payload)

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

      it "refuses a bare pleasantry here too" do
        expect { catch!({ idea: "Thanks!", category: :me }) }.not_to change(BuddyMemory, :count)
      end

      it "catches each loose end in a rant separately" do
        catch_all!(
          { idea: "call Mel back", category: :me },
          { idea: "the greenhouse door", category: :home },
          { idea: "chase the invoice", category: :work },
        )

        expect(user.buddy_memories.live.pluck(:category)).to match_array(%w[me home work])
      end

      it "collapses the same thought said twice in one turn" do
        catch_all!({ idea: "call Mel back" }, { idea: "Call Mel Back" })

        expect(user.buddy_memories.live.count).to eq(1)
      end

      # Content equality alone misses a link re-described in other words.
      describe "the same link, described differently" do
        let(:first)  { "https://dock.myvobot.com/ — a cool Dock/Clock/Hub I may want to buy and integrate into HASS at some point." }
        let(:second) { "https://dock.myvobot.com/ - a Dock/Clock/Hub to probably buy and integrate into HASS later." }

        it "keeps one entry with the first wording and fills in a missing label", :aggregate_failures do
          catch!({ idea: first })

          expect { catch!({ idea: second, summary: "Dock/Clock/Hub for HASS" }) }
            .not_to change { user.buddy_memories.live.count }
          expect(user.buddy_memories.live.first).to have_attributes(content: first, summary: "Dock/Clock/Hub for HASS")
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

        it "leaves two unlinked thoughts about one subject alone" do
          catch!({ idea: "a dock for HASS would be nice" })

          expect { catch!({ idea: "some sort of clock hub for HASS, maybe" }) }
            .to change { user.buddy_memories.live.count }.by(1)
        end

        it "collapses two of the same link inside one turn" do
          catch_all!({ idea: first }, { idea: second })

          expect(user.buddy_memories.live.count).to eq(1)
        end

        it "does not reach a dropped one and resurrect it" do
          catch!({ idea: first })
          user.buddy_memories.last.update!(status: :dropped)

          expect { catch!({ idea: second }) }.to change { user.buddy_memories.live.count }.by(1)
        end
      end
    end

    describe "what's being held rides in the prompt every turn" do
      # Pinned to midday: the age is counted in calendar days in their zone, so
      # a late-evening run would read 3.days.ago as two.
      it "lists live items with their id and how long they've waited" do
        travel_to(Time.zone.parse("2026-10-14 12:00")) {
          BuddyMemory.create!(kind: :stash, user: user, category: :home, content: "fix the gate", status: :active, created_at: 3.days.ago)

          block = Buddy::Personality.open_loops_block(user)

          expect(block).to include("fix the gate", "home", "3 days")
          expect(block).to match(/`#\d+`/)
        }
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

      # Ascending order plus a cap would take the OLDEST N, dropping the one
      # just handed over.
      it "keeps the newest past the cap, drops the oldest, and still reads oldest-first", :aggregate_failures do
        limit = Buddy::Personality::OPEN_LOOP_LIMIT
        (limit + 3).times { |i|
          BuddyMemory.create!(
            kind: :stash, user: user, status: :active,
            content: "thing #{i}", created_at: (40 - i).days.ago
          )
        }

        block = Buddy::Personality.open_loops_block(user)
        ideas = Buddy::Context.send(:stashed_ideas, user).pluck(:idea)

        expect(block).to include("thing #{limit + 2}")
        # Bounded, because "thing 1" is a substring of "thing 10".
        [0, 1, 2].each { |i| expect(block).not_to match(/\bthing #{i}\b/) }
        expect(block.index("thing 3")).to be < block.index("thing #{limit + 1}")
        expect(ideas).to include("thing #{limit + 2}")
        expect(ideas).not_to include("thing 0", "thing 5")
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

  # Pile entries that were never thoughts: something that repeats, or that
  # names a moment, belongs on a reminder.
  describe "mis-filing" do
    let(:user) { User.me }

    def held(content, summary: nil)
      BuddyMemory.create!(kind: :stash, user: user, status: :active, content: content, summary: summary)
    end

    before { BuddyMemory.where(user: user).destroy_all }

    describe "Buddy::Stash.misfiled_kind" do
      it "classifies repeating, timed, and genuine thoughts", :aggregate_failures do
        [
          ["Feed fish daily", :recurring],
          ["Check propagations every 4 days.", :recurring],
          ["check the front flower bed daily", :recurring],
          # Repeating wins over a time it also names.
          ["water the plants daily at 8pm", :recurring],
          ["Pick out my outfit before 3:45", :timed],
          ["Write Doug's card before 3:45", :timed],
          ["Banana juice can go on the Home list, and set reminder for 8pm", :timed],
          ["Please remind me at 8pm to water the tomatoes", :timed],
          ["Chuck the old plastic pots tomorrow, it's trash day", :timed],
          ["automatic kennel open/close and treat dispenser with an inside sensor", nil],
          ["Figure out a way to subtract an image so the base slime can be separated from items", nil],
          ["Work on bedroom", nil],
          ["Weeds in the front rocky area", nil],
          ["send the squash photo to ChatGPT to find out what it is", nil],
          ["I'm trying to make the lounge feel better, and the Ikea shelf set needs a home", nil],
          ["Add storage with drawers and glass door faces by his work desk", nil],
          ["Look up on YouTube whether blueberry bushes need phosphorus", nil],
        ].each { |content, kind|
          expect(Buddy::Stash.misfiled_kind(held(content))).to eq(kind), content
        }
      end

      it "reads the summary as well as the body" do
        memory = held("Oh right!! Thank you! thank you! Please ping me when it's time to do that!",
          summary: "Noon plant check ping")

        expect(Buddy::Stash.misfiled_kind(memory)).to eq(:timed)
      end
    end

    describe "what rides in the prompt" do
      it "tags a repeating one and a timed one", :aggregate_failures do
        held("Feed fish daily", summary: "Daily fish feeding")
        held("Write Doug's card before 3:45")

        block = Buddy::Personality.open_loops_block(user)

        expect(block).to include("REPEATS", "NAMES A TIME")
        expect(block).to include("schedule_reminder", "drop_idea")
      end

      it "tags nothing when nothing is mis-filed" do
        held("automatic kennel open/close with an inside sensor")

        expect(Buddy::Personality.open_loops_block(user)).not_to include("REPEATS", "NAMES A TIME")
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

      it "sets a one-off after checking upcoming ones, offers a repeating one, and leaves a thought alone", :aggregate_failures do
        timed = closing_for("Please remind me at 8pm to water the tomatoes")

        expect(timed).to include("schedule_reminder", "drop: true", "upcoming_reminders")
        expect(timed).to match(/do not offer and wait/i)
        expect(closing_for("Feed fish daily")).to match(/repeating reminder/i)
        expect(closing_for("Figure out a way to subtract an image from the base slime")).not_to match(/do not offer and wait/i)
      end
    end
  end

  # Refiling out of a bucket leaves a receipt chip, since recent_actions is what
  # Buddy reads to tell whether it did something; a first-time sort stays silent.
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
          content:  "recipe cards need total/prep/cook times", summary: "Recipe card time clarity",
          category: :work, status: :active
        )
      }

      it "moves it and leaves a receipt that reaches recent_actions", :aggregate_failures do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)
        did = Buddy::Context.build(user, convo)[:recent_actions].pluck(:did)

        expect(idea.reload.category).to eq("home")
        expect(chips.count).to eq(1)
        expect(chips.last.metadata["tool_name"]).to eq("sort_stash")
        expect(did).to include(chips.last.body)
      end

      it "reports that something changed, so a true claim survives the guard" do
        expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id, category: "home" })).to be(true)
      end

      it "says nothing when it's already in that bucket" do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "work" }, conversation: convo)

        expect(chips.count).to eq(0)
      end
    end

    describe "filing a fresh dump for the first time" do
      let!(:idea) { user.buddy_memories.create!(kind: :stash, content: "garage shelves", category: nil, status: :active) }

      it "files it and sharpens its summary silently", :aggregate_failures do
        Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)
        Buddy::Stash.apply_sort(user, { id: idea.id, summary: "Garage shelf plan" }, conversation: convo)

        expect(idea.reload).to have_attributes(category: "home", summary: "Garage shelf plan")
        expect(chips.count).to eq(0)
      end

      it "still reports the change even with nothing to show" do
        expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id, category: "home" })).to be(true)
      end
    end

    it "leaves a receipt for taking one off the pile" do
      idea = user.buddy_memories.create!(kind: :stash, content: "uncover the tomatoes", category: :home, status: :active)

      Buddy::Stash.apply_sort(user, { id: idea.id, drop: true }, conversation: convo)

      expect(idea.reload.status).to eq("dropped")
      expect(chips.count).to eq(1)
    end

    # FALSE rather than an error: a marker the model invents must not count as
    # having acted, or it gets a free pass past the retraction guard.
    it "reports no change for an empty sort, someone else's idea, or a marker nothing handles", :aggregate_failures do
      idea = user.buddy_memories.create!(kind: :stash, content: "something", category: :home, status: :active)

      expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id })).to be(false)
      expect(Buddy::SideEffects.call(convo, :sort_stash, { id: -1, category: "work" })).to be(false)
      expect(Buddy::SideEffects.call(convo, :not_a_marker, { whatever: 1 })).to be(false)
    end

    describe "cleaning the reply body" do
      let(:turn) {
        Buddy::GPT::Turn.new(
          convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hi"),
          client: FakeBuddyClient.new([]),
        )
      }

      def clean(body) = turn.send(:display_body, body)

      it "strips echoed stand-in markers and swaps em dashes for hyphens", :aggregate_failures do
        [
          ["[form you put up: Who did: Puppy Down? - answered]", ""],
          ["Kk, four of them. [form you put up: Who did: Puppy Down? - answered] Done.", "Kk, four of them.  Done."],
          ["JPMorgan got it.\n\n[Tapped Today - asked for a briefing on the day ahead]", "JPMorgan got it."],
          ["Done — your Today briefing is up.", "Done - your Today briefing is up."],
          ["Kk! Fan's on low  —  living room one.", "Kk! Fan's on low - living room one."],
        ].each { |body, out| expect(clean(body)).to eq(out), body }
      end

      # Below a length floor only an exact repeat counts, since short replies
      # are mostly stock phrases.
      it "drops a repeated paragraph, reworded or verbatim, and keeps distinct ones", :aggregate_failures do
        reworded = "Ahh, yep. You're right - it's still sitting in home already, so there wasn't anything " \
                   "to move. The recipe card one is home now.\n\nAhh, yep. You're right - it's already in " \
                   "home, so there wasn't anything to move. The recipe card one is home now."
        distinct = "The recipe card one is in home now, so it'll come up with the house stuff.\n\n" \
                   "Want me to pull the other two out of work while I'm in there, or leave those?"
        verbatim = "Moved it over to home for you, that's where the rest of the house stuff lives.\n\n" * 2

        expect(clean(reworded).scan(/Ahh, yep/).size).to eq(1)
        expect(clean(distinct).split("\n\n").size).to eq(2)
        expect(clean("Okie!\n\nOk!").split("\n\n").size).to eq(2)
        expect(clean(verbatim).split("\n\n").size).to eq(1)
      end
    end
  end
end
