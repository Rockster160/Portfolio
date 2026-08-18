require "rails_helper"

# Reading what a person actually said, so "if she says yes" can mean something.
RSpec.describe Buddy::AnswerCondition do
  def yes_gate(var: "hers", who: "Chelsea")
    described_class.build(var: var, is: "yes", who: who)
  end

  def check(condition, answer)
    described_class.check(condition, { "hers" => answer })
  end

  describe ".build" do
    it "keeps the name, the wanted answer and who was asked" do
      expect(yes_gate).to eq("var" => "hers", "is" => "yes", "who" => "Chelsea")
    end

    it "is nothing at all without a var to read" do
      expect(described_class.build(var: "", is: "yes")).to be_nil
    end

    # Every gate built before this existed has no condition on it, and every
    # ordinary sequence still won't.
    it "is nothing at all without an answer to want" do
      expect(described_class.build(var: "hers", is: nil)).to be_nil
    end
  end

  # The common case, and the one from the report.
  describe "a yes/no condition" do
    def yeses
      phrases = ["yes please", "Sounds good", "go for it"]
      %w[yes Yes! yeah yep sure ok please definitely 👍] + phrases
    end

    def noes
      phrases = ["not tonight", "no thanks", "I'd rather not"]
      %w[no No. nope nah don't never 👎] + phrases
    end

    it "runs on the obvious yeses" do
      yeses.each do |said|
        expect(check(yes_gate, said)).to eq(:met), "expected #{said.inspect} to read as yes"
      end
    end

    it "stops on the obvious noes" do
      noes.each do |said|
        expect(check(yes_gate, said)).to eq(:unmet), "expected #{said.inspect} to read as no"
      end
    end

    # "no thanks" opens with a word the yes list would happily skip past, so the
    # order the two are tried in is load-bearing.
    it "does not read a polite no as a yes" do
      expect(check(yes_gate, "no thanks, I'm good")).to eq(:unmet)
      expect(check(yes_gate, "not really")).to eq(:unmet)
    end

    it "reads an answer that says it late" do
      expect(check(yes_gate, "I'd love that, yes")).to eq(:met)
    end

    # The third case, and the reason there are three. Acting on this is the bug;
    # dropping it in silence is the other bug.
    it "refuses to guess at an answer that says neither" do
      ["maybe", "I'll think about it", "hmm", "what time?", "ask me later"].each do |said|
        expect(check(yes_gate, said)).to eq(:unclear), "expected #{said.inspect} to be unclear"
      end
    end

    it "refuses to guess when they said both" do
      expect(check(yes_gate, "yes to the pasta, no to the syrup")).to eq(:unclear)
    end

    it "is unclear when they never answered" do
      expect(described_class.check(yes_gate, {})).to eq(:unclear)
    end

    # The other polarity is just as real: "if she says no, order takeout".
    it "runs on a no when a no is what it wanted" do
      no_gate = described_class.build(var: "hers", is: "no", who: "Chelsea")

      expect(check(no_gate, "nope")).to eq(:met)
      expect(check(no_gate, "yes")).to eq(:unmet)
    end
  end

  describe "a condition that names the answer" do
    let(:pizza) { described_class.build(var: "hers", is: "pizza", who: "Chelsea") }

    it "runs when they named it" do
      expect(check(pizza, "pizza")).to eq(:met)
      expect(check(pizza, "Pizza, please")).to eq(:met)
    end

    it "stops when they named something else" do
      expect(check(pizza, "tacos")).to eq(:unmet)
    end

    # Whole words only. Containment would make "no pizza" a match for pizza.
    it "does not match a word inside another one" do
      expect(check(pizza, "pizzeria")).to eq(:unmet)
    end

    # A multi-select comes back as a list, and naming one of them is enough.
    it "runs when one of several picks named it" do
      expect(check(pizza, ["tacos", "pizza"])).to eq(:met)
    end
  end

  describe ".check with no condition" do
    it "lets everything through" do
      expect(described_class.check(nil, {})).to eq(:met)
    end
  end

  describe ".describe" do
    it "says they said no, when a yes was wanted" do
      expect(described_class.describe(yes_gate, { "hers" => "nope" }, :unmet)).to eq("Chelsea said no")
    end

    it "says they said yes, when a no was wanted" do
      gate = described_class.build(var: "hers", is: "no", who: "Chelsea")

      expect(described_class.describe(gate, { "hers" => "yes" }, :unmet)).to eq("Chelsea said yes")
    end

    it "quotes them back when the answer was neither" do
      line = described_class.describe(yes_gate, { "hers" => "maybe" }, :unclear)

      expect(line).to eq("Chelsea said \"maybe\", and I couldn't tell whether that was a yes")
    end

    it "says so plainly when nobody answered" do
      expect(described_class.describe(yes_gate, {}, :unclear)).to eq("Chelsea never answered that")
    end

    # ask_me has no third party — the person answered it themselves.
    it "speaks to the person when there's nobody else to name" do
      gate = described_class.build(var: "mine", is: "yes")

      expect(described_class.describe(gate, { "mine" => "nah" }, :unmet)).to eq("You said no")
    end

    it "names what they picked instead" do
      gate = described_class.build(var: "hers", is: "pizza", who: "Chelsea")

      expect(described_class.describe(gate, { "hers" => "tacos" }, :unmet))
        .to eq("Chelsea said \"tacos\", not pizza")
    end
  end
end
