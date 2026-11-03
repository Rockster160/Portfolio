# == Schema Information
#
# Table name: user_caches
#
#  id         :bigint           not null, primary key
#  user_id    :bigint
#  data       :jsonb
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  key        :string
#
RSpec.describe UserCache, type: :model do
  let!(:user) { User.me }
  let(:caches) { user.caches }

  it "gets, sets and dig-sets nested values that survive a reload", :aggregate_failures do
    expect(caches.get(:bowlingCarStarted)).to eq({})

    caches.set(:blah, { thing: :set })
    expect(caches.get(:blah)).to match_hash({ thing: "set" })

    caches.dig_set(:car, :state, :on)
    expect(caches.get(:car)).to match_hash({ state: "on" })
    expect(caches.dig(:car, :state)).to eq("on")

    caches.dig_set(:oauth, :tesla, :access_token, "blah access blah")
    caches.dig_set(:oauth, :tesla, :refresh_token, "blahrefreshblah")
    expect(caches.reload.dig(:oauth, :tesla, :access_token)).to eq("blah access blah")
    expect(caches.reload.dig(:oauth, :tesla, :refresh_token)).to eq("blahrefreshblah")
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
