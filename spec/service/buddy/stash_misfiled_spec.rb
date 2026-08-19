require "rails_helper"

# Pile entries that were never thoughts.
#
# `destination` ("WHAT IS IT?") landed on 6 Aug and tells the model to DO a
# thing with a clock on it rather than file it. It works most of the time. Two
# gaps it can't close on its own:
#
#   1. Nothing deterministic marks a one-off with a moment in it, the way
#      RECURRING_RX marks a repeating one. The one shape where hesitating costs
#      the whole thing had the loosest handling.
#   2. A capture-time fix only ever helps things captured after it ships.
#      Everything already on the pile stayed exactly as mis-filed as the day it
#      arrived, and nothing ever went back.
RSpec.describe "Buddy stash mis-filing" do
  let(:user) { User.me }

  def held(content, summary: nil)
    BuddyMemory.create!(kind: :stash, user: user, status: :active, content: content, summary: summary)
  end

  before { BuddyMemory.where(user: user).destroy_all }

  describe "Buddy::Stash.misfiled_kind" do
    it "spots something that repeats" do
      expect(Buddy::Stash.misfiled_kind(held("Feed fish daily"))).to eq(:recurring)
      expect(Buddy::Stash.misfiled_kind(held("Check propagations every 4 days."))).to eq(:recurring)
      expect(Buddy::Stash.misfiled_kind(held("check the front flower bed daily"))).to eq(:recurring)
    end

    # Every one of these is a real pile entry whose moment went past with
    # nothing set.
    it "spots something that names a moment" do
      expect(Buddy::Stash.misfiled_kind(held("Pick out my outfit before 3:45"))).to eq(:timed)
      expect(Buddy::Stash.misfiled_kind(held("Write Doug's card before 3:45"))).to eq(:timed)
      expect(Buddy::Stash.misfiled_kind(held("Banana juice can go on the Home list, and set reminder for 8pm"))).to eq(:timed)
      expect(Buddy::Stash.misfiled_kind(held("Please remind me at 8pm to water the tomatoes"))).to eq(:timed)
      expect(Buddy::Stash.misfiled_kind(held("Chuck the old plastic pots tomorrow, it's trash day"))).to eq(:timed)
    end

    it "reads the summary as well as the body, since that's where the shape often shows" do
      memory = held("Oh right!! Thank you! thank you! Please ping me when it's time to do that!",
        summary: "Noon plant check ping")

      expect(Buddy::Stash.misfiled_kind(memory)).to eq(:timed)
    end

    # The regexes have to stay narrow or they swallow the pile they're meant to
    # clean. These are all real entries that genuinely belong where they are.
    it "leaves a genuine thought alone" do
      [
        "automatic kennel open/close and treat dispenser with an inside sensor",
        "Figure out a way to subtract an image so the base slime can be separated from items",
        "Work on bedroom",
        "Weeds in the front rocky area",
        "send the squash photo to ChatGPT to find out what it is",
        "I'm trying to make the lounge feel better, and the Ikea shelf set needs a home",
        "Add storage with drawers and glass door faces by his work desk",
        "Look up on YouTube whether blueberry bushes need phosphorus",
      ].each { |content| expect(Buddy::Stash.misfiled_kind(held(content))).to be_nil }
    end

    it "reads repeating as repeating even when it also names a time" do
      expect(Buddy::Stash.misfiled_kind(held("water the plants daily at 8pm"))).to eq(:recurring)
    end
  end

  describe "what rides in the prompt" do
    it "marks a repeating one so there is somewhere to notice it" do
      held("Feed fish daily", summary: "Daily fish feeding")

      block = Buddy::Personality.open_loops_block(user)

      expect(block).to include("REPEATS")
      expect(block).to match(/never a thought/i)
      expect(block).to include("schedule_reminder")
    end

    it "marks one that names a moment" do
      held("Pick out my outfit before 3:45")

      expect(Buddy::Personality.open_loops_block(user)).to include("NAMES A TIME")
    end

    # A pile is not a thing to audit at somebody.
    it "tells it to wait for the subject to come up rather than raising them cold" do
      held("Feed fish daily")

      expect(Buddy::Personality.open_loops_block(user)).to match(/don't raise them out of nowhere/i)
    end

    it "offers dropping instead when the moment has already gone" do
      held("Write Doug's card before 3:45")

      expect(Buddy::Personality.open_loops_block(user)).to include("drop_idea")
    end

    # The common prompt has to be unchanged for a pile that's all real thoughts.
    it "says nothing at all when nothing is mis-filed" do
      held("automatic kennel open/close with an inside sensor")

      block = Buddy::Personality.open_loops_block(user)

      expect(block).not_to include("REPEATS", "NAMES A TIME")
      expect(block).not_to match(/never a thought/i)
    end

    it "reaches the real system prompt, not just the helper" do
      held("Feed fish daily")
      convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      expect(Buddy::Personality.for(user, conversation: convo)).to include("REPEATS")
    end
  end

  describe "the closing at capture" do
    def closing_for(content)
      Buddy::Stash.send(:closing, user, held(content))
    end

    # Not an offer. The moment arrives whether or not anyone gets round to
    # discussing it, and "want me to set that?" answered twenty minutes later is
    # a reminder that already missed.
    it "tells it to SET a one-off rather than offer one" do
      text = closing_for("Please remind me at 8pm to water the tomatoes")

      expect(text).to include("schedule_reminder")
      expect(text).to match(/do not offer and wait/i)
      expect(text).to include("drop: true")
    end

    it "sends it to check for one that already covers it first" do
      expect(closing_for("ping me at 8pm about the tomatoes")).to include("upcoming_reminders")
    end

    it "still merely OFFERS for a repeating one, which can wait" do
      text = closing_for("Feed fish daily")

      expect(text).to match(/offer/i)
      expect(text).to match(/repeating reminder/i)
    end

    it "leaves a genuine thought on the ordinary path" do
      text = closing_for("Figure out a way to subtract an image from the base slime")

      expect(text).not_to match(/do not offer and wait/i)
    end
  end
end
