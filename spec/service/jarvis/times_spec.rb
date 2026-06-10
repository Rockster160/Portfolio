require "rails_helper"

RSpec.describe Jarvis::Times do
  describe ".extract_time" do
    describe "hyphen boundaries" do
      it "does not match a day word embedded in a hyphenated identifier" do
        pre_text, parsed = described_class.extract_time("set evening-mode")
        expect(pre_text).to be_nil
        expect(parsed).to be_nil
      end

      it "does not match a month word embedded in a hyphenated identifier" do
        pre_text, parsed = described_class.extract_time("trigger march-update")
        expect(pre_text).to be_nil
        expect(parsed).to be_nil
      end
    end

    describe "weak day words require a qualifier" do
      it "does not match bare 'evening'" do
        pre_text, parsed = described_class.extract_time("remind me evening")
        expect(pre_text).to be_nil
        expect(parsed).to be_nil
      end

      it "does not match 'evening' surrounded by non-time words" do
        pre_text, parsed = described_class.extract_time("trigger evening mode")
        expect(pre_text).to be_nil
        expect(parsed).to be_nil
      end

      it "does not match bare 'morning' / 'afternoon' / 'night'" do
        %w[morning afternoon night].each do |w|
          pre_text, parsed = described_class.extract_time("ping me #{w}")
          expect(pre_text).to be_nil, "expected '#{w}' alone to not match, got #{pre_text.inspect}"
          expect(parsed).to be_nil
        end
      end

      it "matches 'this evening'" do
        pre_text, parsed = described_class.extract_time("remind me this evening to bake sweets")
        expect(pre_text).to eq("this evening")
        expect(parsed).to be_present
      end

      it "matches 'in the evening'" do
        pre_text, parsed = described_class.extract_time("remind me in the evening to bake sweets")
        expect(pre_text).to eq("in the evening")
        expect(parsed).to be_present
      end

      it "matches 'tomorrow morning' (strong + weak)" do
        pre_text, parsed = described_class.extract_time("remind me tomorrow morning")
        expect(pre_text).to eq("tomorrow morning")
        expect(parsed).to be_present
      end
    end

    describe "strong day words stand alone" do
      it "matches bare 'tomorrow'" do
        pre_text, parsed = described_class.extract_time("remind me tomorrow")
        expect(pre_text).to eq("tomorrow")
        expect(parsed).to be_present
      end

      it "matches bare 'tonight'" do
        pre_text, parsed = described_class.extract_time("ping me tonight")
        expect(pre_text).to eq("tonight")
        expect(parsed).to be_present
      end

      it "matches a day name" do
        pre_text, parsed = described_class.extract_time("remind me monday to call mom")
        expect(pre_text).to eq("monday")
        expect(parsed).to be_present
      end

      it "matches 'next monday'" do
        pre_text, parsed = described_class.extract_time("schedule meeting next monday")
        expect(pre_text).to include("next monday")
        expect(parsed).to be_present
      end
    end

    describe "noon / midnight" do
      it "matches 'at noon'" do
        pre_text, parsed = described_class.extract_time("remind me at noon to eat")
        expect(pre_text).to include("at noon")
        expect(parsed).to be_present
        expect(parsed.hour).to eq(12)
      end

      it "matches 'at midnight'" do
        pre_text, parsed = described_class.extract_time("wake me at midnight")
        expect(pre_text).to include("at midnight")
        expect(parsed).to be_present
        expect(parsed.hour).to eq(0)
      end
    end

    describe "explicit clock times still work" do
      it "matches 'at 3pm'" do
        pre_text, parsed = described_class.extract_time("remind me at 3pm")
        expect(pre_text).to include("at 3pm")
        expect(parsed).to be_present
      end

      it "matches 'tomorrow at 3pm'" do
        pre_text, parsed = described_class.extract_time("meeting tomorrow at 3pm")
        expect(pre_text).to include("at 3pm")
        expect(parsed).to be_present
      end
    end

    describe "future context" do
      around { |ex| Time.use_zone("Mountain Time (US & Canada)") { ex.run } }

      it "rolls 'at 8:30am' into tomorrow when context is :future and now is past 8:30am" do
        Timecop.freeze(Time.zone.local(2026, 6, 9, 23, 57)) do
          pre_text, parsed = described_class.extract_time(
            "agenda add berry breakfast at 8:30am",
            context: :future,
          )
          expect(pre_text).to include("at 8:30am")
          expect(parsed).to be > Time.current
          expect(parsed.hour).to eq(8)
          expect(parsed.min).to eq(30)
          expect(parsed.to_date).to eq(Date.new(2026, 6, 10))
        end
      end

      it "leaves 'at 2pm' in the past when no context is forced (default Jarvis behavior)" do
        Timecop.freeze(Time.zone.local(2026, 6, 9, 23, 57)) do
          _pre_text, parsed = described_class.extract_time("log something at 2pm")
          expect(parsed.to_date).to eq(Date.new(2026, 6, 9))
          expect(parsed.hour).to eq(14)
        end
      end
    end

    describe "relative offsets" do
      it "matches 'in 3 hours'" do
        pre_text, parsed = described_class.extract_time("remind me in 3 hours")
        expect(pre_text).to include("in 3 hours")
        expect(parsed).to be_present
      end

      it "matches '5 minutes from now'" do
        pre_text, parsed = described_class.extract_time("ping me 5 minutes from now")
        expect(pre_text).to include("5 minutes from now")
        expect(parsed).to be_present
      end
    end
  end
end
