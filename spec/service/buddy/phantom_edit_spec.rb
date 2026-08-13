require "rails_helper"

# Two ways a turn can tell somebody a thing happened when nothing did, both from
# the 2026-08-12 audit and both fixed in the same place they went wrong.
RSpec.describe "Buddy edits that change nothing" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:chore) { create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car") }
  let(:ctx) { Buddy::ToolContext.new(user) }

  before { user.update!(chore_household_id: household.id) }

  # Prod byte_action 493. `edit_chore` was called with args `{chore: "Charge
  # Villager Car"}` and nothing else, on a turn where the person had asked for
  # two other things entirely. Its result read `updated_fields: []`, `before:
  # {}` — and it still posted "Updated Charge Villager Car ✓" over an undo row
  # that reverts nothing. `update_delivery` has had exactly this guard since it
  # shipped, for exactly this reason.
  describe "edit_chore with no field to change" do
    def confirm(payload) = Buddy::Tools[:edit_chore][:confirm].call(payload, ctx)

    it "refuses instead of reporting a successful edit of nothing" do
      expect { confirm(chore: "villager car") }
        .to raise_error(/nothing to change on Charge Villager Car/)
    end

    it "names the chore in the error, so the answer says which one it meant" do
      expect { confirm(chore: "villager car") }.to raise_error(/Charge Villager Car/)
    end

    # Everything the tool can actually change has to count as a reason to run.
    %i[name schedule due assignee priority disabled].each do |field|
      it "runs when #{field} was given" do
        value = {
          schedule: "every sunday",
          due:      "2026-09-01",
          assignee: user.first_name,
          priority: "high",
          disabled: "true",
        }.fetch(field, "Charge The Car")

        expect { confirm(chore: "villager car", field => value) }.not_to raise_error
      end
    end

    # A wrong value still has to reach its own error rather than this one; the
    # guard is about an EMPTY edit, not an invalid one.
    it "still refuses a priority it doesn't recognize on its own terms" do
      expect { confirm(chore: "villager car", priority: "urgent") }.to raise_error(/unknown priority/)
    end

    it "leaves the chore untouched" do
      expect { confirm(chore: "villager car") rescue nil }.not_to(change { chore.reload.updated_at })
    end
  end

  # Prod 3434 and 3436. An hourly repeat schedule_reminder couldn't parse came
  # back "Oop, that repeat shape didn't line up!" — with a cancel_reminder
  # button for the very reminder it had been trying to change, and on the second
  # attempt one for the standing daily plant reminder alongside it. She'd said
  # "Perfect!" to what she thought was the repeat being set. Neither row was
  # ever tapped, so nothing was lost, but the recovery on offer was deleting
  # what she'd asked to keep.
  describe "what a failed call tells the model to do next" do
    let(:note) { Buddy::GPT::Turn.resolve_failure("that repeat shape didn't line up")[:note] }

    it "says the record is untouched, so there is nothing to clean up" do
      expect(note).to include("untouched")
    end

    it "rules out deleting as a way out of it" do
      expect(note).to match(/do NOT offer to delete, cancel or remove/i)
    end

    it "says what to do instead" do
      expect(note).to include("Fix the arguments and call again")
    end

    it "still carries the older half - a failure is not a thing to report as done" do
      expect(note).to include("Do not say you did it")
      expect(Buddy::GPT::Turn.resolve_failure("x")[:status]).to eq("failed")
    end
  end
end
