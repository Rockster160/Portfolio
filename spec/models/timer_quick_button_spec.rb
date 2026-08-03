# == Schema Information
#
# Table name: timer_quick_buttons
#
#  id               :bigint           not null, primary key
#  user_id          :bigint           not null
#  label            :text
#  duration_seconds :integer
#  sort_order       :integer          default(0), not null
#  color            :text
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  template         :jsonb            not null
#  pinned           :boolean          default(TRUE), not null
#  timer_page_id    :bigint
#
require "rails_helper"

RSpec.describe TimerQuickButton do
  let(:user) { create(:user) }

  it "persists template payload" do
    qb = TimerQuickButton.create!(
      user: user,
      duration_seconds: 300,
      template: {
        kind: "countdown",
        name: "Tea",
        duration_ms: 300_000,
        callbacks: [{ id: "x", event: "complete", type: "push" }],
      },
    )
    qb.reload
    expect(qb.template["kind"]).to eq("countdown")
    expect(qb.template["callbacks"].first["type"]).to eq("push")
  end

  it "defaults template to empty hash" do
    qb = TimerQuickButton.create!(user: user, duration_seconds: 60)
    expect(qb.template).to eq({})
  end
end
