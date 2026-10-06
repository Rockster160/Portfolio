# == Schema Information
#
# Table name: user_secrets
#
#  id         :bigint           not null, primary key
#  user_id    :bigint           not null
#  name       :text             not null
#  value      :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
require "rails_helper"

RSpec.describe UserSecret do
  let(:user) { create(:user) }

  it "stores the value encrypted, never as written" do
    secret = user.secrets.create!(name: "OpenAI", value: "sk-user-own-1234")
    raw = described_class.connection.select_value("SELECT value FROM user_secrets WHERE id = #{secret.id}")

    expect(raw).not_to include("sk-user-own")
    expect(secret.reload.value).to eq("sk-user-own-1234")
    expect(secret.hint).to eq("…1234")
  end

  it "is found by name in any case, and one name holds one value" do
    user.secrets.create!(name: "OpenAI", value: "a")

    expect(user.secrets.named(" openai ").value).to eq("a")
    expect(user.secrets.new(name: "OPENAI", value: "b")).not_to be_valid
    expect(create(:user).secrets.new(name: "OpenAI", value: "b")).to be_valid
  end
end
