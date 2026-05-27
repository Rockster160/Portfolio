require "rails_helper"

RSpec.describe GoogleAccount do
  let(:user) { create(:user) }

  describe "validations" do
    it "requires email" do
      account = described_class.new(user: user)
      expect(account).not_to be_valid
      expect(account.errors[:email]).to include("can't be blank")
    end

    it "enforces unique email per user" do
      described_class.create!(user: user, email: "alice@example.com")
      dup = described_class.new(user: user, email: "alice@example.com")
      expect(dup).not_to be_valid
    end

    it "lets different users share an email" do
      other = create(:user, phone: "5550000999")
      described_class.create!(user: user, email: "alice@example.com")
      expect(described_class.new(user: other, email: "alice@example.com")).to be_valid
    end

    it "normalizes the email to lowercase + trimmed" do
      account = described_class.create!(user: user, email: " ALICE@example.COM ")
      expect(account.email).to eq("alice@example.com")
    end
  end

  describe "associations" do
    it "destroys its agendas when destroyed (cascades sync data)" do
      account = described_class.create!(user: user, email: "alice@example.com")
      account.agendas.create!(user: user, source: :google, external_id: "cal-1", name: "Personal")
      expect { account.destroy }.to change(Agenda, :count).by(-1)
    end
  end

  describe "reauth helpers" do
    let(:account) { described_class.create!(user: user, email: "alice@example.com") }

    it "starts out not needing reauth" do
      expect(account).not_to be_needs_reauth
    end

    it "flips on mark_reauth_required!" do
      account.mark_reauth_required!
      expect(account).to be_needs_reauth
      expect(account.reauth_required_at).to be_present
    end

    it "clears via clear_reauth_required!" do
      account.update!(reauth_required_at: 1.day.ago)
      account.clear_reauth_required!
      expect(account.reauth_required_at).to be_nil
    end
  end
end
