require "rails_helper"

RSpec.describe Buddy::Tools do
  describe ".bash_template" do
    it "shell-escapes payload values before substituting" do
      cmd = described_class.bash_template("echo {{name}}", { name: '"; rm -rf ~' })
      # Every metachar gets a leading backslash — the shell will see one
      # literal argument, not a chained command or a tilde expansion.
      expect(cmd).to eq(%q(echo \"\;\ rm\ -rf\ \~))
      expect(cmd).to include('\;')  # metachars escaped, not stripped
    end

    it "handles multi-placeholder templates" do
      cmd = described_class.bash_template("cp {{src}} {{dst}}", { src: "a.txt", dst: "b b.txt" })
      expect(cmd).to eq("cp a.txt b\\ b.txt")
    end
  end

  describe ".validate_payload" do
    let(:tool) {
      {
        args: {
          name:  { type: :string,  required: true },
          count: { type: :integer, required: false, default: 1 },
        },
      }
    }

    it "returns errors when required args are missing" do
      _, errors = described_class.validate_payload(tool, {})
      expect(errors).to include(a_string_matching(/missing required arg :name/))
    end

    it "coerces integers" do
      normalized, errors = described_class.validate_payload(tool, { name: "hi", count: "3" })
      expect(errors).to be_empty
      expect(normalized).to eq(name: "hi", count: 3)
    end

    it "accepts count as a top-level convention even without declaration" do
      minimal = { args: { name: { type: :string, required: true } } }
      normalized, errors = described_class.validate_payload(minimal, { name: "Water", count: "5" })
      expect(errors).to be_empty
      expect(normalized[:count]).to eq(5)
    end

    it "drops undeclared args by default" do
      minimal = { args: { name: { type: :string, required: true } } }
      normalized, = described_class.validate_payload(minimal, { name: "HASS Light", action: "on", target: "mud_room" })
      expect(normalized).to eq(name: "HASS Light")
    end

    it "keeps undeclared args (in order) when passthrough_args is set" do
      dynamic = { args: { name: { type: :string, required: true } }, passthrough_args: true }
      normalized, errors = described_class.validate_payload(
        dynamic, { name: "HASS Light", action: "on", target: "mud_room" }
      )
      expect(errors).to be_empty
      expect(normalized).to eq(name: "HASS Light", action: "on", target: "mud_room")
      expect(normalized.keys).to eq(%i[name action target])
    end

    it "the real call_jil_function tool passes function args through" do
      tool = described_class[:call_jil_function]
      normalized, errors = described_class.validate_payload(
        tool, { name: "HASS Light", action: "on", target: "mud_room", brightness: "40" }
      )
      expect(errors).to be_empty
      expect(normalized.slice(:action, :target, :brightness)).to eq(
        action: "on", target: "mud_room", brightness: "40",
      )
    end
  end

  describe ".function_schemas" do
    # Load real tool files so we're testing the actual registry state.
    before { Rails.root.glob("app/service/buddy/tools/*.rb").each { |f| load f } }

    let(:schemas) { described_class.function_schemas }

    def schema_for(name)
      schemas.find { |s| s[:name] == name }
    end

    it "emits one flat Responses-API function tool per registered tool" do
      expect(schema_for(:complete_chore)).to include(type: :function, name: :complete_chore)
      expect(schema_for(:add_agenda_item)).to be_present
      # Flat, not nested under a :function key — the nested shape is Chat
      # Completions and gets rejected by /responses.
      expect(schema_for(:complete_chore)).not_to have_key(:function)
    end

    it "satisfies strict mode: every property required, no additional properties" do
      schemas.each do |schema|
        params = schema[:parameters]
        expect(params[:additionalProperties]).to be(false), "#{schema[:name]} allows extra properties"
        expect(params[:required]).to match_array(params[:properties].keys),
          "#{schema[:name]} has properties missing from required"
      end
    end

    it "expresses an optional arg as a nullable union so strict mode still lists it" do
      props = schema_for(:complete_chore)[:parameters][:properties]
      expect(props[:chore][:type]).to eq(:string)            # required
      expect(props[:note][:type]).to eq([:string, :null])    # optional
    end

    it "maps registry types onto JSON Schema types" do
      remind = schema_for(:remind_when)[:parameters][:properties]
      expect(remind[:trigger]).to include(type: :string, enum: %i[arrive depart chore event agenda deploy])
      expect(remind[:repeat][:type]).to eq([:boolean, :null])

      agenda = schema_for(:add_agenda_item)[:parameters][:properties]
      expect(agenda[:duration][:type]).to eq([:integer, :null])   # :duration_min
      expect(agenda[:at][:type]).to eq(:string)                   # :iso_time
      expect(agenda[:at][:description]).to include("ISO8601")
    end

    it "admits null in a nullable enum's value list" do
      kind = schema_for(:schedule_reminder)[:parameters][:properties][:kind]
      expect(kind[:type]).to eq([:string, :null])
      expect(kind[:enum]).to include(nil)
      expect(kind[:description]).to include("Defaults to reminder")
    end

    it "advertises count only on tools that can actually collapse repeats" do
      expect(schema_for(:complete_chore)[:parameters][:properties]).to have_key(:count)
      expect(schema_for(:create_chore)[:parameters][:properties]).not_to have_key(:count)
    end

    it "gives the pass-through tool a freeform args object and opts out of strict" do
      jil = schema_for(:call_jil_function)
      expect(jil[:strict]).to be(false)
      expect(jil[:parameters][:properties][:args]).to include(type: :object, additionalProperties: true)
    end
  end

  # Prose used to ride on the call so an action turn could finish in one request.
  # Buddy now stays quiet on the call and speaks on the round after, with the
  # resolved outcome in hand, so no tool advertises a place to put words.
  describe "the retired reply field" do
    before { Rails.root.glob("app/service/buddy/tools/*.rb").each { |f| load f } }

    it "is offered by no tool at all" do
      described_class.function_schemas.each do |schema|
        expect(schema[:parameters][:properties]).not_to have_key(:reply), "#{schema[:name]} still offers reply"
      end
    end

    # The pass-through tool takes undeclared keys as Jil arguments, so a stray
    # `reply` would be forwarded to the function as a parameter.
    it "is still stripped defensively off a pass-through call" do
      tool = described_class[:call_jil_function]

      out = described_class.normalize_function_arguments(tool, {
        "name" => "Tesla Start", "reply" => "Starting it.", "args" => { "temp" => 72 }
      })

      expect(out).to eq(name: "Tesla Start", temp: 72)
    end
  end

  describe ".normalize_function_arguments" do
    before { Rails.root.glob("app/service/buddy/tools/*.rb").each { |f| load f } }

    it "flattens a pass-through tool's nested args so tool procs see the old shape" do
      tool = described_class[:call_jil_function]

      out = described_class.normalize_function_arguments(tool, {
        "name" => "Tesla Start", "args" => { "temp" => 72, "dest" => "Home" }
      })

      expect(out).to eq(name: "Tesla Start", temp: 72, dest: "Home")
    end

    it "strips reply so a pass-through tool never forwards prose as a Jil argument" do
      tool = described_class[:call_jil_function]

      out = described_class.normalize_function_arguments(tool, {
        "name" => "Tesla Start", "reply" => "Starting the car.", "args" => { "temp" => 72 }
      })

      expect(out).to eq(name: "Tesla Start", temp: 72)
    end

    it "leaves an ordinary tool's arguments alone apart from symbolizing keys" do
      tool = described_class[:complete_chore]

      out = described_class.normalize_function_arguments(tool, { "chore" => "dishes", "count" => 2 })

      expect(out).to eq(chore: "dishes", count: 2)
    end
  end
end
