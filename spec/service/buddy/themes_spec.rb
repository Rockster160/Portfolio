require "rails_helper"

# A pet used to be spelled out per-file and, worse, per-USER: a `case` in the
# favicon partial keyed off `default_theme_for(current_user)`, a ternary in
# SleepGuard that knew about Moss and nothing else, and a voice profile picked
# by `user.chelsea?`. A thread whose theme differed from its owner's default
# came out wearing the wrong name, icon, and voice.
RSpec.describe Buddy::Themes do
  it "gives every pet a name, a voice, and its own browser chrome" do
    described_class::ALL.each_key { |theme|
      chrome = described_class.for(theme)

      expect(chrome[:name]).to be_present
      expect(chrome[:tone]).to be_present
      expect(chrome[:color]).to match(/\A#[0-9A-F]{6}\z/i)
      expect(chrome.values_at(:avatar, :touch_icon, :favicon, :manifest)).to all(be_present)
    }
  end

  # Each pet is a whole personality: a persona file to be, and a voice profile
  # to speak with. A missing file means a companion falls back to a one-line
  # stub, which reads as a different (blander) character entirely.
  it "has both files on disk for every pet" do
    described_class::ALL.each_key { |theme|
      expect(Buddy::Personality::PERSONA_ROOT.join("#{theme}.md")).to exist
      expect(Buddy::Personality::TONE_PROFILE_ROOT.join("#{described_class.tone_for(theme)}.md")).to exist
    }
  end

  it "reads an unknown theme as the default rather than raising" do
    expect(described_class.for("nonsense")).to eq(described_class.for(:byte))
    expect(described_class.name_for(nil)).to eq("Byte")
  end

  it "accepts the theme as either a string or a symbol, since the column is a string" do
    expect(described_class.for("suki")).to eq(described_class.for(:suki))
  end

  describe "the voice following the pet rather than the person" do
    def prompt_for(theme, user: create(:user))
      convo = user.byte_conversations.create!(mode: :buddy)
      convo.update!(buddy_theme: theme)
      Buddy::Personality.for(user, conversation: convo)
    end

    # The bug this replaced: anyone but Eve opening a Suki thread got Suki's
    # persona wearing Rocco's voice - a companion half in character.
    it "gives a Suki thread Eve's voice no matter whose account it's on" do
      expect(prompt_for("suki", user: User.me)).to include("suikerbekkie")
    end

    it "gives a Moss thread Chelsea's voice no matter whose account it's on" do
      expect(prompt_for("moss", user: User.me)).to include("Voice for Moss")
    end
  end

  # The client has no theme table of its own — the resolved name rides on the
  # wire so a new companion never needs a second mapping kept in sync in JS.
  describe "what the client is told" do
    it "carries the pet's name on the conversation, not just its theme" do
      convo = User.me.byte_conversations.create!(mode: :buddy)
      convo.update!(buddy_theme: :suki)

      expect(convo.as_wire).to include(buddy_theme: "suki", buddy_name: "Suki")
    end
  end

  # SleepGuard used to be a Moss-or-Byte ternary keyed off the user, so a Suki
  # thread told you Byte was asleep.
  describe "the sleeping reply" do
    it "names the pet on the thread that's actually asleep" do
      convo = User.me.byte_conversations.create!(mode: :buddy)
      convo.update!(buddy_theme: :suki)
      Buddy::SleepGuard.sleep_until!(User.me, 1.hour.from_now)

      expect(Buddy::SleepGuard.sleeping_reply_body(User.me, convo)).to start_with("💤 Suki is sleeping")
    end

    it "falls back to the owner's default pet when there's no thread to ask" do
      expect(Buddy::SleepGuard.sleeping_reply_body(User.me)).to include("Byte is sleeping")
    end
  end
end
