RSpec.describe UserCache, type: :model do
  let!(:user) { User.me }
  let(:caches) { user.caches }

  describe "#get" do
    it "returns the cache object" do
      val = caches.get(:bowlingCarStarted)
      expect(val).to eq({})

      # numbers are currently broken since we set these at top level
      # caches.set(:somethingElse, 15)
      # expect(caches.get(:somethingElse)).to eq(15)

      caches.set(:blah, { thing: :set })
      expect(caches.get(:blah)).to match_hash({ thing: "set" })

      caches.dig_set(:car, :state, :on)
      expect(caches.get(:car)).to match_hash({ state: "on" })
      expect(caches.dig(:car, :state)).to eq("on")
    end
  end

  describe "#dig_set" do
    it "does something" do
      caches.dig_set(:oauth, :tesla, :access_token, "blah access blah")
      caches.dig_set(:oauth, :tesla, :refresh_token, "blahrefreshblah")
      # caches.dig_set(:somelist, 1, :sup, "not the first")

      expect(caches.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
      expect(caches.reload.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
      expect(caches.reload.dig(:oauth, :tesla, :refresh_token)).to eq("blahrefreshblah")
      # expect(caches.dig(:somelist, 0)).to be_nil
      # expect(caches.dig(:somelist, 1, :sup)).to eq("not the first")
    end
  end

  describe "(user_id, key) uniqueness" do
    it "rejects a second row with the same (user_id, key) at the DB level" do
      caches.create!(key: "DupeKey", data: { a: 1 })
      expect {
        caches.create!(key: "DupeKey", data: { a: 2 })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "by(key) does not race-create a duplicate" do
      caches.by(:WinAtRace)
      expect {
        caches.by(:WinAtRace)
      }.not_to change { caches.where(key: "WinAtRace").count }.from(1)
    end
  end
end
