require "rails_helper"

RSpec.describe Jil::Methods::Agenda, type: :service do
  let(:user) { create(:user) }
  let(:jil_stub) {
    Class.new {
      attr_reader :user, :ctx

      def initialize(user)
        @user = user
        @ctx = nil
      end
    }.new(user)
  }

  subject(:methods) { described_class.new(jil_stub) }

  describe "#find — soft lookup for voice/text inputs" do
    let!(:ours) { user.agendas.create!(name: "Ours 💕", parameterized_name: "ours") }
    let!(:tasks) { user.agendas.create!(name: "Tasks", parameterized_name: "tasks") }

    it "resolves stored parameterized_name (emoji stripped from name)" do
      expect(methods.find("ours")).to eq(ours)
    end

    it "falls back to ILIKE substring match on parameterized_name" do
      expect(methods.find("our")).to eq(ours)
    end

    it "is case-insensitive via parameterize" do
      expect(methods.find("OURS")).to eq(ours)
    end

    it "matches exact name when parameterize doesn't" do
      expect(methods.find("Tasks")).to eq(tasks)
    end

    it "returns nil for blank/empty input" do
      expect(methods.find(nil)).to be_nil
      expect(methods.find("")).to be_nil
      expect(methods.find("   ")).to be_nil
    end

    it "returns nil when nothing matches" do
      expect(methods.find("zzzzznothing")).to be_nil
    end
  end
end
