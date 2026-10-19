# Jil's way onto the Meal Builder pages, so a food logged once can be picked
# from the builder after.
class Jil::Methods::MealBuilder < Jil::Methods::Base
  def cast(value)
    value
  end

  # MealBuilder.add("Food", "Boiled egg", 100) -> true once it's on a builder,
  # false when there's no builder or no name.
  def add(category, name, calories)
    builder = ::MealBuilder.where(user: @jil.user).for_category(category)
    return false if builder.nil?

    builder.add_item!(category: category, name: name, cal: calories)
  end
end
