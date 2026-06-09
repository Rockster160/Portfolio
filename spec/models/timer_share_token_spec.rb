require "rails_helper"

RSpec.describe TimerShareToken do
  let(:user) { create(:user) }
  let(:timer) { create(:timer, user: user) }

  it "generates a unique token on create" do
    a = TimerShareToken.create!(user: user, timer: timer)
    b = TimerShareToken.create!(user: user, timer: create(:timer, user: user))
    expect(a.token).to be_present
    expect(a.token).not_to eq(b.token)
  end

  it "requires exactly one target" do
    page = create(:timer_page, user: user)
    bad = TimerShareToken.new(user: user, timer: timer, timer_page: page)
    expect(bad.valid?).to eq(false)
    expect(bad.errors[:base].first).to match(/exactly one/)
  end

  it "usable? returns false when revoked" do
    share = TimerShareToken.create!(user: user, timer: timer)
    share.revoke!
    expect(share.usable?).to eq(false)
  end

  it "usable? returns false when expired" do
    share = TimerShareToken.create!(user: user, timer: timer, expires_at: 1.hour.ago)
    expect(share.usable?).to eq(false)
  end
end
