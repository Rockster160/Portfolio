require "rails_helper"

# Rearranging the steps a routine already has: drop one, drag them into a
# different order, change how many times one runs.
#
# What this endpoint deliberately can't do is compose a step. The client sends
# back the ORIGINAL index of each step it's keeping, so the worst a bug on that
# side can do is reorder or lose a step - never invent a broken one, which is
# the failure that made `update` refuse `steps` in the first place.
RSpec.describe Buddy::RoutinesController, type: :controller do
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
