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

  # terminal-pet lives on the owner's Mac; a drink or a meal they log feeds it.
  describe "feeding the pet" do
    before { allow(PetWorker).to receive(:tell) }

    it "feeds 10 for a drink, saying what it was and when" do
      event = User.me.action_events.create!(name: "Drink", notes: "Mtn Dew Zero")

      expect(PetWorker).to have_received(:tell).with(
        :feed,
        10,
        :drink,
        ["Mtn", "Dew", "Zero"],
        "@#{event.timestamp.to_i}",
      )
    end

    it "feeds 80 for food, whatever the case of the name" do
      event = User.me.action_events.create!(name: "food")

      expect(PetWorker).to have_received(:tell).with(:feed, 80, :food, [], "@#{event.timestamp.to_i}")
    end

    it "sends a backdated event's own time, not when it was logged" do
      at = 1.hour.ago.change(usec: 0)
      User.me.action_events.create!(name: "Food", notes: "Pizza", timestamp: at)

      expect(PetWorker).to have_received(:tell).with(:feed, 80, :food, ["Pizza"], "@#{at.to_i}")
    end

    it "keeps the notes to five words with no @ the Mac would read as a time" do
      User.me.action_events.create!(name: "Food", notes: "@home chicken rice beans salsa cheese guac")

      expect(PetWorker).to have_received(:tell).with(
        :feed,
        80,
        :food,
        ["home", "chicken", "rice", "beans", "salsa"],
        anything,
      )
    end

    it "says nothing for any other event" do
      User.me.action_events.create!(name: "Shower")

      expect(PetWorker).not_to have_received(:tell)
    end

    it "says nothing for someone else's drink" do
      create(:user).action_events.create!(name: "Drink")

      expect(PetWorker).not_to have_received(:tell)
    end

    it "says nothing when an existing drink is edited" do
      event = User.me.action_events.create!(name: "Drink")
      RSpec::Mocks.space.proxy_for(PetWorker).reset
      allow(PetWorker).to receive(:tell)

      event.update!(notes: "Cherry Coke Zero")

      expect(PetWorker).not_to have_received(:tell)
    end
  end
end
