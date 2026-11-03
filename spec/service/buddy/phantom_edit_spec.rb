require "rails_helper"

# An edit that changes nothing must refuse rather than report success, and a
# failed call must reach the model as failed.
RSpec.describe "Buddy edits that change nothing" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:chore) { create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car") }
  let(:ctx) { Buddy::ToolContext.new(user) }

  before { user.update!(chore_household_id: household.id) }

  describe "edit_chore with no field to change" do
    def confirm(payload) = Buddy::Tools[:edit_chore][:confirm].call(payload, ctx)

    it "refuses, naming the chore it meant, and leaves it untouched", :aggregate_failures do
      expect {
        expect { confirm(chore: "villager car") }.to raise_error(/Charge Villager Car/)
      }.not_to(change { chore.reload.updated_at })
    end

    # Everything the tool can actually change has to count as a reason to run.
    it "runs when any field it can change was given", :aggregate_failures do
      {
        name:     "Charge The Car",
        schedule: "every sunday",
        due:      "2026-09-01",
        assignee: user.first_name,
        priority: "high",
        disabled: "true",
      }.each do |field, value|
        expect { confirm(chore: "villager car", field => value) }.not_to raise_error, field.to_s
      end
    end

    # The guard is about an EMPTY edit, not an invalid one.
    it "still refuses a priority it doesn't recognize on its own terms" do
      expect { confirm(chore: "villager car", priority: "urgent") }.to raise_error(/unknown priority/)
    end
  end

  it "marks a failed call as failed for the model" do
    expect(Buddy::GPT::Turn.resolve_failure("that repeat shape didn't line up")[:status]).to eq("failed")
  end
end
