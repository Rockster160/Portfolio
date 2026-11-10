require "rails_helper"

# Every sentence an entry was written from has to stay caught, and every honest
# sentence below has to stay alone - the second list is what keeps a loose
# pattern from sending a turn that was right back for another round.
RSpec.describe Buddy::Claims do
  def ran_for(claim)
    claim.target.is_a?(String) ? Set[claim.target.downcase] : Set[claim.target]
  end

  described_class::CLAIMS.each do |claim|
    describe "#{claim.target} claims" do
      claim.examples.each do |sentence, seen|
        it "catches #{sentence.inspect} (#{seen}) when it didn't run" do
          hits = described_class.unbacked(sentence, ran: Set.new)

          expect(hits.map { |hit| hit.claim.target }).to include(claim.target)
        end

        it "leaves #{sentence.inspect} alone when it did run" do
          hits = described_class.unbacked(sentence, ran: ran_for(claim))

          expect(hits.map { |hit| hit.claim.target }).not_to include(claim.target)
        end
      end
    end
  end

  it "names only tools that exist" do
    tools = described_class::CLAIMS.map(&:target).grep(Symbol)
    tools += described_class::CLAIMS.flat_map(&:also)

    expect(tools.reject { |tool| Buddy::Tools.known?(tool) }).to be_empty
  end

  it "counts a tool named in `also` as backing the claim" do
    hits = described_class.unbacked("I added those three to **Before Bed**.", ran: Set[:schedule_list_items])

    expect(hits).to be_empty
  end

  it "leaves questions, negations, other people and the world alone" do
    [
      "Want me to skip her nap?",
      "Skipped that one already?",
      "I haven't skipped her nap yet - want me to?",
      "She skipped her nap and she's cranky.",
      "Skipped naps make for a cranky evening.",
      "Whisper quiet is something I can turn on.",
      "Quiet isn't on for long, just until 9.",
      "Chelsea added those to the list earlier.",
      "Did you add milk to the list?",
      "I couldn't find a Whisper nap reminder to cancel.",
      "I pulled up your reminders, there are three.",
      "The car is parked at home.",
      "Your reminder went off at 5.",
      "Sent you the link.",
      "I set a timer for 10 minutes.",
    ].each do |honest|
      expect(described_class.unbacked(honest, ran: Set.new)).to be_empty, "false positive: #{honest}"
    end
  end
end
