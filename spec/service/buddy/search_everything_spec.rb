require "rails_helper"

RSpec.describe Buddy::SearchEverything do
  let(:user) { create(:user) }
  let(:list) { create(:list, name: "Pharmacy", user: user) }

  before do
    household = ChoreHousehold.create!(name: "Ours", owner_user: user)
    user.update!(chore_household_id: household.id)
    create(:chore, created_by_user: user, chore_household: household, name: "Vitamins")
    ActionEvent.create!(user: user, name: "Vitamins", timestamp: 1.day.ago)
    create(:list_item, list: list, name: "Vitamins")
  end

  def kinds(groups)
    groups.pluck(:kind)
  end

  it "puts one name found in several kinds in front of the model side by side" do
    groups = described_class.call(user: user, query: "vitamins")

    expect(kinds(groups)).to include(:chores, :events, :list_items)
    expect(groups.find { |group| group[:kind] == :list_items }[:hits].first).to include("Vitamins", "Pharmacy")
  end

  it "names the tools that act on each kind" do
    groups = described_class.call(user: user, query: "vitamins")

    expect(groups.find { |group| group[:kind] == :events }[:acts_with]).to include(:log_event)
  end

  it "never points at a tool the person isn't offered" do
    offered = Buddy::Tools.offered(user: user).reject { |tool| tool[:name] == :complete_chore }
    allow(Buddy::Tools).to receive(:offered).and_return(offered)

    chores = described_class.call(user: user, query: "vitamins").find { |group| group[:kind] == :chores }

    expect(chores[:acts_with]).not_to include(:complete_chore)
  end

  it "comes back empty when nothing is called that" do
    expect(described_class.call(user: user, query: "zebra saddle")).to eq([])
  end
end
