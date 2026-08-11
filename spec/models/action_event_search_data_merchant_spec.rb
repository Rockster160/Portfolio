require "rails_helper"

# `merchant:` raised PG::SyntaxError for every query until 2026-08-11: the
# search pipeline strips the parentheses from `ILIKE ANY (array[...])` when it
# extracts a scope's WHERE clause, leaving invalid SQL. Nothing covered it, so
# nothing caught it.
RSpec.describe ActionEvent, ".search_data_merchant" do
  let(:user) { User.me }

  def event(merchant)
    described_class.create!(
      user: user, name: "Transaction", timestamp: 1.day.ago,
      data: { amount: 10, merchant: merchant, category: "other" }
    )
  end

  it "does not raise" do
    expect { described_class.query("merchant:amazon").count }.not_to raise_error
  end

  it "matches on a substring, case-insensitively" do
    amazon = event("AMAZON MKTPLACE PMTS")
    event("TST* HOUSTON S HOT C")

    expect(described_class.query("merchant:amazon")).to contain_exactly(amazon)
  end

  it "combines with another term" do
    amazon = event("AMAZON MKTPLACE PMTS")
    amazon.update!(notes: "Solder iron")
    event("AMAZON PRIME*6A0Y98FQ3")

    expect(described_class.query("merchant:amazon notes:solder")).to contain_exactly(amazon)
  end

  it "negates" do
    event("AMAZON MKTPLACE PMTS")
    other = event("NETFLIX.COM")

    expect(described_class.query("-merchant:amazon")).to include(other)
    expect(described_class.query("-merchant:amazon")).not_to include(
      described_class.find_by("data->>'merchant' = ?", "AMAZON MKTPLACE PMTS"),
    )
  end

  it "matches nothing on a blank term rather than everything" do
    event("AMAZON MKTPLACE PMTS")

    expect(described_class.search_data_merchant("")).to be_empty
  end
end
