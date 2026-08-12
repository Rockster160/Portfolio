require "rails_helper"

RSpec.describe DeviceLoginToken do
  let(:user) { create(:user) }

  describe ".issue!" do
    it "mints a token, a numeric code, and an expiry" do
      token = described_class.issue!(user)

      expect(token.token).to be_present
      expect(token.code).to match(/\A\d{6}\z/)
      expect(token.expires_at).to be_within(5.seconds).of(described_class::TTL.from_now)
      expect(token).to be_live
    end

    it "retires the user's previous token" do
      old = described_class.issue!(user)
      described_class.issue!(user)

      expect(described_class.exists?(old.id)).to be(false)
      expect(described_class.where(user: user).count).to eq(1)
    end

    it "leaves other users' tokens alone" do
      other = described_class.issue!(create(:user))
      described_class.issue!(user)

      expect(described_class.exists?(other.id)).to be(true)
    end
  end

  describe ".claim_token" do
    it "returns the user and burns the token" do
      token = described_class.issue!(user)

      expect(described_class.claim_token(token.token)).to eq(user)
      expect(token.reload).to be_used
    end

    it "refuses a second use" do
      token = described_class.issue!(user)
      described_class.claim_token(token.token)

      expect(described_class.claim_token(token.token)).to be_nil
    end

    it "refuses an expired token" do
      token = described_class.issue!(user)
      token.update!(expires_at: 1.second.ago)

      expect(described_class.claim_token(token.token)).to be_nil
    end

    it "refuses a blank or unknown token" do
      expect(described_class.claim_token(nil)).to be_nil
      expect(described_class.claim_token("")).to be_nil
      expect(described_class.claim_token("nope")).to be_nil
    end
  end

  describe ".claim_code" do
    it "returns the user and burns the token" do
      token = described_class.issue!(user)

      expect(described_class.claim_code(user, token.code)).to eq(user)
      expect(token.reload).to be_used
    end

    it "accepts the code with the display spacing typed in" do
      token = described_class.issue!(user)

      expect(described_class.claim_code(user, token.formatted_code)).to eq(user)
    end

    it "refuses a second use" do
      token = described_class.issue!(user)
      described_class.claim_code(user, token.code)

      expect(described_class.claim_code(user, token.code)).to be_nil
    end

    it "refuses another user's code" do
      token = described_class.issue!(user)
      stranger = create(:user)

      expect(described_class.claim_code(stranger, token.code)).to be_nil
      expect(token.reload).not_to be_used
    end

    it "refuses an expired code" do
      token = described_class.issue!(user)
      token.update!(expires_at: 1.second.ago)

      expect(described_class.claim_code(user, token.code)).to be_nil
    end

    it "counts wrong guesses and stops accepting the real code once the budget is spent" do
      token = described_class.issue!(user)
      wrong = format("%06d", (token.code.to_i + 1) % 1_000_000)

      described_class::MAX_ATTEMPTS.times { described_class.claim_code(user, wrong) }

      expect(token.reload.attempts).to eq(described_class::MAX_ATTEMPTS)
      expect(described_class.claim_code(user, token.code)).to be_nil
    end

    it "ignores anything that is not a six digit code without spending an attempt" do
      token = described_class.issue!(user)

      expect(described_class.claim_code(user, "password123")).to be_nil
      expect(described_class.claim_code(user, "12345")).to be_nil
      expect(token.reload.attempts).to eq(0)
    end
  end

  describe "#formatted_code" do
    it "splits the code into two groups of three" do
      token = described_class.issue!(user)
      token.update!(code: "483912")

      expect(token.formatted_code).to eq("483 912")
    end
  end
end
