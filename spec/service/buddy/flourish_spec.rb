require "rails_helper"

# A trailing clause that only comments on the sentence ("..., which is a small
# mercy", "..., if you enjoy being bullied by bins") is cut, unless it carries
# something: a figure, a name from the day, or enough length to be doing work.
RSpec.describe Buddy::Flourish do
  let(:facts) {
    { today: [{ time: "6:00 PM", title: "meatballs & power Mac" }], weather: { week: "rain Sun & Mon" } }
  }

  def trim(body, day=facts)
    described_class.trim(body, day)
  end

  it "drops an empty `which` or `if` clause and keeps the punctuation", :aggregate_failures do
    [
      ["Not much on deck from here, which is either peaceful or suspiciously peaceful.", "Not much on deck from here."],
      ["Then tonight's got meatballs & power Mac, which is a nice little anchor.", "Then tonight's got meatballs & power Mac."],
      ["Otherwise it looks nice and open for you, which is a small mercy!", "Otherwise it looks nice and open for you!"],
      ["Nice little double-point kind of day, if you enjoy being bullied by bins.", "Nice little double-point kind of day."],
      ["The afternoon is wide open, if you like that sort of thing.", "The afternoon is wide open."],
      # Never eats the sentence after it.
      ["It's open, which is lovely. Game Night is still on at 7.", "It's open. Game Night is still on at 7."],
    ].each do |body, expected|
      expect(trim(body)).to eq(expected), body
    end
  end

  # The expensive direction. A clause carrying something is a clause somebody
  # wanted, and losing one is worse than leaving a flourish in.
  it "keeps a clause that is doing work", :aggregate_failures do
    [
      "Dinner's late, if the meatballs hold out.",
      "You could take the run early, if 6:15 suits you.",
      "Eye Follow Up at 11:40, which is a 22 minute drive.",
      "Dinner's late, which is meatballs anyway.",
      "It's quiet, which gives you the whole afternoon back if you want to take the run early.",
      # Restrictive, with no comma: the sentence's own grammar.
      "Take the bag if you're heading out.",
      "Take the bag which is by the door.",
      # A body that was nothing else has no version of itself left to hand back.
      ", which is lovely.",
    ].each do |body|
      expect(trim(body)).to eq(body), body
    end
  end
end
