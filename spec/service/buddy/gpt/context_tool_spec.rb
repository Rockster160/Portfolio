require "rails_helper"

RSpec.describe Buddy::GPT::ContextTool do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tool)  { described_class.new(user, convo) }

  def sections_returned(requested)
    JSON.parse(tool.call({ "sections" => requested })).keys
  end

  # "Turn the fan to low" had the model check jil_triggers, find only "Fan High",
  # and tell the person it couldn't do it - while "Great Fan" (off/low/mid/high)
  # sat in jil_functions the whole time. Which of the two indexes a capability
  # lands in is our filing system, not something the request reveals.
  describe "the two Jil indexes" do
    it "returns both when only the trigger index was asked for" do
      expect(sections_returned(["jil_triggers"])).to include("jil_triggers", "jil_functions")
    end

    it "returns both when only the function index was asked for" do
      expect(sections_returned(["jil_functions"])).to include("jil_triggers", "jil_functions")
    end

    it "does not drag them into an unrelated request" do
      expect(sections_returned(["chores_all"])).to eq(["chores_all"])
    end
  end

  describe "section filtering" do
    it "keeps only sections on the allowlist" do
      expect(sections_returned(%w[chores_all not_a_real_section])).to eq(["chores_all"])
    end

    it "returns everything when nothing specific was asked for" do
      expect(sections_returned([]).length).to be > 1
    end
  end
end
