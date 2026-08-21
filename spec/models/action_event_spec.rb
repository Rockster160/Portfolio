# == Schema Information
#
# Table name: action_events
#
#  id            :integer          not null, primary key
#  name          :text
#  user_id       :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  timestamp     :datetime
#  notes         :text
#  streak_length :integer
#  data          :jsonb
#

require "rails_helper"

RSpec.describe ActionEvent do
  describe "the model" do
    let(:user) { User.me }

    describe "data source key search" do
      let!(:phone_only) do
        user.action_events.create!(name: "arrived", notes: "SpecTown", data: {
          phone: { lat: 40.5, lng: -111.5, name: "SpecTown" },
        })
      end
      let!(:multi_source) do
        user.action_events.create!(name: "arrived", notes: "SpecTown", data: {
          phone: { lat: 40.6, lng: -111.6, name: "SpecTown" },
          car:   { lat: 41.0, lng: -112.0, name: "OtherPlace" },
        })
      end
      let!(:legacy_event) do
        user.action_events.create!(name: "arrived", notes: "SpecTown", data: {})
      end

      after do
        [phone_only, multi_source, legacy_event].each(&:destroy)
      end

      it "matches events whose data has the given source key" do
        results = described_class.search_data_source(:phone)
        expect(results).to include(phone_only, multi_source)
        expect(results).not_to include(legacy_event)
      end

      it "matches multi-source events on either key" do
        expect(described_class.search_data_source(:car)).to contain_exactly(multi_source)
      end

      it "is queryable via search_terms alias data_source" do
        results = user.action_events.query('data_source::"car"')
        expect(results).to contain_exactly(multi_source)
      end
    end
  end

  # `merchant:` raised PG::SyntaxError for every query until 2026-08-11: the
  # search pipeline strips the parentheses from `ILIKE ANY (array[...])` when it
  # extracts a scope's WHERE clause, leaving invalid SQL. Nothing covered it, so
  # nothing caught it.
  describe "search_data_merchant" do
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
end
