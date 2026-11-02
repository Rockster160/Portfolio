require "rails_helper"

# The page builder takes one timer per line. Every line has to mean
# something — anything not read as an option is the name — so these pin
# down what each shape of line turns into, and the words the preview
# says about it while it's being typed.
RSpec.describe "page builder lines (JS-side)" do
  let(:cases) {
    JsRunner.output("spec/javascript/timer_quick_lines_runner.js", symbolize: true)
  }

  def timers(key) = cases[key][:timers]
  def timer(key) = timers(key).sole
  def preview(key) = cases[key][:preview]

  it "reads a bare duration as an unnamed countdown, ignoring the comment" do
    expect(timer(:bare_duration)).to include(kind: "countdown", name: "", duration_ms: 10_000)
  end

  it "reads a bare name as a counter from 0" do
    expect(timer(:bare_name)).to include(kind: "counter", name: "Rocco", value: 0, reset_value: 0)
  end

  it "reads a name and a number as a counter starting there" do
    expect(timer(:name_and_start)).to include(kind: "counter", name: "Chelsea", value: 50, reset_value: 50)
  end

  it "reads durations in every form they get typed" do
    expect(timer(:spelled_duration)).to include(name: "Pasta", duration_ms: 540_000)
    expect(timer(:split_duration)).to include(name: "Bread", duration_ms: 5_400_000)
    expect(timer(:colon_duration)).to include(name: "Tea", duration_ms: 270_000)
  end

  it "gives a countdown a soft chime by default" do
    expect(timer(:bare_duration)[:callbacks].sole[:then]).to include(chime: "soft", cadence: "once")
  end

  it "reads the countdown sound options" do
    expect(timer(:repeat_alarm)).to include(repeat: true)
    expect(timer(:repeat_alarm)[:callbacks].sole[:then]).to include(chime: "bell", cadence: "10s")
    expect(timer(:quiet)[:callbacks]).to eq([])
    expect(timer(:chime)[:callbacks].sole[:then]).to include(chime: "bell", cadence: "once")
  end

  it "reads counter steps and limits" do
    expect(timer(:step_and_range)).to include(step: 5, min_value: 0, max_value: 100)
    expect(timer(:out_of)).to include(value: 0, min_value: 0, max_value: 10)
    expect(timer(:negative_start)).to include(value: -5)
  end

  it "reads 'min' after a number as a floor, not minutes, when a number follows it" do
    expect(timer(:min_max_words)).to include(kind: "counter", value: 3, min_value: 0, max_value: 5)
  end

  it "keeps option words as the name when they have nothing to apply to" do
    expect(timer(:min_as_name)).to include(kind: "counter", name: "Min")
    expect(timer(:quoted_keyword)).to include(name: "Big Mike", value: 10)
    expect(timer(:quoted_keyword)).not_to have_key(:width)
  end

  it "makes numbered copies, and leaves unnamed copies unnamed" do
    expect(timers(:copies_named).pluck(:name)).to eq(["Egg 1", "Egg 2", "Egg 3"])
    expect(timers(:copies_unnamed).pluck(:name)).to eq(["", ""])
  end

  it "reads colors, and leaves a # word that isn't one in the name" do
    expect(timer(:hex_color)).to include(color: "#f80")
    expect(timer(:named_color)).to include(color: "#3fb950")
    expect(timer(:unknown_hash_word)).to include(name: "Player #1")
  end

  it "gives each uncolored timer the next palette color" do
    expect(timers(:multi).pluck(:color).uniq.length).to eq(3)
  end

  it "reads a size word as the card size" do
    expect(timer(:size)).to include(name: "Rocco", width: 3)
  end

  it "reads 'Name: a, b, c' as a dial, and a colon without commas as a name" do
    expect(timer(:dial)).to include(kind: "dial", name: "Turn")
    expect(timer(:dial)[:dial_config][:sections].pluck(:name)).to eq(%w[Rocco Chelsea Eve])
    expect(timer(:colon_name_without_comma)).to include(kind: "counter", name: "Note: hello")
  end

  it "skips blank and comment-only lines" do
    expect(timers(:comment_only)).to eq([])
    expect(timers(:blank)).to eq([])
    expect(timers(:multi).pluck(:kind)).to eq(%w[countdown counter counter])
  end

  describe "fields written back as a line (the timer form)" do
    def line(key) = cases[:serialized][key][:line]
    def back(key) = cases[:serialized][key][:back]

    it "writes the short form a person would type" do
      expect(line(:countdown)).to eq("Tea 3m")
      expect(line(:counter_plain)).to eq("Rocco")
      expect(line(:counter_full)).to eq("Score +5 /100 big #green")
      expect(line(:dial)).to eq("Turn full: Rocco, Eve")
    end

    it "reads every line back as the fields it came from" do
      expect(back(:countdown_options)).to include(kind: "countdown", seconds: 45, repeat: true, alarm: true, chime: "ding")
      expect(back(:quiet)).to include(kind: "countdown", seconds: 600, quiet: true)
      expect(back(:counter_full)).to include(step: 5, min: 0, max: 100, size: 3, color: "#3fb950")
      expect(back(:counter_floor)).to include(kind: "counter", value: 3, min: 0)
      expect(back(:counter_ceiling)).to include(value: 50, max: 60)
      expect(back(:dial)).to include(kind: "dial", name: "Turn", size: 4, sections: %w[Rocco Eve])
    end

    it "quotes a name that would otherwise read as an option" do
      expect(line(:option_word_name)).to eq('"Big"')
      expect(back(:option_word_name)).to include(name: "Big", size: nil)
    end

    it "leaves a dial's sections out when a line can't hold them, without naming a type" do
      expect(line(:dial_complex)).to eq("Game")
      expect(back(:dial_complex)).to include(kindSaid: false)
    end
  end

  describe "the preview under the box" do
    it "says what each line makes, in words" do
      expect(preview(:bare_name)).to eq("counter from 0")
      expect(preview(:spelled_duration)).to eq("9 minutes countdown")
      expect(preview(:repeat_alarm)).to eq("45 seconds countdown · repeats · rings until stopped")
      expect(preview(:step_and_range)).to eq("counter from 0 · steps of 5 · 0 to 100")
      expect(preview(:dial)).to eq("dial: Rocco → Chelsea → Eve")
      expect(preview(:copies_named)).to eq("3 minutes countdown · × 3")
      expect(preview(:size)).to eq("counter from 0 · large")
    end
  end
end
