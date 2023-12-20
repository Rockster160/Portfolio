RSpec.describe JarvisCache, type: :model do
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:cache) { user.jarvis_cache }

  describe "#dig_set" do
    it "does something" do
      cache.dig_set(:oauth, :tesla, :access_token, "blah access blah")
      cache.dig_set(:oauth, :tesla, :refresh_token, "blahrefreshblah")
      # cache.dig_set(:somelist, 1, :sup, "not the first")

      expect(cache.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
      expect(cache.reload.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
      # expect(cache.dig(:somelist, 0)).to be_nil
      # expect(cache.dig(:somelist, 1, :sup)).to eq("not the first")
    end
  end
end
