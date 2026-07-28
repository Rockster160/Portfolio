require "rails_helper"

RSpec.describe Buddy::Personality do
  describe ".for mood vocabulary" do
    it "injects Byte's own face set for a Byte user" do
      user = User.me
      user.update_column(:buddy_theme, "byte")

      prompt = described_class.for(user, tools_appendix: "", context_path: nil)

      expect(prompt).to include("`nerd`", "`uwu`", "`annoyed`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
      # Moss-only faces must not be offered to Byte.
      expect(prompt).not_to include("`celebrating`")
    end

    it "injects Moss's own (larger) face set for a Moss user" do
      user = create(:user, buddy_theme: "moss")

      prompt = described_class.for(user, tools_appendix: "", context_path: nil)

      # Moss's distinctive faces are offered...
      expect(prompt).to include("`loving`", "`star`", "`wink`", "`dizzy`")
      # ...and Byte-only faces are not.
      expect(prompt).not_to include("`nerd`", "`uwu`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
    end

    it "does not offer sleeping as a selectable mood" do
      prompt = described_class.for(User.me, tools_appendix: "", context_path: nil)
      expect(prompt).not_to include("`sleeping`")
    end

    it "keeps neutral as the resting default while pushing the face to move" do
      prompt = described_class.for(User.me, tools_appendix: "", context_path: nil)
      expect(prompt).to include("resting default")
      expect(prompt).to include("your face should MOVE")
    end
  end

  describe ".for tone floor" do
    it "warns against reply-as-receipt and templated warmth" do
      prompt = described_class.for(User.me, tools_appendix: "", context_path: nil)
      expect(prompt).to include("Don't just confirm and close")
      expect(prompt).to include("Vary your warmth")
    end

    it "teaches remind_when as the condition-based reminder tool in the doctrine" do
      prompt = described_class.for(User.me, tools_appendix: "", context_path: nil)
      expect(prompt).to include("remind_when")
    end
  end
end
