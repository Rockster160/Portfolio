require "rails_helper"

RSpec.describe ChoreDaily, type: :model do
  let(:user)  { create(:user) }
  let(:chore) { create(:chore, created_by_user: user) }

  it "validates uniqueness of (user, chore)" do
    described_class.create!(user: user, chore: chore, sort_order: 0)
    dup = described_class.new(user: user, chore: chore, sort_order: 1)
    expect(dup).not_to be_valid
    expect(dup.errors[:chore_id]).to be_present
  end

  it "for_user returns the viewer's pins ordered by sort_order" do
    c1 = create(:chore, created_by_user: user)
    c2 = create(:chore, created_by_user: user)
    c3 = create(:chore, created_by_user: user)
    described_class.create!(user: user, chore: c1, sort_order: 2)
    described_class.create!(user: user, chore: c2, sort_order: 0)
    described_class.create!(user: user, chore: c3, sort_order: 1)
    expect(described_class.for_user(user).pluck(:chore_id)).to eq([c2.id, c3.id, c1.id])
  end

  it "is destroyed when the chore is destroyed" do
    daily = described_class.create!(user: user, chore: chore, sort_order: 0)
    chore.destroy
    expect(described_class.where(id: daily.id)).to be_empty
  end
end
