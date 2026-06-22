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

    # Previously the top-of-file `NOT WORKING: ... on the 16th` TODO. The
    # parser now rewrites `(on|for) the Nth` into a concrete `Month N` so
    # Chronic has something it knows how to parse, with current-vs-next
    # month chosen by whether N is still future this month.
    describe "ordinal day-of-month ('on the 16th')" do
      around { |ex| Time.use_zone("Mountain Time (US & Canada)") { ex.run } }

      it "resolves 'on the 16th' to the 16th of the current month when still future" do
        Timecop.freeze(Time.zone.local(2026, 6, 10, 9, 0)) do
          pre_text, parsed = described_class.extract_time("dentist on the 16th")
          expect(pre_text).to be_present
          expect(parsed.to_date).to eq(Date.new(2026, 6, 16))
        end
      end

      it "rolls 'on the 16th' to next month when the 16th already passed" do
        Timecop.freeze(Time.zone.local(2026, 6, 20, 9, 0)) do
          _pre_text, parsed = described_class.extract_time("dentist on the 16th")
          expect(parsed.to_date).to eq(Date.new(2026, 7, 16))
        end
      end

      it "honors 'for the 22nd' the same way" do
        Timecop.freeze(Time.zone.local(2026, 6, 10, 9, 0)) do
          _pre_text, parsed = described_class.extract_time("reserve a table for the 22nd")
          expect(parsed.to_date).to eq(Date.new(2026, 6, 22))
        end
      end

      it "combines 'on the 16th at 7pm' into one timestamp" do
        Timecop.freeze(Time.zone.local(2026, 6, 10, 9, 0)) do
          _pre_text, parsed = described_class.extract_time("dentist on the 16th at 7pm")
          expect(parsed.to_date).to eq(Date.new(2026, 6, 16))
          expect(parsed.hour).to eq(19)
        end
      end

      it "rolls forward when the requested day doesn't exist in current month (Jan 30 → Mar 30 from Feb)" do
        Timecop.freeze(Time.zone.local(2026, 2, 5, 9, 0)) do
          _pre_text, parsed = described_class.extract_time("ping me on the 30th")
          # Feb 2026 has no 30; March 2026 does (skip Feb entirely).
          expect(parsed.to_date).to eq(Date.new(2026, 3, 30))
        end
      end

      it "leaves nonsensical ordinals (e.g. 'on the 99th') alone" do
        _pre_text, parsed = described_class.extract_time("file on the 99th")
        # 99th can't resolve; Chronic should also return nil.
        expect(parsed).to be_nil
      end
    end
  end
end
