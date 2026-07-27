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

    it "injects Moss's face set for a Moss user" do
      user = create(:user, buddy_theme: "moss")

      prompt = described_class.for(user, tools_appendix: "", context_path: nil)

      expect(prompt).to include("`focused`", "`celebrating`")
      expect(prompt).not_to include("`nerd`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
    end

    it "keeps neutral as the weighted baseline instruction" do
      prompt = described_class.for(User.me, tools_appendix: "", context_path: nil)
      expect(prompt).to include("baseline")
    end
  end
end
