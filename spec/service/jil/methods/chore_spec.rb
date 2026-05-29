require "rails_helper"

RSpec.describe Jil::Methods::Chore, type: :service do
  let(:user) { create(:user) }
  let!(:vitamins) { create(:chore, created_by_user: user, name: "Vitamins", reward_pebbles: 1) }
  let!(:floss) { create(:chore, created_by_user: user, name: "Floss",  reward_pebbles: 1) }

  # Minimal Jil double — `@jil.user` is the only contract this module
  # leans on, so a struct stands in for the full executor.
  let(:jil_stub) { instance_double("Jil::Executor", user: user, ctx: nil) }
  subject(:methods) { described_class.new(jil_stub) }

  it "find('Vit') returns the matching chore" do
    expect(methods.find("Vit")).to eq(vitamins)
  end

  it "complete creates a completion and returns it" do
    expect { methods.complete("Vitamins") }.to change(ChoreCompletion, :count).by(1)
    completion = ChoreCompletion.order(:id).last
    expect(completion.chore_id).to eq(vitamins.id)
    expect(completion.user_id).to eq(user.id)
  end

  it "complete with a timestamp records the supplied time" do
    when_at = Time.zone.local(2026, 4, 1, 7, 30, 0)
    methods.complete("Floss", when_at.iso8601)
    completion = ChoreCompletion.order(:id).last
    expect(completion.completed_at.to_i).to eq(when_at.to_i)
  end

  it "uncomplete destroys today's most recent completion" do
    ChoreCompleter.new(vitamins, user).call
    expect { methods.uncomplete("Vitamins") }.to change(ChoreCompletion, :count).by(-1)
  end

  it "balance + today_earnings reflect completions" do
    ChoreCompleter.new(vitamins, user).call
    expect(methods.balance).to eq(1)
    expect(methods.today_earnings).to eq(1)
  end
end
