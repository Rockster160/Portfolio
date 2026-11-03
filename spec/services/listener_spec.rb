RSpec.describe Task do
  include ActiveJob::TestHelper

  let(:admin) { User.me }
  let(:other_user) {
    User.find_or_create_by!(username: :luffy) { |u|
      u.password = :password
      u.password_confirmation = :password
    }
  }

  def expect_trigger_listeners(user, trigger, trigger_data, expected_listeners)
    @listeners = []
    trigger_data_parsed = Tokenizing::TriggerData.parse(trigger_data, as: user)
    serialized = Tokenizing::TriggerData.serialize(trigger_data_parsed, use_global_id: false)

    @tasks.select { |task|
      next false unless task.user_id == user.id

      did_match = task.listener_match?(trigger) { |sub_listener|
        next true if sub_listener == trigger.to_s

        if trigger == :monitor && trigger_data_parsed.is_a?(::Hash) && trigger_data_parsed[:channel].present?
          next true if sub_listener.match?(/\A\s*monitor::?#{Regexp.escape(trigger_data_parsed[:channel].to_s)}\s*\z/)
        end

        ::Tokenizing::Matcher.new(sub_listener, { trigger => serialized }).match?
      }

      did_match
    }.each { |task| @listeners << task.listener }

    expect(@listeners).to match_array(expected_listeners)
  end

  context "with basic triggers" do
    before do
      @tasks = Task.create([
        { user: other_user, listener: "travel" },
        { user: admin, listener: "travel" },
        { user: admin, listener: "travel:depart:home" },
        { user: admin, listener: "travel:depart" },
        { user: admin, listener: "travel:arrive" },
        { user: admin, listener: "travel:arrive:home" },
        { user: admin, listener: "travel:home" },
        { user: admin, listener: "travel:arrive:!home" },
        { user: admin, listener: "event:name:ANY(food soda drink alcohol treat snack)" },
        { user: admin, listener: "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)" },
        { user: admin, listener: "email:from:amazon subject:deliver" },
        { user: admin, listener: "email:from:blah subject:deliver" },
        { user: admin, listener: "subject:deliver" },
        { user: admin, listener: "email:body:\"awesome socks\"" },
        { user: admin, listener: "tell:/(?<direction>open|close|toggle)( (?:the|my))? garage/" },
        { user: admin, listener: "tell:/Set the house( to)? (?<temp>\\d+)( degrees?) ?(this|that|other) ?(this|matters)?.*?/" },
        { user: admin, listener: "tell:\"Do the things\"" },
        { user: admin, listener: "tell:~/^Checkup$/" },
        { user: admin, listener: "tell:ANY(~/^Checkup$/ ~/^Result$/)" },
        { user: admin, listener: "event:/food|drink|snack|treat|alcohol/ note:/(?<text>.*?)(((?<cals>\d+) ?cals?))?/" },
        { user: admin, listener: "event:note:/(?<text>.*?)(((?<cals>\d+) ?cals?))?/" },
        { user: admin, listener: "event:/food|drink|snack|treat|alcohol/" },
        { user: admin, listener: "tell:OR(/is the garage (open|closed)/ /check garage/)" },
        { user: admin, listener: "shortcut:data" },
        { user: admin, listener: "shortcut" },
      ])
    end

    it "executes the correct values" do
      expect_trigger_listeners(admin, :webhook, { travel: "home" }, [])
      expect_trigger_listeners(admin, :tell, "Do things", [])
      expect_trigger_listeners(admin, :tell, "Do the", [])
      expect_trigger_listeners(admin, :tell, "add checkup", [])
      expect_trigger_listeners(admin, :tell, "checkup do", [])
      expect_trigger_listeners(admin, :tell, "Set the house 72 degrees", [])
      expect_trigger_listeners(admin, :tell, "is the garage open", [
        "tell:OR(/is the garage (open|closed)/ /check garage/)",
      ])
      expect_trigger_listeners(admin, :tell, "check garage", [
        "tell:OR(/is the garage (open|closed)/ /check garage/)",
      ])
      expect_trigger_listeners(other_user, :travel, { action: "Arrive", location: "Home" }, [
        "travel",
      ])
      expect_trigger_listeners(admin, :shortcut, { shortcut: { data: { something: {} } } }, [
        "shortcut",
        "shortcut:data",
      ])
      expect_trigger_listeners(admin, :shortcut, { shortcut: { data: { something: [] } } }, [
        "shortcut",
        "shortcut:data",
      ])
      expect_trigger_listeners(admin, :shortcut, { shortcut: [{ data: nil }] }, [
        "shortcut",
        "shortcut:data",
      ])
      expect_trigger_listeners(admin, :travel, { whatever: "home" }, [
        "travel",
        "travel:home",
      ])
      expect_trigger_listeners(admin, :travel, { action: "Arrive", location: "Delton", arrived: "Delton" }, [
        "travel",
        "travel:arrive",
        "travel:arrive:!home",
      ])
      expect_trigger_listeners(admin, :travel, { action: :depart, location: "Delton" }, [
        "travel",
        "travel:depart",
      ])
      expect_trigger_listeners(admin, :travel, { location: "Home", action: "departed", departed: "Home" }, [
        "travel",
        "travel:depart",
        "travel:depart:home",
        "travel:home",
      ])
      expect_trigger_listeners(admin, :travel, { arrived: "Home" }, [
        "travel",
        "travel:arrive",
        "travel:arrive:home",
        "travel:home",
        # "travel:arrive:!home", # -- This should NOT be present!
      ])
      expect_trigger_listeners(admin, :event, { name: "drink" }, [
        "event:/food|drink|snack|treat|alcohol/",
        "event:name:ANY(food soda drink alcohol treat snack)",
      ])
      expect_trigger_listeners(admin, :event, { name: "drink", notes: "Fireball" }, [
        "event:/food|drink|snack|treat|alcohol/",
        "event:name:ANY(food soda drink alcohol treat snack)",
        "event:note:/(?<text>.*?)(((?<cals>d+) ?cals?))?/",
      ])
      expect_trigger_listeners(admin, :event, { name: "Wordle", notes: "food" }, [
        "event:/food|drink|snack|treat|alcohol/",
        "event:note:/(?<text>.*?)(((?<cals>d+) ?cals?))?/",
      ])
      expect_trigger_listeners(admin, :event, { name: "soda" }, [
        "event:name:ANY(food soda drink alcohol treat snack)",
      ])
      expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item has been Delivered!", text_body: "We delivered your Awesome Socks today!" }, [
        "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
        "email:from:amazon subject:deliver",
        "email:body:\"awesome socks\"",
      ])
      expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item is now arriving tomorrow" }, [
        "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      ])
      expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item has been lost" }, [
        "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      ])
      expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item is delayed" }, [
        "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      ])
      expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item has been Delivered!", text_body: "We delivered your Awesome Pants today!" }, [
        "email:from:amazon subject:deliver",
        "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      ])
      expect_trigger_listeners(admin, :tell, "Open the garage", [
        "tell:/(?<direction>open|close|toggle)( (?:the|my))? garage/",
      ])
      expect_trigger_listeners(admin, :tell, "Set the house 72 degrees this matters more", [
        "tell:/Set the house( to)? (?<temp>\\d+)( degrees?) ?(this|that|other) ?(this|matters)?.*?/",
      ])
      expect_trigger_listeners(admin, :tell, "Do the things", [
        "tell:\"Do the things\"",
      ])
      expect_trigger_listeners(admin, :tell, "Do the things twice", [
        "tell:\"Do the things\"",
      ])
      expect_trigger_listeners(admin, :tell, " checkup  ", [
        "tell:~/^Checkup$/",
        "tell:ANY(~/^Checkup$/ ~/^Result$/)",
      ])
      expect_trigger_listeners(admin, :tell, "result", [
        "tell:ANY(~/^Checkup$/ ~/^Result$/)",
      ])
    end
  end

  context "with a multi-field sensor listener" do
    let(:listener) { "hass-sensor:location:doorbell type:rang rang:true" }
    let(:payload) {
      {
        device_name: "Doorbell",
        entity_id:   "binary_sensor.doorbell_visitor",
        type:        "rang",
        subject:     "visitor",
        rang:        true,
        location:    "doorbell",
      }
    }

    before { @tasks = Task.create([{ user: admin, listener: listener }]) }

    it "matches only when every field, boolean included, matches" do
      expect_trigger_listeners(admin, :"hass-sensor", payload, [listener])
      expect_trigger_listeners(admin, :"hass-sensor", payload.merge(rang: false), [])
      expect_trigger_listeners(admin, :"hass-sensor", payload.merge(location: "garage"), [])
      expect_trigger_listeners(admin, :"hass-sensor", payload.merge(type: "motion"), [])
    end
  end

  context "Tokenizing::TriggerData.parse" do
    it "strips surrounding quotes from colon-separated values" do
      result = Tokenizing::TriggerData.parse('person:chelsea:"-15.20"')
      expect(result).to eq({ person: { chelsea: "-15.20" } })
    end

    it "parses space-separated key:\"value\" pairs as a flat hash" do
      result = Tokenizing::TriggerData.parse('name:"Refill Item" notes:"Ice Water"')
      expect(result).to eq({ name: "Refill Item", notes: "Ice Water" })
    end

    it "parses unquoted space-separated key:value pairs" do
      result = Tokenizing::TriggerData.parse("a:b c:d")
      expect(result).to eq({ a: "b", c: "d" })
    end

    it "leaves single-chain colon syntax intact when there are no top-level spaces" do
      expect(Tokenizing::TriggerData.parse("a:b:c")).to eq({ a: { b: "c" } })
    end

    it "does NOT split words that aren't key:value pairs" do
      expect(Tokenizing::TriggerData.parse("chelsea withdraw 180")).to eq({ data: "chelsea withdraw 180" })
      expect(Tokenizing::TriggerData.parse('command:Remind me to "x"')).to eq({ command: 'Remind me to "x"' })
    end

    it "passes through hashes untouched" do
      expect(Tokenizing::TriggerData.parse({ name: "x", notes: "y" })).to eq({ name: "x", notes: "y" })
    end
  end

  context "with hyphenated trigger keys" do
    let!(:tasks) {
      Task.create([
        { user: admin, listener: "hass-button" },
        { user: admin, listener: 'hass-button:entity_id:"sensor.shortcut_button_1"' },
        { user: admin, listener: "hass-button:type:long_press" },
      ])
    }

    let(:trigger) { "hass-button" }
    let(:trigger_data) {
      {
        button_id:   "8f78df4c09395edf6060cae7c22df356",
        type:        "button1_long_press",
        entity_id:   "sensor.shortcut_button_1",
        device_name: "Action Button 1",
      }
    }

    def matching_listeners(trigger, data)
      serialized = Tokenizing::TriggerData.serialize(data, use_global_id: false)
      admin.tasks.by_listener(trigger).select { |task|
        task.listener_match?(trigger) { |sub|
          next true if sub == trigger

          Tokenizing::Matcher.new(sub, { trigger => serialized }).match?
        }
      }.map(&:listener)
    end

    it "finds the tasks by the hyphenated key and matches the applicable listeners" do
      expect(admin.tasks.by_listener(trigger).pluck(:listener)).to match_array(tasks.map(&:listener))
      expect(matching_listeners(trigger, trigger_data)).to contain_exactly("hass-button", 'hass-button:entity_id:"sensor.shortcut_button_1"', "hass-button:type:long_press")

      other_data = trigger_data.merge(entity_id: "sensor.shortcut_button_2", type: "button2_short_press")
      expect(matching_listeners(trigger, other_data)).to contain_exactly("hass-button")
    end
  end

  context "with regex named captures" do
    let(:log_listener) { 'tell:/^log(?: log)?(?:\s+(?<title>\w+)(?:-)?)(?:\s+(?<notes>.*?))?(?:\s+\((?<calories>(\d+))\))?(?:\s+\{(?<data>.*?)\})?$/' }

    def match_with_captures(listener, trigger, data)
      serialized = Tokenizing::TriggerData.serialize(Tokenizing::TriggerData.parse(data, as: admin), use_global_id: false)
      matcher = Tokenizing::Matcher.new(listener, { trigger => serialized })
      [matcher.match?, matcher.match_data[:named_captures]]
    end

    it "exposes the regex's named captures" do
      [
        [log_listener, "log drink Mtn dew",       { title: "drink", notes: "Mtn dew" }],
        [log_listener, "log drink Mtn dew (170)", { title: "drink", notes: "Mtn dew", calories: "170" }],
        [log_listener, "log food",                { title: "food", notes: nil }],
        ["tell:/(?<direction>open|close|toggle)( (?:the|my))? garage/", "Open the garage", { direction: "Open" }],
      ].each { |listener, words, expected|
        matched, captures = match_with_captures(listener, :tell, words)
        expect(matched).to be(true), words
        expected.each { |key, value| expect(captures[key].presence).to eq(value), "#{words} #{key}" }
      }
    end
  end
end
