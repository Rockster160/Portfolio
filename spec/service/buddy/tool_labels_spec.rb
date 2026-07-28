require "rails_helper"

# The confirm-card labels favour readability for a human reviewer: one
# non-default detail per line (newlines, not a comma run), the kind chip
# carries the verb (no "Delete:"/"Undo:" in the title), and symbols stand in
# for obvious labels (@ location, 📋 list).
RSpec.describe "Buddy tool confirm-card labels" do
  let(:user) { create(:user) }
  let(:ctx)  { Buddy::ToolContext.new(user) }

  def label(name, payload)
    Buddy::Tools[name][:label].call(payload, ctx)
  end

  it "edit tools stack each field change on its own line (no comma run)" do
    out = label(:edit_chore, { chore: "Dishes", name: "Do Dishes", schedule: "every day" })
    expect(out[:title]).to eq("Dishes")
    expect(out[:sub]).not_to include(", ")
    expect(out[:sub].split("\n")).to include("name → Do Dishes", "schedule → every day")
  end

  it "list tools use a 📋 symbol for the list instead of a word-label" do
    add = label(:add_list_item, { item: "oat milk", list_name: "Groceries" })
    expect(add).to eq(title: "oat milk", sub: "📋 Groceries")
  end

  it "destructive tools KEEP the verb in the title (high-stakes, unmistakable)" do
    expect(label(:delete_event, { event: "Coffee" })[:title]).to eq("Delete Coffee")
    expect(label(:remove_list_item, { item: "oat milk", list_name: "Groceries" })[:title]).to eq("Remove oat milk")
  end

  it "log_event puts short notes on their own line, not glued with a dash" do
    out = label(:log_event, { name: "Coffee", notes: "oat milk, 8oz" })
    expect(out).to eq(title: "Coffee", sub: "oat milk, 8oz")
  end
end
