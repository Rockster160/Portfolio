require "rails_helper"

# A pet is resolved from the THREAD's theme, never from the user, so a thread
# whose theme differs from its owner's default still wears its own name, icon
# and voice.
RSpec.describe Buddy::Themes do
  it "gives every pet a name, a voice, and its own browser chrome" do
    described_class.all.each_key { |theme|
      chrome = described_class.for(theme)

      expect(chrome[:name]).to be_present
      expect(chrome[:tone]).to be_present
      expect(chrome[:color]).to match(/\A#[0-9A-F]{6}\z/i)
      expect(chrome.values_at(:avatar, :touch_icon, :favicon, :manifest, :kiosk_manifest)).to all(be_present)
    }
  end

  # Two manifests per pet, differing only in `start_url`, because that's what
  # decides whether the home-screen icon opens the chat or the wall tablet. A
  # missing file is an install that silently falls back to the chat.
  it "ships both manifests for every pet, pointed at the right page" do
    described_class.all.each_key { |theme|
      chrome = described_class.for(theme)
      chat   = JSON.parse(Rails.public_path.join(chrome[:manifest].delete_prefix("/")).read)
      kiosk  = JSON.parse(Rails.public_path.join(chrome[:kiosk_manifest].delete_prefix("/")).read)

      expect(chat["start_url"]).to eq("/?source=pwa")
      expect(kiosk["start_url"]).to eq("/kiosk")
      expect(kiosk["name"]).to eq("#{chrome[:name]} Kiosk")
      # Distinct ids, or the browser treats the second install as the first one
      # again and never adds a second icon.
      expect(kiosk["id"]).not_to eq(chat["id"])
    }
  end

  # Each pet is a whole personality: a persona file to be, and a voice profile
  # to speak with. A missing file means a companion falls back to a one-line
  # stub, which reads as a different (blander) character entirely.
  it "has both files on disk for every pet" do
    described_class.all.each_key { |theme|
      expect(Buddy::Companion.find(theme).persona_path).to exist
      expect(Buddy::Personality::TONE_PROFILE_ROOT.join("#{described_class.tone_for(theme)}.md")).to exist
    }
  end

  it "reads an unknown theme as the default, and a string theme as its symbol", :aggregate_failures do
    expect(described_class.for("nonsense")).to eq(described_class.for(:byte))
    expect(described_class.name_for(nil)).to eq("Byte")
    expect(described_class.for("suki")).to eq(described_class.for(:suki))
  end

  describe "the voice following the pet rather than the person" do
    def prompt_for(theme, user: create(:user))
      convo = user.byte_conversations.create!(mode: :buddy)
      convo.update!(buddy_theme: theme)
      Buddy::Personality.for(user, conversation: convo)
    end

    it "loads the thread's pet's voice profile whoever's account it's on", :aggregate_failures do
      expect(prompt_for("suki", user: User.me)).to include("suikerbekkie")
      expect(prompt_for("moss", user: User.me)).to include("the warm household voice")
    end

    # Each profile ends with a short Floor, repeated last in the prompt - the
    # position nearest the person's message.
    describe "the voice floor" do
      it "ends every pet's profile, so a new companion is still one file" do
        described_class.all.each_key { |theme|
          path = Buddy::Personality::TONE_PROFILE_ROOT.join("#{described_class.tone_for(theme)}.md")

          expect(path.read).to include(Buddy::Personality::FLOOR_HEADING), "#{theme} has no floor"
        }
      end

      it "is the last thing in the prompt, after the rules and after the clock" do
        prompt = prompt_for("byte", user: User.me)
        floor  = prompt.rindex(Buddy::Personality::FLOOR_HEADING)

        expect(floor).to be_present
        expect(prompt[floor..]).to include("aside in parentheses")
        # Nothing after it, which is the whole point of adding it there.
        expect(prompt.rindex("## Rules of the House")).to be < floor
        expect(prompt.rindex("Right now")).to be < floor
      end

      # It appears twice on purpose - once in the profile at the top, once at
      # the end - so a profile without one must not pick up somebody else's.
      it "carries the pet's own moves, not the default pet's" do
        expect(prompt_for("kumoko", user: User.me)).to include("Self-tsukkomi")
        expect(prompt_for("kumoko", user: User.me)).not_to include("aside in parentheses")
      end
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

    # Switching threads has to repaint both avatars, the placeholder, the
    # favicon and the surface colour, and warm the incoming pet's faces - which
    # means the client needs pets it has no open conversation for. That comes as
    # one blob generated from this table, so a new companion is still one entry.
    describe "the theme table rendered into the page" do
      # Through the real view context, so the asset paths are the ones the page
      # would actually render.
      let(:table) { JSON.parse(ApplicationController.helpers.buddy_themes_json) }

      it "covers every pet with everything a repaint needs", :aggregate_failures do
        expect(table.keys).to match_array(described_class.all.keys.map(&:to_s))
        table.each_value { |chrome|
          expect(chrome["name"]).to be_present
          expect(chrome["color"]).to match(/\A#[0-9A-F]{6}\z/i)
          expect(chrome.values_at("avatar", "touch_icon", "favicon")).to all(start_with("/"))
        }
      end

      it "resolves each pet's face set so a switch can warm them" do
        # `faces` is `{ expression => url }` — keyed so the hero can look up the
        # art for a mood with no second list of which faces a pet has, and
        # `neutral` is the one every pet must carry (the resting default and the
        # resolver's fallback).
        table.each { |theme, chrome|
          expect(chrome["faces"]).not_to be_empty, "#{theme} has no face images"
          expect(chrome["faces"]).to include("neutral"), "#{theme} has no neutral face"
          chrome["faces"].each { |expr, url|
            # `thinking` resolves to a stand-in pose for a pet with no thinking
            # art of its own, so it needn't match its own name — but it is still
            # one of THIS pet's real face images.
            match = expr == "thinking" ? "buddy/#{theme}/face_" : "buddy/#{theme}/face_#{expr}"
            expect(url).to include(match)
          }
        }
      end
    end
  end

  it "names the thread's pet in the sleeping reply, or the owner's default with no thread", :aggregate_failures do
    convo = User.me.byte_conversations.create!(mode: :buddy)
    convo.update!(buddy_theme: :suki)
    Buddy::SleepGuard.sleep_until!(User.me, 1.hour.from_now)

    expect(Buddy::SleepGuard.sleeping_reply_body(User.me, convo)).to include("Suki")
    expect(Buddy::SleepGuard.sleeping_reply_body(User.me)).to include("Byte")
  end
end
