require "rails_helper"

# The duration boxes on a prompt take whatever shape the number came out of
# someone's head — "52", "1:32", "1h 32", "97m" — and say underneath what they
# were read as. This covers the reading; `Parse Duration` (a Jil function task)
# implements the identical rules server-side and is what actually stores the
# value.
RSpec.describe "parseDurationMinutes (JS-side)" do
  let(:cases) {
    JsRunner.output("spec/javascript/duration_parse_runner.js", symbolize: true)
  }

  def minutes(key) = cases[key][:minutes]
  def hint(key) = cases[key][:hint]

  it "leaves blank blank rather than calling it zero" do
    # 0 is a claim — "it took no time" — and nobody made it.
    expect(minutes(:blank)).to be_nil
    expect(minutes(:whitespace)).to be_nil
    expect(hint(:blank)).to eq("")
  end

  it "reads a bare number as minutes" do
    expect(minutes(:bare_minutes)).to eq(52)
    expect(minutes(:already_a_number)).to eq(42)
  end

  it "reads a colon as hours:minutes" do
    expect(minutes(:clock_h_mm)).to eq(92)
    expect(minutes(:clock_h_mm_ss)).to eq(65)
  end

  it "reads unit suffixes" do
    expect(minutes(:minutes_suffix)).to eq(97)
    expect(minutes(:hours_only)).to eq(60)
    expect(minutes(:compact_h_and_m)).to eq(684)
    expect(minutes(:fractional_hours)).to eq(90)
    expect(minutes(:spelled_minutes)).to eq(90)
  end

  it "reads a trailing bare number as the minutes half" do
    expect(minutes(:hours_then_bare)).to eq(92)
    expect(minutes(:no_space_h_then_bare)).to eq(150)
  end

  it "does not count a leading number twice" do
    # The trailing-number rule is anchored to the end for exactly this. Loose,
    # "1 hour 32" reads its own "1" again and comes out 93.
    expect(minutes(:spelled_hour_then_bare)).to eq(92)
  end

  it "rounds sub-minute values up rather than to nothing" do
    # "30s" is not zero minutes, and it is not blank either.
    expect(minutes(:seconds_only)).to eq(1)
  end

  it "reports nothing for text carrying no number" do
    expect(minutes(:unreadable)).to be_nil
  end

  it "keeps an explicit zero" do
    expect(minutes(:zero)).to eq(0)
  end

  it "ignores case and surrounding space" do
    expect(minutes(:padded)).to eq(92)
    expect(minutes(:uppercase)).to eq(92)
  end

  it "reads a colon pair as H:MM even where an old value meant MM:SS" do
    # The screenshot parser used to write "56:47" meaning 56m47s. As INPUT the
    # colon means hours, consistently, and the hint says so out loud.
    expect(minutes(:legacy_mm_ss_reads_as_h_mm)).to eq(3407)
    expect(hint(:legacy_mm_ss_reads_as_h_mm)).to eq("56h 47m · 3407 minutes")
  end

  describe "the subtext under the box" do
    it "says minutes on their own below an hour" do
      expect(hint(:bare_minutes)).to eq("52 minutes")
    end

    it "says the clock form AND the minutes above an hour" do
      # The minutes are what gets stored; the clock form is what was meant.
      expect(hint(:clock_h_mm)).to eq("1h 32m · 92 minutes")
      expect(hint(:hours_only)).to eq("1h · 60 minutes")
    end

    it "does not pluralize one minute" do
      expect(hint(:seconds_only)).to eq("1 minute")
    end
  end
end
