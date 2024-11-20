RSpec.describe ApplicationRecord, type: :model do
  def query(str)
    sql = ActionEvent.query(str).to_sql
    sql[/\ASELECT \"action_events\"\.\* FROM \"action_events\" WHERE \((.*?)\)\z/, 1]
  end

  describe "nested conditions for an operator" do
    it "returns records matching a singular word" do
      sql = query("workout")
      expect(sql).to eq("((\"name\"::TEXT ILIKE '%workout%' OR \"notes\"::TEXT ILIKE '%workout%'))")
    end

    it "returns records matching multiple words" do
      sql = query("workout climbing")
      expect(sql).to eq("(((\"name\"::TEXT ILIKE '%workout%' OR \"notes\"::TEXT ILIKE '%workout%') AND (\"name\"::TEXT ILIKE '%climbing%' OR \"notes\"::TEXT ILIKE '%climbing%')))")
    end

    it "returns records matching words with negates" do
      sql = query("workout -climbing")
      expect(sql).to eq("(((\"name\"::TEXT ILIKE '%workout%' OR \"notes\"::TEXT ILIKE '%workout%') AND (NOT (\"name\"::TEXT ILIKE '%climbing%' OR \"notes\"::TEXT ILIKE '%climbing%'))))")
    end

    it "returns records for timestamps" do
      sql = query("wordle timestamp>'2020-01-01' timestamp<'2021-01-01'")
      expect(sql).to eq("(((\"name\"::TEXT ILIKE '%wordle%' OR \"notes\"::TEXT ILIKE '%wordle%') AND (timestamp > '2020-01-01 23:59:59.999999') AND (timestamp < '2021-01-01 23:59:59.999999')))")
    end

    it "returns records matching the query with AND conditions" do
      sql = query("name:(Workout Z 'Z*')")
      expect(sql).to eq("(((name ILIKE '%Workout%') AND (name ILIKE '%Z%') AND (name ILIKE '%Z*%')))")
    end

    it "returns records matching the query with OR conditions" do
      sql = query("name:(Workout OR Z OR 'Z*')")
      expect(sql).to eq("(((name ILIKE '%Workout%') OR (name ILIKE '%Z%') OR (name ILIKE '%Z*%')))")
    end

    it "returns records matching the query with id range and NOT conditions" do
      sql = query("id < 20 id > 10 -(Potter OR Rowling)")
      expect(sql).to eq("(((id < 20.0) AND (id > 10.0) AND (NOT ((\"name\"::TEXT ILIKE '%Potter%' OR \"notes\"::TEXT ILIKE '%Potter%') OR (\"name\"::TEXT ILIKE '%Rowling%' OR \"notes\"::TEXT ILIKE '%Rowling%')))))")
    end

    it "returns records matching the query with nested OR and NOT conditions" do
      sql = query("name::(zish OR \"z*\") NOT zip")
      expect(sql).to eq("((((name ILIKE 'zish') OR (name ILIKE 'z*')) AND (NOT (\"name\"::TEXT ILIKE '%zip%' OR \"notes\"::TEXT ILIKE '%zip%'))))")
    end

    it "returns records matching the query with nested OR and NOT conditions using dash" do
      sql = query("name::(zish OR \"z*\") -zip")
      expect(sql).to eq("((((name ILIKE 'zish') OR (name ILIKE 'z*')) AND (NOT (\"name\"::TEXT ILIKE '%zip%' OR \"notes\"::TEXT ILIKE '%zip%'))))")
    end

    it "returns based on a complex multi-query" do
      sql = query("timestamp>'2024-11-12T00:00:00-07:00' AND (name::(food OR drink OR treat OR snack OR soda) OR name::(workout OR Z OR Zish))")
      expect(sql).to eq("(((timestamp > '2024-11-12 07:00:00') AND (((name ILIKE 'food') OR (name ILIKE 'drink') OR (name ILIKE 'treat') OR (name ILIKE 'snack') OR (name ILIKE 'soda')) OR ((name ILIKE 'workout') OR (name ILIKE 'Z') OR (name ILIKE 'Zish')))))")
    end
  end
end
