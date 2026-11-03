# == Schema Information
#
# Table name: timer_share_tokens
#
#  id            :bigint           not null, primary key
#  user_id       :bigint           not null
#  timer_id      :bigint
#  timer_page_id :bigint
#  token         :string           not null
#  access_mode   :integer          default("view_only"), not null
#  revoked_at    :datetime
#  expires_at    :datetime
#  hit_count     :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
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
    expect(bad.errors[:base]).to be_present
  end

  it "is usable until revoked or expired" do
    share = TimerShareToken.create!(user: user, timer: timer)
    expect(share.usable?).to eq(true)
    share.revoke!
    expect(share.usable?).to eq(false)

    expired = TimerShareToken.create!(user: user, timer: create(:timer, user: user), expires_at: 1.hour.ago)
    expect(expired.usable?).to eq(false)
  end
end
