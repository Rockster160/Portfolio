require "rails_helper"

# A routine step as a form and as a payload.
#
# The panel builds its fields from the tool registry, so the shapes here are the
# ones /buddy/routines/tools hands over. The server validates the payload again
# through the same sanitize a routine saved in conversation goes through — this
# is about what reaches it, and about a time meaning what was picked.
RSpec.describe "Routine step fields" do
  # The shapes /buddy/routines/tools hands over, one of each kind a field can
  # hold. A local rather than a constant, so it doesn't leak out of the block.
  args = {
    chore:   { key: "chore", type: "string", required: true, description: "Fuzzy chore name" },
    note:    { key: "note", type: "string", required: false },
    seconds: { key: "seconds", type: "integer", required: true },
    hold:    { key: "then_continue", type: "boolean", required: false },
    kind:    { key: "kind", type: "enum", required: false, values: %w[reminder prompt] },
    at:      { key: "at", type: "iso_time", required: false },
    dur:     { key: "seconds", type: "duration", unit: "seconds", required: false },
    brk:     { key: "break_minutes", type: "duration", unit: "minutes", required: false },
  }

  # One node process for the whole file: each example below asks a different
  # question and they all needed the same module loaded to answer it.
  let(:out) {
    module_path = Rails.root.join("app/javascript/src/pages/byte/buddy/routine_step.js")
    script = <<~JS
      import { fieldFor, readPayload, stepPhrase, durationRead } from "#{module_path}";
      const a = #{args.transform_keys(&:to_s).to_json};
      const read = (args, values) => readPayload(args, (arg) => values[arg.key] ?? null);

      console.log(JSON.stringify({
        text_field:    fieldFor(a.chore),
        enum_field:    fieldFor(a.kind),
        bool_field:    fieldFor(a.hold),
        number_field:  fieldFor(a.seconds),
        time_field:    fieldFor(a.at),
        escaped:       fieldFor({ ...a.chore, description: "<b>bold</b>" }),
        escaped_attr:  fieldFor({ ...a.kind, values: ['say "hi"', "plain"] }),

        filled:        read([a.chore, a.note], { chore: { value: " Load Dishes " }, note: { value: "" } }),
        blank_needed:  read([a.chore], { chore: { value: "   " } }),
        numbers:       read([a.seconds], { seconds: { value: "90" } }),
        unticked:      read([a.hold], { then_continue: { value: "on", checked: false } }),
        ticked:        read([a.hold], { then_continue: { value: "on", checked: true } }),
        no_field:      read([a.chore], {}),
        time:          read([a.at], { at: { value: "2026-10-14T11:00" } }),
        bad_time:      read([a.at], { at: { value: "not a time" } }),

        dur_field:     fieldFor(a.dur),
        dur_plain:     read([a.dur], { seconds: { value: "4m" } }),
        dur_compound:  read([a.dur], { seconds: { value: "4m30s" } }),
        dur_loose:     read([a.dur], { seconds: { value: "1h 30m" } }),
        dur_colon:     read([a.dur], { seconds: { value: "4:30" } }),
        dur_bare:      read([a.dur], { seconds: { value: "90" } }),
        dur_junk:      read([a.dur], { seconds: { value: "soonish" } }),
        dur_minutes:   read([a.brk], { break_minutes: { value: "90s" } }),

        read_plain:    durationRead("4m30s"),
        read_junk:     durationRead("soonish"),
        read_blank:    durationRead("  "),

        named_step:    stepPhrase({ tool_name: "complete_chore", payload: { chore: "8oz Water" } }),
        bare_step:     stepPhrase({ tool_name: "check_weather", payload: {} }),
      }));
    JS
    JsRunner.eval_module(script, symbolize: true)
  }

  describe "the field it draws" do
    it "gives a plain argument a text box carrying its own hint" do
      expect(out[:text_field]).to include('type="text"', 'data-arg-key="chore"')
      expect(out[:text_field]).to include("Fuzzy chore name")
    end

    # The spelling IS the argument, so there is nothing to type wrong.
    it "gives a fixed set of values a select, with a blank when it's optional" do
      expect(out[:enum_field]).to include("<select", '<option value="reminder">')
      expect(out[:enum_field]).to include('<option value=""></option>')
    end

    it "gives a flag a checkbox, in front of its name rather than under it" do
      expect(out[:bool_field]).to include('type="checkbox"')
      expect(out[:bool_field]).to include("byte-arg-inline")
    end

    it "gives a number a numeric keypad and a time a picker" do
      expect(out[:number_field]).to include('type="number"', 'inputmode="numeric"')
      expect(out[:time_field]).to include('type="datetime-local"')
    end

    it "marks the ones that have to be filled in" do
      expect(out[:text_field]).to include("byte-arg-req")
      expect(out[:bool_field]).not_to include("byte-arg-req")
    end

    # The descriptions and the enum values are the registry's, not ours, and
    # both are interpolated into markup - one as text, one into an attribute.
    it "escapes a description rather than rendering it" do
      expect(out[:escaped]).to include("&lt;b&gt;bold&lt;/b&gt;")
      expect(out[:escaped]).not_to include("<b>")
    end

    it "escapes a value that would otherwise close the attribute it sits in" do
      expect(out[:escaped_attr]).to include('value="say &quot;hi&quot;"')
    end
  end

  # Two arguments because the model picks whichever matches how it was said.
  # A person filling in a form has one length and no reason to care which box
  # it belongs in - and the pair arrived as two empty fields under a hint
  # explaining to use one and not the other.
  describe "a length" do
    it "is one text box taking the shorthand used everywhere else" do
      expect(out[:dur_field]).to include('type="text"', 'data-arg-type="duration"')
      expect(out[:dur_field]).to include("4m30s").and include("1h30m")
    end

    it "takes every shape that box takes" do
      expect(out.dig(:dur_plain, :payload)).to eq(seconds: 240)
      expect(out.dig(:dur_compound, :payload)).to eq(seconds: 270)
      expect(out.dig(:dur_loose, :payload)).to eq(seconds: 5400)
      expect(out.dig(:dur_colon, :payload)).to eq(seconds: 270)
      expect(out.dig(:dur_bare, :payload)).to eq(seconds: 90)
    end

    it "converts into whichever unit the argument wanted" do
      expect(out.dig(:dur_minutes, :payload)).to eq(break_minutes: 2)
    end

    it "treats one it can't read as one that isn't filled in" do
      expect(out.dig(:dur_junk, :missing)).to eq(["seconds"])
      expect(out.dig(:dur_junk, :payload)).to be_empty
    end

    # "4m30" being four and a half minutes is only obvious once something says
    # so, and a length nothing can read has to say that while it can still be
    # fixed rather than on the way out.
    it "says what it was understood as, or that it wasn't" do
      expect(out[:read_plain]).to eq("4 minutes, 30 seconds")
      expect(out[:read_junk]).to match(/can't read/i)
      expect(out[:read_blank]).to eq("")
    end
  end

  describe "what it reads back" do
    it "trims what was typed" do
      expect(out.dig(:filled, :payload)).to eq(chore: "Load Dishes")
    end

    # The server reads a blank as missing, and an argument nobody filled in is
    # one they didn't mean to set.
    it "leaves a blank optional one out rather than sending it empty" do
      expect(out.dig(:filled, :payload)).not_to have_key(:note)
      expect(out.dig(:filled, :missing)).to be_empty
    end

    it "names a blank required one back instead of sending it to be refused" do
      expect(out.dig(:blank_needed, :missing)).to eq(["chore"])
      expect(out.dig(:blank_needed, :payload)).to be_empty
    end

    it "sends a number as a number" do
      expect(out.dig(:numbers, :payload)).to eq(seconds: 90)
    end

    it "sends a ticked flag and omits an unticked one" do
      expect(out.dig(:ticked, :payload)).to eq(then_continue: true)
      expect(out.dig(:unticked, :payload)).to be_empty
    end

    it "says nothing about an argument with no field on screen" do
      expect(out[:no_field]).to eq(payload: {}, missing: [])
    end

    # "2026-10-14T11:00" on its own leaves the zone to be guessed at the other
    # end, which is how a time lands six hours out.
    it "sends a picked time as a full instant, not a local string" do
      expect(out.dig(:time, :payload, :at)).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
    end

    it "treats a time it can't read as one that isn't filled in" do
      expect(out.dig(:bad_time, :missing)).to eq(["at"])
    end
  end

  # "complete chore" twice over says nothing about which two steps those are.
  describe "how a step reads in the list" do
    it "leads with the argument that identifies it" do
      expect(out[:named_step]).to eq("complete chore: 8oz Water")
    end

    it "falls back to the action's own name" do
      expect(out[:bare_step]).to eq("check weather")
    end
  end
end
