require "rails_helper"

RSpec.describe Chore, "target_count", type: :model do
  let(:user) { create(:user) }

  it "defaults to 1 when not specified" do
    chore = create(:chore, created_by_user: user)
    expect(chore.target_count).to eq(1)
  end

  it "persists a custom target" do
    chore = create(:chore, created_by_user: user, target_count: 5)
    expect(chore.reload.target_count).to eq(5)
  end

  it "rejects values below 1" do
    chore = build(:chore, created_by_user: user, target_count: 0)
    expect(chore).not_to be_valid
    expect(chore.errors[:target_count]).to be_present
  end

  it "rejects negative values" do
    chore = build(:chore, created_by_user: user, target_count: -1)
    expect(chore).not_to be_valid
  end

  it "rejects values above 99" do
    chore = build(:chore, created_by_user: user, target_count: 100)
    expect(chore).not_to be_valid
  end

  it "accepts the upper bound" do
    chore = build(:chore, created_by_user: user, target_count: 99)
    expect(chore).to be_valid
  end

  it "includes target_count in jil_attrs payload" do
    chore = create(:chore, created_by_user: user, target_count: 4)
    payload = chore.jil_attrs(action: :created)
    expect(payload[:target_count]).to eq(4)
  end
end
