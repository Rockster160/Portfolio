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
    trigger_data_parsed = TriggerData.parse(trigger_data, as: user)
    serialized = TriggerData.serialize(trigger_data_parsed, use_global_id: false)

    @tasks.select { |task|
      next false unless task.user_id == user.id

      did_match = task.listener_match?(trigger) { |sub_listener|
        next true if sub_listener == trigger.to_s

        if trigger == :monitor && trigger_data_parsed.is_a?(::Hash) && trigger_data_parsed[:channel].present?
          next true if sub_listener.match?(/\A\s*monitor::?#{Regexp.escape(trigger_data_parsed[:channel].to_s)}\s*\z/)
        end

        ::SearchBreakMatcher.new(sub_listener, { trigger => serialized }).match?
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

  context "TriggerData.parse" do
    it "strips surrounding quotes from colon-separated values" do
      result = TriggerData.parse('person:chelsea:"-15.20"')
      expect(result).to eq({ person: { chelsea: "-15.20" } })
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
      serialized = TriggerData.serialize(data, use_global_id: false)
      admin.tasks.by_listener(trigger).select { |task|
        task.listener_match?(trigger) { |sub|
          next true if sub == trigger

          SearchBreakMatcher.new(sub, { trigger => serialized }).match?
        }
      }.map(&:listener)
    end

    it "finds tasks via by_listener scope" do
      found = admin.tasks.by_listener(trigger)
      expect(found.pluck(:listener)).to match_array(tasks.map(&:listener))
    end

    it "matches all applicable listeners for button 1" do
      expect(matching_listeners(trigger, trigger_data)).to contain_exactly("hass-button", 'hass-button:entity_id:"sensor.shortcut_button_1"', "hass-button:type:long_press")
    end

    it "only matches the bare listener for a different button" do
      other_data = trigger_data.merge(
        entity_id: "sensor.shortcut_button_2",
        type:      "button2_short_press",
      )
      expect(matching_listeners(trigger, other_data)).to contain_exactly("hass-button")
    end
  end

  context "with regex named captures" do
    let(:log_listener) { 'tell:/^log(?: log)?(?:\s+(?<title>\w+)(?:-)?)(?:\s+(?<notes>.*?))?(?:\s+\((?<calories>(\d+))\))?(?:\s+\{(?<data>.*?)\})?$/' }

    def match_with_captures(listener, trigger, data)
      serialized = TriggerData.serialize(TriggerData.parse(data, as: admin), use_global_id: false)
      matcher = SearchBreakMatcher.new(listener, { trigger => serialized })
      [matcher.match?, matcher.regex_match_data[:named_captures]]
    end

    it "captures notes from 'log drink Mtn dew'" do
      matched, captures = match_with_captures(log_listener, :tell, "log drink Mtn dew")
      expect(matched).to be true
      expect(captures[:title]).to eq("drink")
      expect(captures[:notes]).to eq("Mtn dew")
    end

    it "captures notes and calories from 'log drink Mtn dew (170)'" do
      matched, captures = match_with_captures(log_listener, :tell, "log drink Mtn dew (170)")
      expect(matched).to be true
      expect(captures[:title]).to eq("drink")
      expect(captures[:notes]).to eq("Mtn dew")
      expect(captures[:calories]).to eq("170")
    end

    it "captures title only from 'log food'" do
      matched, captures = match_with_captures(log_listener, :tell, "log food")
      expect(matched).to be true
      expect(captures[:title]).to eq("food")
      expect(captures[:notes]).to be_blank
    end

    it "captures garage direction" do
      listener = "tell:/(?<direction>open|close|toggle)( (?:the|my))? garage/"
      matched, captures = match_with_captures(listener, :tell, "Open the garage")
      expect(matched).to be true
      expect(captures[:direction]).to eq("Open")
    end

    context "travel command regex" do
      let(:travel_listener) { 'tell:OR(/^(?<preamble>.+?) (?:when|after|once|(?:the )?next time) (?:I )?(?<direction>get|go|arrive|leave|depart|come|head)(?: (?:to|at))? (?<destination>(?!back\b)\S+?)(?:\'s)? to (?<suffix>.+)$/ /^(?<command>.+?) (?:when|after|once|(?:the )?next time) (?:I )?(?<direction>get|go|arrive|leave|depart|come|head)(?: (?:to|at))? (?<destination>.+?)(?:\'s)?$/)' }

      it "parses 'remind me to clean the house when I get home'" do
        matched, captures = match_with_captures(travel_listener, :tell, "remind me to clean the house when I get home")
        expect(matched).to be true
        expect(captures[:command]).to eq("remind me to clean the house")
        expect(captures[:direction]).to eq("get")
        expect(captures[:destination]).to eq("home")
      end

      it "parses 'remind me when I get to Doug's to grab the Dehydrator'" do
        matched, captures = match_with_captures(travel_listener, :tell, "remind me when I get to Doug's to grab the Dehydrator")
        expect(matched).to be true
        expect(captures[:preamble]).to eq("remind me")
        expect(captures[:direction]).to eq("get")
        expect(captures[:destination]).to eq("Doug")
        expect(captures[:suffix]).to eq("grab the Dehydrator")
      end

      it "parses 'remind me to record climbs when I get to Momentum'" do
        matched, captures = match_with_captures(travel_listener, :tell, "remind me to record climbs when I get to Momentum")
        expect(matched).to be true
        expect(captures[:command]).to eq("remind me to record climbs")
        expect(captures[:direction]).to eq("get")
        expect(captures[:destination]).to eq("Momentum")
      end

      it "parses 'ping me not done when I arrive home'" do
        matched, captures = match_with_captures(travel_listener, :tell, "ping me not done when I arrive home")
        expect(matched).to be true
        expect(captures[:command]).to eq("ping me not done")
        expect(captures[:direction]).to eq("arrive")
        expect(captures[:destination]).to eq("home")
      end

      it "parses 'add dehydrator to list when I get to Doug's'" do
        matched, captures = match_with_captures(travel_listener, :tell, "add dehydrator to list when I get to Doug's")
        expect(matched).to be true
        expect(captures[:command]).to eq("add dehydrator to list")
        expect(captures[:direction]).to eq("get")
        expect(captures[:destination]).to eq("Doug")
      end

      it "parses 'remind me to X next time I go to the store'" do
        matched, captures = match_with_captures(travel_listener, :tell, "remind me to X next time I go to the store")
        expect(matched).to be true
        expect(captures[:command]).to eq("remind me to X")
        expect(captures[:direction]).to eq("go")
        expect(captures[:destination]).to eq("the store")
      end

      it "parses departure commands with 'leave'" do
        matched, captures = match_with_captures(travel_listener, :tell, "close the garage when I leave home")
        expect(matched).to be true
        expect(captures[:command]).to eq("close the garage")
        expect(captures[:direction]).to eq("leave")
        expect(captures[:destination]).to eq("home")
      end

      it "parses departure commands with 'depart'" do
        matched, captures = match_with_captures(travel_listener, :tell, "ping me when I depart work")
        expect(matched).to be true
        expect(captures[:command]).to eq("ping me")
        expect(captures[:direction]).to eq("depart")
        expect(captures[:destination]).to eq("work")
      end

      it "parses 'get back' as destination 'back'" do
        matched, captures = match_with_captures(travel_listener, :tell, "remind me to check mail when I get back")
        expect(matched).to be true
        expect(captures[:command]).to eq("remind me to check mail")
        expect(captures[:direction]).to eq("get")
        expect(captures[:destination]).to eq("back")
      end

      it "parses 'get back to' with a destination (raw capture includes 'back to')" do
        matched, captures = match_with_captures(travel_listener, :tell, "remind me to call mom when I get back to the office")
        expect(matched).to be true
        expect(captures[:command]).to eq("remind me to call mom")
        expect(captures[:direction]).to eq("get")
        # Raw capture includes "back to" -  Jil code strips "back to " prefix
        expect(captures[:destination]).to eq("back to the office")
      end

      it "parses 'after I arrive at' commands" do
        matched, captures = match_with_captures(travel_listener, :tell, "start workout after I arrive at Momentum")
        expect(matched).to be true
        expect(captures[:command]).to eq("start workout")
        expect(captures[:direction]).to eq("arrive")
        expect(captures[:destination]).to eq("Momentum")
      end

      it "does not match normal commands without a travel phrase" do
        matched, _captures = match_with_captures(travel_listener, :tell, "remind me to get milk")
        expect(matched).to be false
      end

      it "does not match without a destination" do
        matched, _captures = match_with_captures(travel_listener, :tell, "remind me when I arrive")
        expect(matched).to be false
      end
    end
  end
end
