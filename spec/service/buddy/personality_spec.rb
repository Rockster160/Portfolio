require "rails_helper"

RSpec.describe Buddy::Personality do
  # The pet theme is now per-conversation, so the persona/face vocabulary is
  # keyed off the buddy conversation's theme, not the user.
  def buddy_convo(user, theme)
    convo = user.byte_conversations.create!(mode: :buddy)
    convo.update!(buddy_theme: theme)
    convo
  end

  describe ".for mood vocabulary" do
    it "injects Byte's own face set for a Byte conversation" do
      convo = buddy_convo(User.me, "byte")

      prompt = described_class.for(User.me, conversation: convo, tools_appendix: "", context_path: nil)

      expect(prompt).to include("`nerd`", "`uwu`", "`annoyed`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
      # Moss-only faces must not be offered to Byte.
      expect(prompt).not_to include("`celebrating`")
    end

    it "injects Moss's own (larger) face set for a Moss conversation" do
      user  = create(:user)
      convo = buddy_convo(user, "moss")

      prompt = described_class.for(user, conversation: convo, tools_appendix: "", context_path: nil)

      # Moss's distinctive faces are offered...
      expect(prompt).to include("`loving`", "`star`", "`wink`", "`dizzy`")
      # ...and Byte-only faces are not.
      expect(prompt).not_to include("`nerd`", "`uwu`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
    end

    it "does not offer sleeping as a selectable mood" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo, tools_appendix: "", context_path: nil)
      expect(prompt).not_to include("`sleeping`")
    end

    it "does not offer thinking as a selectable mood (transitional only)" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo, tools_appendix: "", context_path: nil)
      expect(prompt).not_to include("`thinking`")
    end

    it "keeps neutral as the resting default while pushing the face to move" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo, tools_appendix: "", context_path: nil)
      expect(prompt).to include("resting default")
      expect(prompt).to include("your face should MOVE")
    end
  end

  describe ".for tone floor" do
    it "warns against reply-as-receipt and templated warmth" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo, tools_appendix: "", context_path: nil)
      expect(prompt).to include("Don't just confirm and close")
      expect(prompt).to include("Vary your warmth")
    end

    it "teaches remind_when as the condition-based reminder tool in the doctrine" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo, tools_appendix: "", context_path: nil)
      expect(prompt).to include("remind_when")
    end
  end
end
