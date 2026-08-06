RSpec.describe ApplicationRecord, type: :model do
  def query(str)
    sql = ActionEvent.query(str).to_sql
    sql[/\ASELECT "action_events"\.\* FROM "action_events" WHERE \((.*?)\)\z/, 1].gsub("action_events.", "")
  end

  def expect_matching(sql, expected_sql)
    normalized = expected_sql.gsub(/\(\n */, "(").gsub(/\n *\)/, ")").gsub(/\n */, " ").squish
    normalized = normalized.gsub(/\( +/, "(").gsub(/ +\)/, ")")
    expect(sql).to eq(normalized)
  end

  let(:now) { ::Time.current }

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

    it "returns records matching words with negates" do
      sql = query("workout !climbing")
      expect(sql).to eq("(((\"name\"::TEXT ILIKE '%workout%' OR \"notes\"::TEXT ILIKE '%workout%') AND (NOT (\"name\"::TEXT ILIKE '%climbing%' OR \"notes\"::TEXT ILIKE '%climbing%'))))")
    end

    it "returns records with starting negates" do
      sql = query("-climbing")
      expect(sql).to eq("(NOT (\"name\"::TEXT ILIKE '%climbing%' OR \"notes\"::TEXT ILIKE '%climbing%'))")
    end

    # it "returns records with starting negates" do
    #   sql = query("-climbing workout")
    #   expect(sql).to eq("(NOT (\"name\"::TEXT ILIKE '%climbing%' OR \"notes\"::TEXT ILIKE '%climbing%') AND (\"name\"::TEXT ILIKE '%workout%' OR \"notes\"::TEXT ILIKE '%workout%'))")
    # end

    it "returns records with starting negates" do
      sql = query("!climbing")
      expect(sql).to eq("(NOT (\"name\"::TEXT ILIKE '%climbing%' OR \"notes\"::TEXT ILIKE '%climbing%'))")
    end

    it "returns records between timestamps" do
      # Just uses the generic "timestamp" word to figure out the column.
      # Maybe should add before|after as magic keywords?
      sql = query("wordle timestamp>'2020-01-01' timestamp<'2021-02-01'")
      expect(sql).to eq("(((\"name\"::TEXT ILIKE '%wordle%' OR \"notes\"::TEXT ILIKE '%wordle%') AND (timestamp > '2020-01-02 06:59:59.999999') AND (timestamp < '2021-02-01 07:00:00')))")
    end

    it "returns records on day" do
      sql = query("wordle timestamp:'2020-01-01'")
      expect(sql).to eq("(((\"name\"::TEXT ILIKE '%wordle%' OR \"notes\"::TEXT ILIKE '%wordle%') AND (timestamp >= '2020-01-01 07:00:00' AND timestamp <= '2020-01-02 06:59:59.999999')))")
    end

    it "returns records on/after day" do
      sql = query("wordle timestamp>='2020-01-01'")
      expect_matching sql, <<~SQL.squish
        (
          (
            ("name"::TEXT ILIKE '%wordle%' OR "notes"::TEXT ILIKE '%wordle%')
            AND (
              timestamp >= '2020-01-01 07:00:00'
            )
          )
        )
      SQL
    end

    it "returns records during month" do
      sql = query("wordle timestamp>='7-17'")
      expect_matching sql, <<~SQL.squish
        (
          (
            ("name"::TEXT ILIKE '%wordle%' OR "notes"::TEXT ILIKE '%wordle%')
            AND (
              timestamp >= '#{now.year}-07-17 06:00:00'
            )
          )
        )
      SQL
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
      expect(sql).to eq("(((id < 20) AND (id > 10) AND (NOT ((\"name\"::TEXT ILIKE '%Potter%' OR \"notes\"::TEXT ILIKE '%Potter%') OR (\"name\"::TEXT ILIKE '%Rowling%' OR \"notes\"::TEXT ILIKE '%Rowling%')))))")
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

    it "returns records matching id with colon operator" do
      sql = query("id:44045")
      expect(sql).to eq("((id = 44045))")
    end

    it "returns records matching id with double-colon operator" do
      sql = query("id::44045")
      expect(sql).to eq("((id = 44045))")
    end

    it "returns records matching multiple ids with OR" do
      sql = query("(id::44045 OR id::44063 OR id::44119)")
      expect(sql).to eq("(((id = 44045) OR (id = 44063) OR (id = 44119)))")
    end

    it "returns records matching multiple ids with field-level OR" do
      sql = query("id::(44045 OR 44063 OR 44119)")
      expect(sql).to eq("(((id = 44045) OR (id = 44063) OR (id = 44119)))")
    end
  end

  describe "generic jsonb key search" do
    it "matches a key exactly" do
      sql = query("data:transfer::true")
      expect(sql).to eq("((data->>'transfer' ILIKE 'true'))")
    end

    it "matches a key by substring" do
      sql = query("data:merchant:VENMO")
      expect(sql).to eq("((data->>'merchant' ILIKE '%VENMO%'))")
    end

    it "treats a missing key as not-equal so sparse jsonb stays included" do
      sql = query("data:transfer!::true")
      expect(sql).to eq("((data->>'transfer' IS NULL OR data->>'transfer' NOT ILIKE 'true'))")
    end

    it "treats a missing key as not-containing" do
      sql = query("data:merchant!:VENMO")
      expect(sql).to eq("((data->>'merchant' IS NULL OR data->>'merchant' NOT ILIKE '%VENMO%'))")
    end

    it "guards the numeric cast on comparisons" do
      sql = query("data:amount>100")
      expect(sql).to eq(
        "((data->>'amount' ~ '^-?[0-9]+(\\.[0-9]+)?$' AND (data->>'amount')::numeric > 100.0))",
      )
    end

    it "combines with a regular column term" do
      sql = query("name::Transaction data:transfer!::true")
      expect(sql).to eq(
        "(((name ILIKE 'Transaction') AND (data->>'transfer' IS NULL OR data->>'transfer' NOT ILIKE 'true')))",
      )
    end

    it "composes with OR across keys" do
      sql = query("data:transfer::true OR data:merchant::VENMO")
      expect(sql).to eq("(((data->>'transfer' ILIKE 'true') OR (data->>'merchant' ILIKE 'VENMO')))")
    end
  end

  describe "generic jsonb key search — records" do
    let(:user) { User.me }

    let!(:transfer) {
      user.action_events.create!(name: "Transaction", notes: "CHASE CREDIT CRD", data: {
        merchant: "CHASE CREDIT CRD", amount: 6383.52, transfer: true
      })
    }
    let!(:purchase) {
      user.action_events.create!(name: "Transaction", notes: "COSTCO WHSE #1441", data: {
        merchant: "COSTCO WHSE #1441", amount: 123.45, transfer: false
      })
    }
    # Predates the key entirely.
    let!(:legacy) {
      user.action_events.create!(name: "Transaction", notes: "NETFLIX.COM", data: {
        merchant: "NETFLIX.COM", amount: 21.48
      })
    }

    after { [transfer, purchase, legacy].each(&:destroy) }

    it "excludes only the flagged rows, keeping ones with no key" do
      results = user.action_events.query("name::Transaction data:transfer!::true")
      expect(results).to include(purchase, legacy)
      expect(results).not_to include(transfer)
    end

    it "selects only the flagged rows" do
      expect(user.action_events.query("data:transfer::true")).to contain_exactly(transfer)
    end

    it "compares numerically without choking on non-numeric keys in other rows" do
      user.action_events.create!(name: "Transaction", notes: "odd", data: { amount: "n/a" })

      expect(user.action_events.query("data:amount>1000")).to contain_exactly(transfer)
    end
  end
end
