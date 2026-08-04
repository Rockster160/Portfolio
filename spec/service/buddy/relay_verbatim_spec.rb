require "rails_helper"

# Prod 1434-1440, two failures in one exchange.
#
# "Tell Chelsea: I love you more! And I like YOUR butt!" arrived as "...I like
# your butt!" - message_partner WAS called, but the model retyped the words and
# flattened the shouted one, which was the whole joke.
#
# Then "Tell Chelsea: Rude. Byte took away my formatting!" produced "Sent. 😅"
# followed by a verbatim `[you passed this along to Moss] ...` - the bracketed
# attribution History puts on a bridged message so Buddy can READ it. No tool
# call, no relay row, no receipt chip. Nothing reached Chelsea, and neither the
# nudge nor the retraction noticed, because "Sent." matched no claim pattern.
RSpec.describe "Buddy relay integrity" do
  describe "carrying the person's words intact" do
    let(:tool) { Buddy::Tools[:message_partner] }

    it "tells the model the words are theirs when they hand over words" do
      expect(tool[:description]).to include("Copy it EXACTLY")
      expect(tool[:description]).to include("I like YOUR butt!")
      expect(tool[:description]).to match(/do not tidy/i)
    end

    it "still lets the model do the phrasing when it only got the gist" do
      expect(tool[:description]).to include("The wording is yours")
    end

    it "says the same thing on the question side" do
      expect(Buddy::Tools[:ask_partner][:description]).to match(/gave you the words/i)
    end

    it "puts it in the prompt too, not just the tool schema" do
      convo = User.me.byte_conversations.create!(mode: :buddy)

      expect(Buddy::Personality.for(User.me, conversation: convo)).to include(
        "You're the envelope, not the editor",
      )
    end
  end

  # Prod 2212. Chelsea: "Ask Rocco if he will learn how to play American mahjong
  # with me". What reached Rocco was "Will you learn how to play American
  # mahjong with you?" - the model turned BOTH people into the second person, so
  # the question asked him to do it with himself. Half the swap is right ("if he
  # will" is addressed as "will you"); the other half has to become a name.
  describe "which person the words are written to" do
    # Squished the way function_schema squishes it, so a line wrap in the
    # heredoc isn't the thing these assertions are about.
    def described(name)
      Buddy::Tools[name][:description].strip.gsub(/\s+/, " ")
    end

    %i[ask_partner ask_partner_choice ask_partner_multi].each { |name|
      it "tells #{name} that \"you\" means the recipient" do
        expect(described(name)).to match(/READ BY (them|the person being asked)/i)
        expect(described(name)).to match(/your own person (gets|is) named/i)
      end

      it "says it on #{name}'s question argument, where the value is written" do
        expect(Buddy::Tools[name][:args][:question][:description]).to match(/addressed TO them/i)
      end
    }

    it "works the case out in the prompt, with the sentence that broke" do
      convo = User.me.byte_conversations.create!(mode: :buddy)
      prompt = Buddy::Personality.for(User.me, conversation: convo)

      expect(prompt).to include("Will you learn American mahjong with you?")
      expect(prompt).to include("\"you\" is the recipient and nobody else")
    end
  end

  describe Buddy::GPT::Turn do
    # The exact body that went out in prod.
    let(:faked) { "Sent. 😅\n\n[you passed this along to Moss] Rude. Byte took away my formatting!" }

    it "reads a bare \"Sent.\" as a claim so an uncalled relay gets a corrective round" do
      expect(described_class.unbacked_claim("Sent. 😅")).to eq(:claim)
      expect(described_class.unbacked_claim("Passed it along to Chelsea.")).to eq(:claim)
      expect(described_class.unbacked_claim("Told her already.")).to eq(:claim)
      expect(described_class.unbacked_claim("She's in the loop now.")).to eq(:claim)
    end

    # Writing the attribution IS the claim: the only reason that bracket exists
    # is to label a relay that actually happened.
    it "reads the relay attribution itself as a claim, even with no other words" do
      expect(described_class.unbacked_claim("[you passed this along to Moss] Rude.")).to eq(:claim)
      expect(described_class.unbacked_claim(faked)).to eq(:claim)
    end

    it "leaves an offer to send alone - a promise is not a claim" do
      expect(described_class.unbacked_claim("Want me to send that along?")).to be_nil
      expect(described_class.unbacked_claim("Let me know and I'll tell her.")).to be_nil
    end
  end
end
