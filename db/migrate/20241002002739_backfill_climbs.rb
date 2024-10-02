class BackfillClimbs < ActiveRecord::Migration[7.1]
  def up
    Climb.find_each do |climb|
      climb.update(
        scores: climb.data&.split(" ")&.map(&:to_i),
        total_pennies: climb.calculate_total && climb.total_pennies,
      )
    end
  end

  def down
    Climb.find_each do |climb|
      climb.update(
        scores: nil,
        total_pennies: nil,
      )
    end
  end
end
