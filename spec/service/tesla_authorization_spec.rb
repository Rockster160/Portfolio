require "rails_helper"

# Pinning the "Tesla integration is restricted to User.me" guarantee at
# every entry point: TeslaControl construction, Jarvis voice, and the new
# Jil method module. If any of these specs fail, a non-me user could drive
# the car — which is the whole thing we're guarding against.
RSpec.describe "Tesla authorization" do
  let(:other_user) {
    User.create!(
      username:              "interloper-#{SecureRandom.hex(4)}",
      email:                 "interloper+#{SecureRandom.hex(4)}@example.com",
      password:              "test1234567",
      password_confirmation: "test1234567",
      role:                  User.roles[:user],
    )
  }

  describe "TeslaControl.guard!" do
    it "accepts User.me" do
      expect { TeslaControl.guard!(User.me) }.not_to raise_error
    end

    it "rejects any other user" do
      expect { TeslaControl.guard!(other_user) }.to raise_error(TeslaNotAuthorized)
    end

    it "rejects nil" do
      expect { TeslaControl.guard!(nil) }.to raise_error(TeslaNotAuthorized)
    end
  end

  describe "TeslaControl.new(user)" do
    it "constructs cleanly for User.me" do
      expect { TeslaControl.new(User.me) }.not_to raise_error
    end

    it "raises for any other user" do
      expect { TeslaControl.new(other_user) }.to raise_error(TeslaNotAuthorized)
    end
  end

  describe Jarvis::Tesla do
    it "raises Jarvis::Error when valid words are recognized for a non-me user" do
      # Construct directly so we control reserved_words and can guarantee
      # valid_words? returns true (the path we want to exercise).
      jarvis = described_class.new(other_user, "honk car", [])
      expect { jarvis.attempt }.to raise_error(Jarvis::Error)
    end
  end

  describe Jil::Methods::Tesla do
    let(:jil) { instance_double("Jil::Executor", user: other_user, ctx: {}) }
    let(:methods) { described_class.new(jil) }

    it "every action returns false for a non-me Jil user without raising" do
      %i[
        start stop honk flashLights lockDoors unlockDoors
        closeWindows ventWindows popFrunk popTrunk defrost
        heatDriver heatPassenger
      ].each do |action|
        expect(methods.public_send(action)).to eq(false)
      end
      expect(methods.setTemp(70)).to eq(false)
      expect(methods.navigate("anywhere")).to eq(false)
    end

    it "never constructs TeslaControl for a non-me user" do
      expect(::TeslaControl).not_to receive(:me)
      methods.honk
    end
  end
end
