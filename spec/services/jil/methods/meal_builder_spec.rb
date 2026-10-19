RSpec.describe Jil::Methods::MealBuilder do
  let(:user) { create(:user) }
  let!(:food) { MealBuilder.create!(user: user, name: "Food", items: []) }
  let!(:drink) { MealBuilder.create!(user: user, name: "Drink", items: []) }

  def add(category, name, calories)
    code = <<~JIL
      added = MealBuilder.add("#{category}", "#{name}", #{calories})::Boolean
    JIL
    Jil::Validator.validate!(code)
    Jil::Executor.call(user, code).ctx.dig(:vars, :added, :value)
  end

  it "puts it on the builder named for its category" do
    expect(add("drink", "Iced oat latte", 180)).to be(true)

    expect(drink.reload.items.sole).to include(category: "Drink", name: "Iced oat latte", cal: 180)
    expect(food.reload.items).to be_empty
  end

  it "falls back to Food for a category with no builder of its own" do
    add("Treat", "Churro", 250)

    expect(food.reload.items.sole).to include(category: "Treat", name: "Churro", cal: 250)
  end

  it "leaves one already there alone" do
    add("Food", "Boiled egg", 100)

    expect(add("Food", "boiled EGG", 90)).to be(true)
    expect(food.reload.items.sole).to include(name: "Boiled egg", cal: 100)
  end

  it "says no when there is nowhere to put it" do
    MealBuilder.where(user: user).delete_all

    expect(add("Food", "Boiled egg", 100)).to be(false)
  end
end
