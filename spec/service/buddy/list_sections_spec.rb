require "rails_helper"

# Buddy's awareness of list SECTIONS (the structured, colored groupings on a
# list) and the chore-completion note surfacing on the confirm card.
RSpec.describe "Buddy list sections + completion notes" do
  let(:user) { create(:user) }
  let(:ctx)  { Buddy::ToolContext.new(user) }

  def run(name, payload)
    tool = Buddy::Tools[name]
    confirm = tool[:confirm].call(payload, ctx)
    merged  = payload.merge(confirm[:resolved] || {})
    { confirm: confirm, label: tool[:label].call(merged, ctx), merged: merged, tool: tool }
  end

  # ---- Task 1: chore-completion note shows on the preview ----

  describe "complete_chore label" do
    it "puts the note on its own line so it's visible before confirming" do
      out = Buddy::Tools[:complete_chore][:label].call(
        { chore: "Dishes", note: "used the good soap" }, ctx
      )
      expect(out[:title]).to eq("Dishes")
      expect(out[:sub].split("\n")).to include("📝 used the good soap")
    end

    it "omits the note line when there's no note" do
      out = Buddy::Tools[:complete_chore][:label].call({ chore: "Dishes" }, ctx)
      expect(out[:sub]).to be_nil
    end
  end

  # ---- Task 2: sections in context + used by the list tools ----

  describe "context lists" do
    it "lists each list with its section names, ordered, dropping empties" do
      groceries = create(:list, user: user, name: "Groceries")
      create(:section, list: groceries, name: "Produce", sort_order: 2)
      create(:section, list: groceries, name: "Dairy",   sort_order: 1)
      create(:list, user: user, name: "Todos") # no sections

      lists = Buddy::Context.send(:lists, user)[:items]
      groceries_entry = lists.find { |l| l[:name] == "Groceries" }
      todos_entry     = lists.find { |l| l[:name] == "Todos" }

      expect(groceries_entry[:sections]).to eq(%w[Produce Dairy]) # sort_order DESC
      expect(todos_entry).not_to have_key(:sections)
    end
  end

  describe "add_list_item with a real section" do
    let!(:list)    { create(:list, user: user, name: "Groceries") }
    let!(:section) { create(:section, list: list, name: "Harmon's") }

    it "resolves a matching section (case-insensitive) and files the item into it" do
      res = run(:add_list_item, { list: "Groceries", item: "sanitizer", section: "harmons" })

      expect(res[:merged][:section_id]).to eq(section.id)
      expect(res[:merged][:section_name]).to eq("Harmon's")
      expect(res[:confirm][:summary]).to eq("Add sanitizer to Groceries under Harmon's?")
      expect(res[:label][:sub]).to eq("📋 Groceries › Harmon's")

      res[:tool][:execute].call(res[:merged], ctx)
      item = list.list_items.reload.find { |i| i.name == "sanitizer" }
      expect(item.section_id).to eq(section.id)
      expect(item.category).to be_nil
    end

    # The older shape, still in the model's habits: `category` carrying the
    # placement. It resolves to the real section rather than a duplicate label.
    it "treats a category naming a real section as the section" do
      res = run(:add_list_item, { list: "Groceries", item: "sanitizer", category: "harmons" })

      expect(res[:merged][:section_id]).to eq(section.id)
      expect(res[:merged][:category]).to be_nil
    end

    it "keeps an unmatched placement as a plain label (no section)" do
      res = run(:add_list_item, { list: "Groceries", item: "milk", section: "back fridge" })

      expect(res[:merged]).not_to have_key(:section_id)
      expect(res[:label][:sub]).to eq("📋 Groceries\n🏷️ back fridge")

      res[:tool][:execute].call(res[:merged], ctx)
      item = list.list_items.reload.find { |i| i.name == "milk" }
      expect(item.section_id).to be_nil
      expect(item.category).to eq("Back Fridge") # titleized by the model
    end

    # Prod 1236: "a chicken salad for mom to Shopping at Costco" put Costco in
    # line with the list and dropped "mom" entirely. They're separate questions.
    it "carries a section and a category at the same time" do
      res = run(:add_list_item, { list: "Groceries", item: "Chicken salad", section: "Harmon's", category: "Mom" })

      expect(res[:merged][:section_name]).to eq("Harmon's")
      expect(res[:merged][:category]).to eq("Mom")
      expect(res[:label][:sub]).to eq("📋 Groceries › Harmon's\n🏷️ Mom")

      res[:tool][:execute].call(res[:merged], ctx)
      item = list.list_items.reload.find { |i| i.name == "Chicken salad" }
      expect(item.section_id).to eq(section.id)
      expect(item.category).to eq("Mom")
    end
  end

  describe "edit_list_item moving into a section" do
    let!(:list)    { create(:list, user: user, name: "Groceries") }
    let!(:section) { create(:section, list: list, name: "Dairy") }

    it "moves the item into the matched section and drops a category that was the placement" do
      item = list.list_items.create!(name: "milk", category: "Dairy")
      res  = run(:edit_list_item, { list: "Groceries", item: "milk", section: "dairy" })

      expect(res[:merged][:section_id]).to eq(section.id)
      expect(res[:label][:sub]).to include("› Dairy")

      res[:tool][:execute].call(res[:merged], ctx)
      expect(item.reload.section_id).to eq(section.id)
      expect(item.category).to be_nil
    end

    it "leaves a category that means something else alone" do
      item = list.list_items.create!(name: "milk", category: "Mom")
      res  = run(:edit_list_item, { list: "Groceries", item: "milk", section: "dairy" })

      res[:tool][:execute].call(res[:merged], ctx)
      expect(item.reload.section_id).to eq(section.id)
      expect(item.category).to eq("Mom")
    end
  end
end
