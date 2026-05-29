require "rails_helper"

RSpec.describe "Chore + ChoreCompletion Jil triggers", type: :model do
  let(:user) { create(:user) }

  it "creating a chore fires `chore` trigger with action: :created" do
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :created && attrs[:name] == "Vacuum" }
    )
    create(:chore, created_by_user: user, name: "Vacuum")
  end

  it "updating a chore fires action: :updated" do
    chore = create(:chore, created_by_user: user, name: "V")
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :updated }
    )
    chore.update!(name: "Vacuum")
  end

  it "archiving a chore (archived_at flip) fires action: :archived" do
    chore = create(:chore, created_by_user: user, name: "V")
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :archived }
    )
    chore.update!(archived_at: Time.current)
  end

  it "destroying a chore fires action: :destroyed" do
    chore = create(:chore, created_by_user: user, name: "V")
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :destroyed }
    )
    chore.destroy!
  end

  it "creating a completion fires `chore_completion` action: :completed" do
    chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 4)
    expect(::Jil).to receive(:trigger).with(
      user, :chore_completion,
      satisfy { |a| a[:action] == :completed && a[:chore_name] == "Walk" && a[:paid_pebbles] == 4 }
    )
    ChoreCompleter.new(chore, user).call
  end

  it "destroying a completion fires `chore_completion` action: :uncompleted" do
    chore = create(:chore, created_by_user: user, name: "Walk")
    completion = ChoreCompleter.new(chore, user).call.completion
    expect(::Jil).to receive(:trigger).with(
      user, :chore_completion,
      satisfy { |a| a[:action] == :uncompleted && a[:chore_name] == "Walk" }
    )
    completion.destroy!
  end
end
