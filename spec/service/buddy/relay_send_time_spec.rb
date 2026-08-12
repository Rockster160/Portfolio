require "rails_helper"

# Prod 3303. "Tell Rocco I'll make supper at 6:00 tonight." became a
# `schedule_reminder` aimed at Rocco with `at` set to 6:00 PM — so the news that
# supper was coming at six would have arrived at six. Chelsea corrected it
# ("No I want him to know that I plan to make supper at 6:00"), it relayed
# properly on the retry, and then she spent four more messages getting the
# stray reminder deleted.
#
# The 6:00 was never a delivery time. It was what the message was ABOUT, and
# both tool descriptions listed bare times ("at 4", "tonight") as the tell for
# the later form — the exact tokens that show up inside an ordinary note.
RSpec.describe "Buddy relay send times" do
  let(:relay) { Buddy::Tools[:message_partner][:description] }
  let(:later) { Buddy::Tools[:schedule_reminder][:description] }

  describe "message_partner" do
    it "puts the delay in the instruction rather than in the note" do
      expect(relay).to match(/a delay is in the instruction, never in the note/i)
    end

    it "carries the case that broke, with its answer" do
      expect(relay).to include("Tell Rocco I'll make supper at 6:00 tonight")
      expect(relay).to match(/send it NOW/)
    end

    it "contrasts a time in the content with a time in the framing" do
      expect(relay).to include("Tell Chelsea I'm leaving at 4")
      expect(relay).to include("Remind Chelsea at 4 that I'm leaving")
    end

    it "settles the ambiguous case toward sending" do
      expect(relay).to match(/when the sentence carries one time and you can(?:'|’)t place it, it(?:'|’)s content/i)
    end

    # The examples for the LATER form have to be framings, or they teach the
    # failure they're meant to prevent.
    it "no longer offers a bare time as the tell for scheduling" do
      expect(relay).to include("send it to her in five minutes", "tell him at 4")
      expect(relay).not_to include(%(At a time ("in five minutes", "at 4", "tonight")))
    end
  end

  describe "schedule_reminder" do
    it "says the same thing from the other side" do
      expect(later).to match(/`at` comes from WHEN THEY SAID TO SEND IT/)
      expect(later).to match(/a time inside the note is part of the note/i)
    end

    it "names the tool to use instead" do
      expect(later).to match(/use `message_partner`/)
    end
  end
end
