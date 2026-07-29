require "rails_helper"

RSpec.describe "Buddy create_chore tool" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

  before { user.update!(chore_household_id: household.id) }

  def run(payload)
    tool = Buddy::Tools[:create_chore]
    ctx  = Buddy::ToolContext.new(user)
    confirm = tool[:confirm].call(payload, ctx)
    resolved = payload.merge(confirm[:resolved])
    exec = Buddy::ToolContext.new(user)
    [tool[:execute].call(resolved, exec), resolved, tool]
  end

  describe Buddy::ChoreScheduleParser do
    it "parses common recurrence phrasings into the chore hash shape" do
      expect(described_class.parse("daily")).to eq("freq" => "daily")
      expect(described_class.parse("every weekday")).to eq("freq" => "weekdays")
      expect(described_class.parse("every 3 days")).to eq("freq" => "custom", "interval" => 3, "unit" => "day")
      expect(described_class.parse("every Sunday")).to eq("freq" => "weekly", "by_day" => %w[sun])
      expect(described_class.parse("mondays and wednesdays")).to eq("freq" => "weekly", "by_day" => %w[mon wed])
      expect(described_class.parse("monthly on the 1st")).to eq("freq" => "monthly", "by_month_day" => [1])
      expect(described_class.parse("yearly")).to eq("freq" => "yearly")
    end

    it "returns nil for blank / one-off, and never an empty-by_day weekly" do
      expect(described_class.parse("")).to be_nil
      expect(described_class.parse("one-off")).to be_nil
      weekly = described_class.parse("weekly", on: Date.new(2026, 7, 28)) # a Tuesday
      expect(weekly).to eq("freq" => "weekly", "by_day" => %w[tue])
    end
  end

  describe Buddy::PebbleGuide do
    it "guesses a non-zero reward by effort" do
      expect(described_class.guess("Deep clean the garage")).to eq(10)
      expect(described_class.guess("Drink water")).to eq(1)
      expect(described_class.guess("Tidy the entryway")).to eq(3)
    end
  end

  it "creates a scheduled chore through the proper flow with icon + reward + recurrence" do
    result, = run({ name: "Water the ficus", schedule: "every Sunday" })
    chore = Chore.find(result[:chore_id])

    expect(chore.recurrence).to eq("freq" => "weekly", "by_day" => %w[sun])
    expect(chore.reward_pebbles).to be > 0            # guessed, never 0
    expect(chore.icon).to be_present                  # never blank
    expect(chore.created_by_user).to eq(user)
    expect(chore.chore_household).to eq(household)
  end

  it "honors an explicit reward and one-off (no recurrence)" do
    result, = run({ name: "Return the ladder", reward: 5, one_off: "true" })
    chore = Chore.find(result[:chore_id])

    expect(chore.reward_pebbles).to eq(5)
    expect(chore.one_off).to be(true)
    expect(chore.scheduled?).to be(false)
  end

  it "nests a chore under a parent" do
    parent = household.chores.create!(created_by_user: user, name: "Kitchen")
    result, = run({ name: "Wipe counters", parent: "Kitchen" })
    chore = Chore.find(result[:chore_id])

    expect(chore.parent_chore_id).to eq(parent.id)
  end

  it "wires an after-chore dependency" do
    laundry = household.chores.create!(created_by_user: user, name: "Laundry")
    _result, resolved, = run({ name: "Fold laundry", after: "Laundry" })

    expect(resolved[:recurrence]).to include("freq" => "after_chore", "anchor_chore_id" => laundry.id)
  end

  it "surfaces the non-standard customizations on the row label" do
    _result, resolved, tool = run({ name: "Water the ficus", schedule: "every Sunday", reward: 2 })
    label = tool[:label].call(resolved, Buddy::ToolContext.new(user))

    expect(label[:title]).to eq("Water the ficus")
    expect(label[:sub]).to include("every Sunday").and include("2p")
  end
end
