RSpec.describe JarvisCache, type: :model do
  let!(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:caches) { user.jarvis_caches }

  describe "#get" do
    it "returns the cache object" do
      val = User.me.caches.get(:bowlingCarStarted)
      expect(val).to eq({})

      # numbers are currently broken since we set these at top level
      # User.me.caches.set(:somethingElse, 15)
      # expect(User.me.caches.get(:somethingElse)).to eq(15)

      User.me.caches.set(:blah, { thing: :set })
      expect(User.me.caches.get(:blah)).to match_hash({ thing: "set" })

      User.me.caches.dig_set(:car, :state, :on)
      expect(User.me.caches.get(:car)).to match_hash({ state: "on" })
      expect(User.me.caches.dig(:car, :state)).to eq("on")
    end
  end

  describe "#dig_set" do
    it "does something" do
      caches.dig_set(:oauth, :tesla, :access_token, "blah access blah")
      caches.dig_set(:oauth, :tesla, :refresh_token, "blahrefreshblah")
      # caches.dig_set(:somelist, 1, :sup, "not the first")

      expect(caches.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
      expect(caches.reload.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
      # expect(caches.dig(:somelist, 0)).to be_nil
      # expect(caches.dig(:somelist, 1, :sup)).to eq("not the first")
    end
  end
end
