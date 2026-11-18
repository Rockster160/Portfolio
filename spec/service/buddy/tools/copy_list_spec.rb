require "rails_helper"

RSpec.describe "copy_list tool" do
  let(:user) { create(:user) }
  let(:ctx)  { Buddy::ToolContext.new(user) }
  let(:tool) { Buddy::Tools[:copy_list] }
  let!(:tacos)     { create(:list, name: "Tacos", user: user) }
  let!(:groceries) { create(:list, name: "Groceries", user: user) }

  def confirm(from: "tacos", to: "groceries")
    tool[:confirm].call({ from: from, to: to }, ctx)
  end

  def execute(**)
    tool[:execute].call(confirm(**)[:resolved], ctx)
  end

  def names(list)
    list.reload.list_items.map(&:name)
  end

  it "copies every item onto the other list in the same order, leaving the source alone" do
    %w[Tortillas Cheese Salsa].each { |name| tacos.list_items.add(name) }

    result = execute

    expect(names(groceries)).to eq(names(tacos))
    expect(names(tacos)).to eq(%w[Salsa Cheese Tortillas])
    expect(tool[:receipt].call(result, ctx)).to eq("Copied 3 items from Tacos to Groceries ✓")
  end

  it "skips what's already on the target and doesn't double it" do
    tacos.list_items.add("Cheese")
    tacos.list_items.add("Salsa")
    groceries.list_items.add("cheese")

    result = execute

    expect(names(groceries)).to contain_exactly("cheese", "Salsa")
    expect(result[:skipped]).to eq(["Cheese"])
    expect(tool[:receipt].call(result, ctx)).to include("(1 already there)")
  end

  it "files into the target's section of the same name and carries the category" do
    produce = create(:section, list: tacos, name: "Produce")
    create(:list_item, list: tacos, name: "Cilantro", section: produce, category: "Mom")
    create(:list_item, list: tacos, name: "Limes", section: create(:section, list: tacos, name: "Fruit"))
    target = create(:section, list: groceries, name: "produce")

    execute

    cilantro = groceries.list_items.find_by(name: "Cilantro")
    expect(cilantro.section).to eq(target)
    expect(cilantro.category).to eq("Mom")
    expect(groceries.list_items.find_by(name: "Limes").section).to be_nil
    expect(groceries.sections.count).to eq(1)
  end

  it "undoes only the items it put there" do
    tacos.list_items.add("Cheese")
    tacos.list_items.add("Salsa")
    groceries.list_items.add("Cheese")
    groceries.list_items.add("Bread")

    result = execute
    Buddy::Reverter.descriptors(result).each { |rv| Buddy::Reverter.call(rv) }

    expect(names(groceries)).to contain_exactly("Cheese", "Bread")
    expect(names(tacos)).to contain_exactly("Cheese", "Salsa")
  end

  it "refuses an empty source, the same list twice, or a list that isn't there" do
    expect { confirm }.to raise_error(/nothing on it/)

    tacos.list_items.add("Cheese")
    expect { confirm(to: "tacos") }.to raise_error(/same list/)
    expect { confirm(to: "nowhere") }.to raise_error(/no list matching/)
  end
end
