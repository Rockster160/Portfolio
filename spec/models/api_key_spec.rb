require "rails_helper"

RSpec.describe ApiKey do
  let(:user) { FactoryBot.create(:user) }

  describe ".authenticate" do
    it "returns the key when it's live" do
      key = user.api_keys.create!(name: "Home Assistant")

      expect(described_class.authenticate(key.key)).to eq(key)
    end

    # The whole reason this method exists. `enabled` was a column three separate
    # `find_by(key:)` calls never looked at, so hitting "disable" on a leaked key
    # changed a boolean and nothing else — it still opened /jil/trigger, the
    # websocket, and the byte webhooks.
    it "refuses a key that's been disabled" do
      key = user.api_keys.create!(name: "Old laptop")
      key.update!(enabled: false)

      expect(described_class.authenticate(key.key)).to be_nil
    end

    it "refuses a key nobody issued" do
      expect(described_class.authenticate("NOT-A-REAL-KEY")).to be_nil
    end

    it "refuses a blank key without going to the database" do
      expect(ApiKey).not_to receive(:find_by)

      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate("")).to be_nil
    end

    # Stamped here rather than at the three call sites, so a door can't forget
    # to and leave a live key looking stale on the keys page.
    it "stamps the key as used" do
      key = user.api_keys.create!(name: "Home Assistant")

      expect { described_class.authenticate(key.key) }.to change { key.reload.last_used_at }.from(nil)
    end

    it "does not stamp a disabled key as used" do
      key = user.api_keys.create!(name: "Old laptop")
      key.update!(enabled: false)

      expect { described_class.authenticate(key.key) }.not_to(change { key.reload.last_used_at })
    end
  end
end
