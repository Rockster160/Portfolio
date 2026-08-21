require "rails_helper"

RSpec.describe Buddy::RoutinesController, type: :controller do
  # The drawer panel is deliberately read-mostly: steps are tool calls with
  # validated arguments, which get written by talking to Byte. What lives here is
  # the part conversation is bad at - seeing them all, fixing a name, muting one,
  # throwing one away.
  describe "the controller" do
    let(:user) { User.me }

    before { sign_in user }

    # Every line this pet could have reached for, as one pattern. What a routine
    # says is the companion's own voice (Buddy::VoiceLines) and there are several
    # of each, so a spec pins the SET rather than a phrasing nobody promised.
    def one_of(kind, theme, **vars)
      Regexp.union(
        Buddy::VoiceLines.lines_for(theme, kind).map { |line| Buddy::VoiceLines.render(line[:say], vars) },
      )
    end

    def routine!(name, enabled: true)
      BuddyRoutine.create!(
        user:    user,
        name:    name,
        enabled: enabled,
        steps:   [BuddyRoutine.step(:message_partner, { to: "someone", message: "night" })],
      )
    end

    describe "GET #index" do
      it "lists them alphabetically, with the steps spelled out" do
        routine!("Wind Down")
        routine!("Prep Printer")

        get :index
        body = response.parsed_body

        expect(response).to be_successful
        expect(body["routines"].pluck("name")).to eq(["Prep Printer", "Wind Down"])
        expect(body["routines"].first["summary"]).to be_present
      end

      it "includes the disabled ones, since turning one back on is the point" do
        routine!("Off", enabled: false)

        get :index

        expect(response.parsed_body["routines"].pluck("enabled")).to eq([false])
      end

      it "never shows someone else's" do
        BuddyRoutine.create!(
          user:  create(:user),
          name:  "Theirs",
          steps: [BuddyRoutine.step(:message_partner, { to: "x", message: "y" })],
        )

        get :index

        expect(response.parsed_body["routines"]).to be_empty
      end
    end

    describe "PATCH #update" do
      it "renames one" do
        routine = routine!("Nightly")

        patch :update, params: { id: routine.id, routine: { name: "Bedtime" } }

        expect(response).to be_successful
        expect(routine.reload.name).to eq("Bedtime")
      end

      it "turns one off without losing it" do
        routine = routine!("Nightly")

        patch :update, params: { id: routine.id, routine: { enabled: false } }

        expect(routine.reload.enabled).to be(false)
        expect(routine.steps).to be_present
      end

      # Steps come from save_routine, which validates them. Letting the panel post
      # raw steps would be a way around that check.
      it "ignores steps posted from the panel" do
        routine = routine!("Nightly")
        before  = routine.steps

        patch :update, params: { id: routine.id, routine: { name: "Bedtime", steps: [] } }

        expect(routine.reload.steps).to eq(before)
      end

      it "can't reach someone else's" do
        theirs = BuddyRoutine.create!(
          user:  create(:user),
          name:  "Theirs",
          steps: [BuddyRoutine.step(:message_partner, { to: "x", message: "y" })],
        )

        patch :update, params: { id: theirs.id, routine: { name: "Mine" } }

        expect(response).not_to be_successful
        expect(theirs.reload.name).to eq("Theirs")
      end
    end

    describe "DELETE #destroy" do
      it "removes it" do
        routine = routine!("Nightly")

        delete :destroy, params: { id: routine.id }

        expect(response).to have_http_status(:no_content)
        expect(BuddyRoutine.exists?(routine.id)).to be(false)
      end
    end

    # The Quick grid in the hero. Its order is one fact rather than N independent
    # ones, so the whole thing is sent at once: pinning is that list plus one,
    # unpinning is it minus one, and a drag is the new order.
    describe "POST #reorder" do
      it "pins in the order given" do
        a = routine!("Alpha")
        b = routine!("Beta")

        post :reorder, params: { ids: [b.id, a.id] }

        expect(response).to be_successful
        expect([b.reload.position, a.reload.position]).to eq([0, 1])
      end

      it "unpins anything left out" do
        a = routine!("Alpha")
        b = routine!("Beta")
        post :reorder, params: { ids: [a.id, b.id] }

        post :reorder, params: { ids: [a.id] }

        expect(a.reload.position).to eq(0)
        expect(b.reload.position).to be_nil
      end

      it "clears the whole grid when nothing is sent" do
        a = routine!("Alpha")
        post :reorder, params: { ids: [a.id] }

        post :reorder, params: { ids: [] }

        expect(a.reload.position).to be_nil
      end

      it "refuses to pin someone else's" do
        theirs = BuddyRoutine.create!(
          user:  create(:user),
          name:  "Theirs",
          steps: [BuddyRoutine.step(:message_partner, { to: "x", message: "y" })],
        )

        post :reorder, params: { ids: [theirs.id] }

        expect(theirs.reload.position).to be_nil
      end
    end

    describe "POST #run" do
      let(:partner) { create(:user) }
      let(:household) { user.chore_household || ChoreHousehold.create!(name: "Home", owner_user: user) }
      let!(:convo) {
        user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
      }

      before {
        allow(MonitorChannel).to receive(:broadcast_to)
        allow(WebPushNotifications).to receive(:send_to_byte)
        allow(::WebPushNotifications).to receive(:update_count)
        ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
        user.update!(chore_household_id: household.id)
        partner.update!(chore_household_id: household.id)
        partner.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
      }

      def nightly!
        BuddyRoutine.create!(
          user:  user,
          name:  "Nightly",
          steps: [BuddyRoutine.step(:message_partner, { to: partner.username, message: "night" })],
        )
      end

      # A tapped routine is already decided, so spending a model round trip on
      # having it re-said costs money and reintroduces the one thing a saved
      # sequence removes - a different answer each time.
      it "runs the steps without a model turn" do
        routine = nightly!

        expect(BuddyDeliverWorker).not_to receive(:perform_async)
        post :run, params: { id: routine.id, conversation_id: convo.id }

        expect(response).to be_successful
        expect(BuddyRelay.last.body).to eq("night")
        expect(routine.reload.run_count).to eq(1)
      end

      # The line is the pet's own (Buddy::VoiceLines), so it's asserted as "one of
      # the things this theme says" rather than pinned to one phrasing — but it
      # always names the routine, which is the part that has to be there.
      it "hangs the steps under a line saying what ran" do
        routine = nightly!

        post :run, params: { id: routine.id, conversation_id: convo.id }

        said = convo.byte_messages.pluck(:body)
        expect(said).to include(a_string_including("**Nightly**"))
        expect(said).to include(a_string_matching(one_of(:routine_run, convo.buddy_theme, name: "Nightly")))
      end

      # A bare heading over nothing reads as the routine having worked.
      it "says so on the same message when nothing in it could run" do
        routine = routine!("Nightly") # targets a name nobody in the household has

        post :run, params: { id: routine.id, conversation_id: convo.id }

        expect(convo.byte_messages.last.body).to match(one_of(:routine_empty, convo.buddy_theme))
      end

      it "refuses one that's turned off" do
        routine = BuddyRoutine.create!(user: user, name: "Nightly", enabled: false, steps: [BuddyRoutine.step(:message_partner, { to: partner.username, message: "night" })])

        post :run, params: { id: routine.id, conversation_id: convo.id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(routine.reload.run_count).to eq(0)
      end

      it "needs a conversation that's really theirs" do
        routine = routine!("Nightly")
        theirs  = create(:user).byte_conversations.create!(mode: :buddy, name: "Buddy")

        post :run, params: { id: routine.id, conversation_id: theirs.id }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Turning a Jil automation into a one-tap button.
  #
  # A Jil button IS a routine with one `trigger_jil_task` step - same record, same
  # runner, same pin/order/mute/delete, and it lands on the Quick grid and the
  # wall tablet with no separate handling. This is only here because getting one
  # used to mean asking Buddy to save it, and there's nothing to discuss when the
  # whole routine is "fire this".
  describe "jil actions in a step" do
    let(:user) { create(:user, id: 4) } # someone with Byte access

    before { sign_in user }

    def task!(name:, listener: "fan-high", description: "Puts the fan on high", **attrs)
      Task.create!(
        user: user, name: name, listener: listener, description: description,
        code: "", enabled: true, buddy_enabled: true, **attrs
      )
    end

    def actions
      response.parsed_body["actions"]
    end

    describe "GET #jil_actions" do
      it "offers an automation that fires by name alone" do
        task!(name: "Fan High")

        get :jil_actions

        expect(response).to be_successful
        expect(actions.pluck("name")).to eq(["Fan High"])
        expect(actions.first["description"]).to eq("Puts the fan on high")
      end

      # The filter that matters. A listener with data filters on it needs a
      # payload built to fire, and a button has nowhere to say what that payload
      # is — so offering one would produce a button that looks fine and quietly
      # never fires, which is the one failure a saved button must not have.
      it "leaves out one that needs data to fire" do
        task!(name: "Categorize", listener: "event:add name::Transaction")

        get :jil_actions

        expect(actions).to be_empty
      end

      # What actually accounts for most of the gap between "automations I have"
      # and "automations offered here": a function takes typed arguments, so it's
      # `call_jil_function` with values, not a button. The picker says so in place
      # now, because 7 offered out of 21 buddy-enabled otherwise reads as a bug.
      it "leaves out a function, which needs arguments rather than a name" do
        task!(name: "HASS Light", listener: 'function("Action" TAB ["on" "off"]("on"))::None')

        get :jil_actions

        expect(actions).to be_empty
      end

      # The client filters on name, description AND scope, because which one you'd
      # search by depends on the automation.
      it "sends the scope along so the picker can be searched by it" do
        task!(name: "Fan High", listener: "fan-high")

        get :jil_actions

        expect(actions.first["scope"]).to eq("fan-high")
      end

      it "leaves out one the owner hasn't opted in to Buddy" do
        task!(name: "Private", buddy_enabled: false)

        get :jil_actions

        expect(actions).to be_empty
      end

      it "stops offering one that already has a button" do
        t = task!(name: "Fan High")
        post :create, params: { task_id: t.id }

        get :jil_actions

        expect(actions).to be_empty
      end
    end

    describe "POST #create" do
      it "saves it as a one-step routine that fires the task" do
        t = task!(name: "Fan High")

        post :create, params: { task_id: t.id }

        expect(response).to have_http_status(:created)
        routine = user.buddy_routines.last
        expect(routine.name).to eq("Fan High")
        expect(routine.steps.length).to eq(1)
        expect(routine.steps.first["tool_name"]).to eq("trigger_jil_task")
        expect(routine.steps.first.dig("payload", "name")).to eq("Fan High")
      end

      it "takes a shorter label for the wall when one is given" do
        t = task!(name: "Printer - Preheat")

        post :create, params: { task_id: t.id, name: "Preheat" }

        expect(user.buddy_routines.last.name).to eq("Preheat")
      end

      # Every enabled routine is already on the Quick grid and the kiosk, so this
      # is the whole point: adding one here puts a button on the wall.
      it "lands on the wall pad straight away" do
        t = task!(name: "Fan High")

        post :create, params: { task_id: t.id }

        expect(user.buddy_routines.for_quick.map(&:name)).to include("Fan High")
      end

      it "refuses a second one under the same name" do
        t = task!(name: "Fan High")
        post :create, params: { task_id: t.id }

        post :create, params: { task_id: t.id, name: "fan high" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(user.buddy_routines.count).to eq(1)
      end

      it "refuses an automation that needs data" do
        t = task!(name: "Categorize", listener: "event:add name::Transaction")

        post :create, params: { task_id: t.id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(user.buddy_routines).to be_empty
      end

      it "refuses someone else's automation" do
        other = create(:user)
        theirs = Task.create!(
          user: other, name: "Not Yours", listener: "fan-high", code: "", enabled: true, buddy_enabled: true,
        )

        post :create, params: { task_id: theirs.id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(user.buddy_routines).to be_empty
      end
    end

    it "refuses anyone who can't open Byte at all" do
      sign_in create(:user)

      get :jil_actions

      expect(response).to have_http_status(:forbidden)
    end
  end

  # Rearranging the steps a routine already has: drop one, drag them into a
  # different order, change how many times one runs.
  #
  # What this endpoint deliberately can't do is compose a step. The client sends
  # back the ORIGINAL index of each step it's keeping, so the worst a bug on that
  # side can do is reorder or lose a step - never invent a broken one, which is
  # the failure that made `update` refuse `steps` in the first place.
  describe "editing steps" do
    let(:user) { User.me }
    let(:household) { user.chore_household || ChoreHousehold.create!(name: "Home", owner_user: user) }

    before {
      sign_in user
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      user.update!(chore_household_id: household.id)
    }

    def routine!
      BuddyRoutine.create!(
        user:  user,
        name:  "water cup",
        steps: [
          BuddyRoutine.step(:complete_chore, { chore: "8oz Water", count: 3 }),
          BuddyRoutine.step(:set_timer, { seconds: 60, then_continue: true }),
          BuddyRoutine.step(:log_event, { name: "Water" }),
        ],
      )
    end

    def tools_of(routine)
      routine.reload.steps.pluck("tool_name")
    end

    describe "PATCH #steps" do
      it "drops the ones left out" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 0 }, { index: 2 }] }

        expect(response).to be_successful
        expect(tools_of(r)).to eq(%w[complete_chore log_event])
      end

      it "reorders them into the order sent" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 2 }, { index: 1 }, { index: 0 }] }

        expect(tools_of(r)).to eq(%w[log_event set_timer complete_chore])
      end

      # The value most often wrong, and the one that's purely a number: "cup
      # water" was saved to cash in three waters and read back as one for days.
      it "changes how many times a step runs" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 0, count: 5 }, { index: 1 }, { index: 2 }] }

        expect(r.reload.steps.first["payload"]).to include("count" => 5)
      end

      it "drops the count entirely when it goes back to one" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 0, count: 1 }, { index: 1 }, { index: 2 }] }

        expect(r.reload.steps.first["payload"]).not_to have_key("count")
      end

      it "caps a count nobody meant to type" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 0, count: 900 }] }

        expect(r.reload.steps.first["payload"]["count"]).to eq(Buddy::RoutinesController::MAX_STEP_COUNT)
      end

      # A timer has no repeat semantics, so a count on it would be a number that
      # silently does nothing.
      it "ignores a count on a step that can't repeat" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 1, count: 4 }, { index: 0 }] }

        expect(r.reload.steps.first["payload"]).not_to have_key("count")
      end

      it "leaves everything else in the payload exactly as saved" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 1 }, { index: 0 }] }

        expect(r.reload.steps.first["payload"]).to eq("seconds" => 60, "then_continue" => true)
      end

      it "refuses to empty a routine out" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [] }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(tools_of(r).length).to eq(3)
      end

      # Reorder and prune, not add. Two of the same index is a dragging glitch.
      it "refuses to duplicate a step" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 0 }, { index: 0 }, { index: 1 }] }

        expect(tools_of(r)).to eq(%w[complete_chore set_timer])
      end

      # The panel and the record can be a moment apart, and a step that's already
      # gone is the outcome either way.
      it "shrugs off an index that isn't there any more" do
        r = routine!

        patch :steps, params: { id: r.id, steps: [{ index: 0 }, { index: 9 }] }

        expect(response).to be_successful
        expect(tools_of(r)).to eq(%w[complete_chore])
      end

      it "never reaches someone else's routine" do
        theirs = BuddyRoutine.create!(
          user:  create(:user),
          name:  "Theirs",
          steps: [
            BuddyRoutine.step(:log_event, { name: "Nope" }),
            BuddyRoutine.step(:log_event, { name: "Also nope" }),
          ],
        )

        patch :steps, params: { id: theirs.id, steps: [{ index: 0 }] }

        expect(response).not_to be_successful
        expect(theirs.reload.steps.length).to eq(2)
      end
    end

    describe "what the panel is handed to edit" do
      it "carries each step's original index, so that's all the client can send" do
        r = routine!

        get :index
        rows = response.parsed_body["routines"].find { |x| x["id"] == r.id }["step_rows"]

        expect(rows.pluck("index")).to eq([0, 1, 2])
      end

      # Read off the tool rather than guessed, so a step with no repeat semantics
      # gets no stepper instead of a control that does nothing.
      it "says which steps a count even applies to" do
        r = routine!

        get :index
        rows = response.parsed_body["routines"].find { |x| x["id"] == r.id }["step_rows"]

        expect(rows.pluck("countable")).to eq([true, false, true])
        expect(rows.first["count"]).to eq(3)
      end
    end
  end
end
