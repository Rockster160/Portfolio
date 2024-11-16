RSpec.describe ApplicationRecord, type: :model do
  def query(str)
    sql = ActionEvent.query(str).to_sql
    sql[/\ASELECT \"action_events\"\.\* FROM \"action_events\" WHERE \((.*?)\)\z/, 1]
  end

  describe "nested conditions for an operator" do
    it "returns records matching the query with AND conditions" do
      sql = query("name:(Workout Z 'Z*')")
      expect(sql).to eq("((name ILIKE '%Workout%') AND (name ILIKE '%Z%') AND (name ILIKE '%Z*%'))")
    end

    it "returns records matching the query with OR conditions" do
      sql = query("name:(Workout OR Z OR 'Z*')")
      expect(sql).to eq("((name ILIKE '%Workout%') OR (name ILIKE '%Z%') OR (name ILIKE '%Z*%'))")
    end

    it "returns records matching the query with price range and NOT conditions" do
      sql = query("price < 20 price > 10 -(Potter OR Rowling)")
      expect(sql).to eq("((NOT (((\"name\"::TEXT ILIKE '%Potter%' OR \"notes\"::TEXT ILIKE '%Potter%') OR (\"name\"::TEXT ILIKE '%Rowling%' OR \"notes\"::TEXT ILIKE '%Rowling%'))")
    end

    it "returns records matching the query with nested OR and NOT conditions" do
      sql = query("name::(zish OR \"z*\") NOT zip")
      expect(sql).to eq("((name ILIKE 'zish') OR (name ILIKE 'z*')) AND (NOT ((\"name\"::TEXT ILIKE '%zip%' OR \"notes\"::TEXT ILIKE '%zip%'))")
    end

    it "returns records matching the query with nested OR and NOT conditions using dash" do
      sql = query("name::(zish OR \"z*\") -zip")
      expect(sql).to eq("((name ILIKE 'zish') OR (name ILIKE 'z*')) AND (NOT ((\"name\"::TEXT ILIKE '%zip%' OR \"notes\"::TEXT ILIKE '%zip%'))")
    end
  end
end
