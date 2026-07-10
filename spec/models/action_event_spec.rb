require "rails_helper"

RSpec.describe ActionEvent do
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
