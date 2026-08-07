require "rails_helper"

RSpec.describe "Buddy chore priority" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

  before { user.update!(chore_household_id: household.id) }

  def run(tool_name, payload)
    tool = Buddy::Tools[tool_name]
    confirm = tool[:confirm].call(payload, Buddy::ToolContext.new(user))
    resolved = payload.merge(confirm[:resolved])
    [tool[:execute].call(resolved, Buddy::ToolContext.new(user)), resolved, tool]
  end

  describe "create_chore" do
    it "sets the priority the person asked for" do
      result, = run(:create_chore, { name: "Fix the roof leak", priority: "critical" })
      expect(Chore.find(result[:chore_id]).priority).to eq("critical")
    end

    it "leaves it at normal when they didn't say" do
      result, = run(:create_chore, { name: "Water the ficus" })
      expect(Chore.find(result[:chore_id]).priority).to eq("normal")
    end

    it "rejects a word that isn't a level instead of silently defaulting" do
      expect { run(:create_chore, { name: "Fix the roof", priority: "urgent" }) }
        .to raise_error(/unknown priority/)
    end

    it "shows the priority on the proposal label" do
      _, resolved, tool = run(:create_chore, { name: "Fix the roof leak", priority: "high" })
      label = tool[:label].call(resolved, Buddy::ToolContext.new(user))
      expect(label[:sub]).to include("high priority")
    end
  end

  describe "edit_chore" do
    let!(:chore) { create(:chore, created_by_user: user, name: "Litter Box", priority: :normal) }

    it "moves an existing chore's priority" do
      run(:edit_chore, { chore: "Litter Box", priority: "high" })
      expect(chore.reload.priority).to eq("high")
    end

    it "normalizes casing" do
      run(:edit_chore, { chore: "Litter Box", priority: "  Critical " })
      expect(chore.reload.priority).to eq("critical")
    end

    it "rejects an unknown level" do
      expect { run(:edit_chore, { chore: "Litter Box", priority: "asap" }) }
        .to raise_error(/unknown priority/)
      expect(chore.reload.priority).to eq("normal")
    end

    it "leaves priority alone when the edit is about something else" do
      chore.update!(priority: :high)
      run(:edit_chore, { chore: "Litter Box", name: "Litter Box Scoop" })

      expect(chore.reload.name).to eq("Litter Box Scoop")
      expect(chore.priority).to eq("high")
    end

    it "snapshots the prior priority so the edit can be reverted" do
      result, = run(:edit_chore, { chore: "Litter Box", priority: "none" })
      expect(result[:revert][:before]).to include(priority: "normal")
    end
  end

  describe "context visibility" do
    it "surfaces a non-default priority on the chore's context row" do
      chore = create(:chore, created_by_user: user, priority: :critical)
      slim = Buddy::Context.send(:slim_chore, chore)
      expect(slim[:priority]).to eq("critical")
    end

    it "omits the field entirely for an ordinary chore" do
      chore = create(:chore, created_by_user: user, priority: :normal)
      slim = Buddy::Context.send(:slim_chore, chore)
      expect(slim).not_to have_key(:priority)
    end
  end
end
