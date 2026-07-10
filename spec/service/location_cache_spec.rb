require "rails_helper"

RSpec.describe LocationCache do
  let(:user) { User.me }

  before do
    user.caches.find_or_create_by!(key: :driving).update!(data: {})
    allow_any_instance_of(AddressBook).to receive(:contact_by_loc).and_return(nil)
    allow_any_instance_of(AddressBook).to receive(:reverse_geocode).and_return(nil)
    @triggers = []
    allow(::Jil::Executor).to receive(:trigger) { |*a, **k|
      @triggers << [a, k]
      nil
    }
  end

  def trytravel_payload
    @triggers.find { |(args, _)| args[1] == :trytravel }&.first&.dig(2)
  end

  describe ".driving=" do
    it "includes lat/lng and source=phone on :arrived" do
      user.caches.dig_set(:driving, :is_driving, true)
      described_class.set([40.5, -111.5])
      described_class.driving = false

      expect(trytravel_payload).to include(action: :arrived, lat: 40.5, lng: -111.5, source: :phone)
    end

    it "includes lat/lng and source=phone on :departed" do
      user.caches.dig_set(:driving, :is_driving, false)
      described_class.set([40.6, -111.7])
      described_class.driving = true

      expect(trytravel_payload).to include(action: :departed, lat: 40.6, lng: -111.7, source: :phone)
    end
  end
end
