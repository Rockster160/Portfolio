require "rails_helper"

# Buddy previously fell back to log_event because it only ever saw the
# today/overdue/hot chore buckets. `chores_all` gives it the complete active
# roster to match completions against.
RSpec.describe Buddy::Context, ".build chores_all" do
  it "lists every active chore (even ones not due today) and excludes archived" do
    user = create(:user)
    create(:chore, name: "Recycling Out", created_by_user: user)
    user.reload
    create(:chore, name: "Water Plants", created_by_user: user, chore_household: user.chore_household)
    archived = create(:chore, name: "Old Thing", created_by_user: user, chore_household: user.chore_household)
    archived.update!(archived_at: Time.current)

    roster = described_class.build(user)[:chores_all]

    expect(roster).to include("Recycling Out", "Water Plants")
    expect(roster).not_to include("Old Thing")
  end

  it "is an empty list for a user with no household" do
    user = create(:user)
    user.update_column(:chore_household_id, nil)
    expect(described_class.build(user)[:chores_all]).to eq([])
  end
end
