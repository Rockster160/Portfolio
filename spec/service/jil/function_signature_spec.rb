require "rails_helper"

# What order a function task's `params` array comes out in.
#
# This is load-bearing in a way that doesn't look it: a task reading its args
# positionally has no way to notice they arrived shuffled. It just runs with
# action="all", matches nothing, and returns a cheerful string.
RSpec.describe Jil::FunctionSignature do
  def keys(sig) = described_class.slots(sig).map { |s| s[:key] }
  def defaults(sig) = described_class.slots(sig).map { |s| s[:default] }

  describe ".slots" do
    it "reads a quoted label as the name of the arg after it" do
      sig = '"Action" TAB ["open" "close"]("open") BR "Which" TAB String BR "Position" TAB Numeric'

      expect(keys(sig)).to eq(%w[action which position])
    end

    it "snake-cases a multi-word label, the way both callers spell it" do
      expect(keys('"Fallback minutes" TAB Numeric(180)')).to eq(["fallback_minutes"])
      expect(keys('"ON for" TAB Numeric(400)')).to eq(["on_for"])
    end

    it "takes the default out of the parentheses after the type" do
      sig = '"Zone" TAB ["main" "upstairs"]("main") BR "Mode" TAB ["keep" "off"]("keep") BR "Temperature" TAB Numeric(0)'

      expect(defaults(sig)).to eq(["main", "keep", "0"])
    end

    it "leaves a default nil when the signature declares none" do
      expect(defaults('"Execute" TAB Boolean')).to eq([nil])
    end

    it "reads the Type:Label form" do
      expect(keys("String:Icon TAB Text:Query")).to eq(%w[icon query])
      expect(keys("String|Array:From String|Array:To Date:At")).to eq(%w[from to at])
    end

    it "takes a :Label over a quoted label sitting in front of it" do
      # The quoted one labels the ROW; the colon one is attached to this arg.
      expect(keys('Numeric:Diff TAB "Figs" Numeric(1):SigFigs')).to eq(%w[diff sigfigs])
    end

    it "handles a label quoted after the colon" do
      expect(keys('String:Who Numeric:"$" String:Note')).to eq(["who", "$", "note"])
      expect(keys('Numeric:"Dur ms" Numeric:"Flash ms"')).to eq(%w[dur_ms flash_ms])
    end

    # `"Quiet for" TAB Numeric(30) TAB "minutes"` — "minutes" is a unit printed
    # next to the field, not a fourth thing to send.
    it "ignores a trailing quoted word with no arg after it" do
      expect(keys('"Quiet for" TAB Numeric(30) TAB "minutes"')).to eq(["quiet_for"])
    end

    it "still counts an arg the signature never named" do
      expect(keys('String:Icon TAB ["Need" "Want"] Text:Query')).to eq(["icon", nil, "query"])
      expect(keys('["chelsea" "red" "purple"]')).to eq([nil])
      expect(keys("Boolean")).to eq([nil])
    end

    it "reads commas in an enum as separators, not as args" do
      expect(keys("String:Who [Pay, Request] Numeric:Amount")).to eq(["who", nil, "amount"])
    end

    it "counts a content block's named options as args of their own" do
      sig = "content([width:Numeric(10) current:Numeric total:Numeric])"

      expect(keys(sig)).to eq(%w[width current total])
      expect(defaults(sig)).to eq(["10", nil, nil])
    end

    it "reads a content option whose type is an enum" do
      sig = 'content([channel:String("teeth") color:["Blue" "Red"] rgb:String("0,40,150") flash_ms:Numeric])'

      expect(keys(sig)).to eq(%w[channel color rgb flash_ms])
      expect(defaults(sig)).to eq(["teeth", nil, "0,40,150", nil])
    end

    # `content(Hash|Keyval)` says what SHAPE arrives, not which fields — there's
    # nothing positional in it.
    it "adds nothing for a content block that only lists types" do
      expect(keys('"ID: " Numeric content(Hash|Keyval|ActionEvent)')).to eq(["id:"])
      expect(keys("String content(Hash|Keyval)")).to eq([nil])
    end

    it "has no slots for a function taking nothing" do
      expect(described_class.slots(nil)).to eq([])
      expect(described_class.slots("")).to eq([])
    end
  end

  describe ".params" do
    # Prod byte_message 3845. `lockdown` is BuddyRoutine 4; its step payload
    # lives in jsonb, and Postgres sorts object keys by length then bytes, so
    # {action, which, position} came back {which, action, position}. The blinds
    # were sent action="all" which="close", matched no case in HASS Blinds, and
    # nothing moved — over a reply that said the house was locked down.
    describe "when the caller's keys arrive in the wrong order" do
      let(:blinds) {
        '"Action" TAB ["open" "close" "stop" "position"]("open") BR ' \
          '"Which" TAB ["all" "great_room" "stairs"]("great_room") BR "Position" TAB Numeric'
      }

      it "puts them back in signature order" do
        scrambled = { "which" => "all", "action" => "close", "position" => 0 }

        expect(described_class.params(blinds, scrambled)).to eq(["close", "all", 0])
      end

      it "gets the same answer whichever order they came in" do
        ordered = { "action" => "close", "which" => "all", "position" => 0 }

        expect(described_class.params(blinds, ordered)).to eq(["close", "all", 0])
      end

      it "reads symbol keys too" do
        expect(described_class.params(blinds, { which: "all", action: "close", position: 0 }))
          .to eq(["close", "all", 0])
      end
    end

    # The other half of the same bug: `params` used to be built from the keys
    # the caller actually SENT, so one arg left out slid every later arg onto
    # the wrong slot.
    describe "when the caller leaves an arg out" do
      let(:thermostat) {
        '"Zone" TAB ["main" "upstairs"]("main") BR ' \
          '"Mode" TAB ["keep" "off" "heat" "cool" "heat_cool"]("keep") BR "Temperature" TAB Numeric(0)'
      }

      # "Set upstairs to 70" carries no mode. Sent as two values it made 70 the
      # MODE; the signature says the missing one is `keep`, which holds whatever
      # the thermostat is already running.
      it "fills the hole with the declared default instead of shifting" do
        expect(described_class.params(thermostat, { "zone" => "upstairs", "temperature" => 70 }))
          .to eq(["upstairs", "keep", 70])
      end

      it "leaves a hole nil when the signature declares no default" do
        sig = '"Camera" TAB ["doorbell" "driveway"]("doorbell") BR "When" TAB String BR ' \
              '"Event" TAB ["any" "person"]("any")'

        expect(described_class.params(sig, { "camera" => "driveway", "event" => "person" }))
          .to eq(["driveway", nil, "person"])
      end
    end

    describe "when the signature never named its args" do
      it "keeps them in the order they arrived, which is all there is to go on" do
        given = { "icon" => "🍎", "kind" => "Need", "query" => "food" }

        expect(described_class.params('String:Icon TAB ["Need" "Want"] Text:Query', given))
          .to eq(["🍎", "Need", "food"])
      end

      it "falls back to the given order when nothing can be parsed" do
        expect(described_class.params(nil, { "b" => 2, "a" => 1 })).to eq([2, 1])
        expect(described_class.params("", { "b" => 2, "a" => 1 })).to eq([2, 1])
      end

      it "hands a single unnamed arg straight through" do
        expect(described_class.params("Boolean", { "execute" => true })).to eq([true])
      end
    end

    it "sends nothing for a function that takes nothing" do
      expect(described_class.params("", {})).to eq([])
    end
  end

  # The parser only earns its keep if it survives the signatures actually on the
  # account, so these are copied verbatim off prod `tasks.listener`.
  describe "against the signatures in production" do
    live = {
      "HASS Blinds"       => [
        '"Action" TAB ["open" "close" "stop" "position"]("open") BR "Which" TAB ' \
        '["all" "great_room" "great_top" "great_bottom" "stairs"]("great_room") BR "Position" TAB Numeric',
        %w[action which position],
      ],
      "HASS Thermostat"   => [
        '"Zone" TAB ["main" "upstairs"]("main") BR "Mode" TAB ' \
        '["keep" "off" "heat" "cool" "heat_cool"]("keep") BR "Temperature" TAB Numeric(0)',
        %w[zone mode temperature],
      ],
      "Camera Last Seen"  => [
        '"Camera" TAB ["doorbell" "driveway" "backyard"]("doorbell") BR "When" TAB String BR ' \
        '"Event" TAB ["any" "person" "pet" "vehicle" "ring"]("any")',
        %w[camera when event],
      ],
      "Notify At"         => [
        '"ID" String TAB "At" Date BR "Title" String BR "Body" Text BR "While" TAB ' \
        '["awake" "asleep"]("awake") BR "Icon" TAB String BR "Alert" TAB Boolean',
        %w[id at title body while icon alert],
      ],
      "Chore Tile"        => [
        '"Chore" TAB Numeric BR "Username" TAB String BR "Text" TAB String BR "Subtitle" TAB String BR ' \
        '"Monitor" TAB String BR "Color" TAB String BR "Pressed" TAB Boolean',
        %w[chore username text subtitle monitor color pressed],
      ],
      "Blink"             => [
        '"Color" TAB ["Blue" "Orange"]("Blue") BR "Blinks" TAB Numeric(3) BR "ON for" TAB Numeric(400) BR ' \
        '"OFF for" TAB Numeric(200)',
        %w[color blinks on_for off_for],
      ],
      "Progress Bar"      => [
        '"Progress Bar" TAB content([width:Numeric(10) current:Numeric total:Numeric])',
        %w[width current total],
      ],
      "Ledger Entry"      => [
        "content([person:String deposit:Numeric withdraw:Numeric note:Text timestamp:Date])",
        %w[person deposit withdraw note timestamp],
      ],
      "Whisper Sound"     => ['"Sound" TAB ["alarm" "nap" "wake" "birthday" "default"]("wake")', %w[sound]],
      "Whisper Quiet For" => ['"Quiet for" TAB Numeric(30) TAB "minutes"', %w[quiet_for]],
      "Travel Minutes"    => ["String|Array:From String|Array:To Date:At", %w[from to at]],
      "Yoga Lights"       => ['"Execute" TAB Boolean', %w[execute]],
    }

    live.each do |name, (signature, expected)|
      it "reads #{name} as #{expected.join(", ")}" do
        expect(keys(signature)).to eq(expected)
      end
    end
  end
end
