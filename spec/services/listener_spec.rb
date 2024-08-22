RSpec.describe JarvisTask do
  include ActiveJob::TestHelper

  let(:admin) {
    User.find_or_create_by!(username: :rocco, role: :admin) { |u|
      u.password = :password
      u.password_confirmation = :password
    }
  }
  let(:other_user) {
    User.find_or_create_by!(username: :luffy) { |u|
      u.password = :password
      u.password_confirmation = :password
    }
  }

  def expect_trigger_listeners(user, trigger, trigger_data, expected_listeners)
    @listeners = []
    Jarvis.trigger_events(user, trigger, trigger_data)
    expect(@listeners).to match_array(expected_listeners)
  end

  context "with basic triggers" do
    before do
      JarvisTask.create([
        # { user: other_user, listener: "travel" },
        # { user: admin, listener: "travel" },
        # { user: admin, listener: "travel:depart:home" },
        # { user: admin, listener: "travel:depart" },
        # { user: admin, listener: "travel:arrive" },
        # { user: admin, listener: "travel:arrive:home" },
        # { user: admin, listener: "travel:home" },
        # { user: admin, listener: "travel:arrive:!home" },
        # { user: admin, listener: "event:name:ANY(food soda drink alcohol treat snack)" },
        # { user: admin, listener: "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)" },
        # { user: admin, listener: "email:from:amazon subject:deliver" },
        # { user: admin, listener: "email:from:blah subject:deliver" },
        # { user: admin, listener: "subject:deliver" },
        # { user: admin, listener: "email:body:\"awesome socks\"" },
        # { user: admin, listener: "tell~/(?<direction>open|close|toggle)( (?:the|my))? garage/" },
        # { user: admin, listener: "tell~/Set the house( to)? (?<temp>\\d+)( degrees?) ?(this|that|other) ?(this|matters)?.*?/" },
        # { user: admin, listener: "tell:\"Do the things\"" },
        # { user: admin, listener: "tell:~/Checkup/" },
        # { user: admin, listener: "tell:ANY(~/Checkup/ ~/Result/)" },
        { user: admin, listener: "event:/food|drink|snack|treat|alcohol/ note:/(?<text>.*?)(\((?<cals>\d+) ?cals?\))?/" },
      ])

      @listeners = []
      allow_any_instance_of(JarvisTask).to receive(:execute) do |jarvis_task, data|
        @listeners << jarvis_task.listener
      end
    end

    it "executes the correct values" do
      # expect_trigger_listeners(admin, :webhook, { travel: "home" }, [])
      # expect_trigger_listeners(admin, :tell, "Do things", [])
      # expect_trigger_listeners(admin, :tell, "Do the", [])
      # expect_trigger_listeners(admin, :tell, "add checkup", [])
      # expect_trigger_listeners(admin, :tell, "checkup do", [])
      # expect_trigger_listeners(admin, :tell, "Set the house 72 degrees", [])
      #
      # expect_trigger_listeners(other_user, :travel, { action: "Arrive", location: "Home" }, [
      #   "travel",
      # ])
      # expect_trigger_listeners(admin, :travel, { whatever: "home" }, [
      #   "travel",
      #   "travel:home",
      # ])
      # expect_trigger_listeners(admin, :travel, { action: "Arrive", location: "Delton", arrived: "Delton" }, [
      #   "travel",
      #   "travel:arrive",
      #   "travel:arrive:!home",
      # ])
      # expect_trigger_listeners(admin, :travel, { action: :depart, location: "Delton" }, [
      #   "travel",
      #   "travel:depart",
      # ])
      # expect_trigger_listeners(admin, :travel, { location: "Home", action: "departed", departed: "Home" }, [
      #   "travel",
      #   "travel:depart",
      #   "travel:depart:home",
      #   "travel:home",
      # ])
      # expect_trigger_listeners(admin, :travel, { arrived: "Home" }, [
      #   "travel",
      #   "travel:arrive",
      #   "travel:arrive:home",
      #   "travel:home",
      #   # "travel:arrive:!home", # -- This should NOT be here!
      # ])
      # expect_trigger_listeners(admin, :event, { name: "drink" }, [
      #   "event:name:ANY(food soda drink alcohol treat snack)"
      # ])
      expect_trigger_listeners(admin, :event, { name: "drink", notes: "Fireball" }, [
        "event:name:ANY(food soda drink alcohol treat snack)"
      ])
      # expect_trigger_listeners(admin, :event, { name: "Wordle", notes: "food" }, [
      # ])
      # expect_trigger_listeners(admin, :event, { name: "soda" }, [
      #   "event:name:ANY(food soda drink alcohol treat snack)"
      # ])
      # expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item has been Delivered!", text_body: "We delivered your Awesome Socks today!" }, [
      #   "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      #   "email:from:amazon subject:deliver",
      #   "email:body:\"awesome socks\"",
      # ])
      # expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item is now arriving tomorrow" }, [
      #   "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      # ])
      # expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item has been lost" }, [
      #   "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      # ])
      # expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item is delayed" }, [
      #   "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      # ])
      # expect_trigger_listeners(admin, :email, { from: "shipping@amazon.com", to: "rocco@ardesian.com", subject: "Your item has been Delivered!", text_body: "We delivered your Awesome Pants today!" }, [
      #   "email:from:amazon subject:deliver",
      #   "email:from:amazon subject:ANY(\"has been\" \"is now\" delayed)",
      # ])
      # expect_trigger_listeners(admin, :tell, "Open the garage", [
      #   "tell~/(?<direction>open|close|toggle)( (?:the|my))? garage/",
      # ])
      # expect_trigger_listeners(admin, :tell, "Set the house 72 degrees this matters more", [
      #   "tell~/Set the house( to)? (?<temp>\\d+)( degrees?) ?(this|that|other) ?(this|matters)?.*?/",
      # ])
      # expect_trigger_listeners(admin, :tell, "Do the things", [
      #   "tell:\"Do the things\""
      # ])
      # expect_trigger_listeners(admin, :tell, "Do the things twice", [
      #   "tell:\"Do the things\"",
      # ])
      # expect_trigger_listeners(admin, :tell, "checkup", [
      #   "tell:~/Checkup/",
      #   "tell:ANY(~/Checkup/ ~/Result/)",
      # ])
      # expect_trigger_listeners(admin, :tell, "result", [
      #   "tell:ANY(~/Checkup/ ~/Result/)",
      # ])
    end
  end
end
