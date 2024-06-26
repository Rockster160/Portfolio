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

  context "with basic trigger" do
    before do
      JarvisTask.create(user: other_user, listener: "travel")
      JarvisTask.create(user: admin, listener: "travel")
      JarvisTask.create(user: admin, listener: "travel:depart:home")
      JarvisTask.create(user: admin, listener: "travel:depart")
      JarvisTask.create(user: admin, listener: "travel:arrive")
      JarvisTask.create(user: admin, listener: "travel:arrive:home")
      JarvisTask.create(user: admin, listener: "travel:home")
      JarvisTask.create(user: admin, listener: "travel:arrive:!home")
      JarvisTask.create(user: admin, listener: "event:name:ANY(food soda drink alcohol treat snack)")

      @listeners = []
      allow_any_instance_of(JarvisTask).to receive(:execute) do |jarvis_task, data|
        @listeners << jarvis_task.listener
      end
    end

    it "executes the correct values" do
      expect_trigger_listeners(other_user, :travel, { action: "Arrive", location: "Home" }, [
        "travel",
      ])
      expect_trigger_listeners(admin, :webhook, { travel: "home" }, [
      ])
      expect_trigger_listeners(admin, :travel, { whatever: "home" }, [
        "travel",
        "travel:home",
      ])
      expect_trigger_listeners(admin, :travel, { action: "Arrive", location: "Delton" }, [
        "travel",
        "travel:arrive",
        "travel:arrive:!home",
      ])
      expect_trigger_listeners(admin, :travel, { action: :depart, location: "Delton" }, [
        "travel",
        "travel:depart",
      ])
      expect_trigger_listeners(admin, :travel, { arrived: "Home" }, [
        "travel",
        "travel:arrive",
        "travel:arrive:home",
        "travel:home",
      ])
      expect_trigger_listeners(admin, :event, { name: "drink" }, [
        "event:name:ANY(food soda drink alcohol treat snack)"
      ])
      expect_trigger_listeners(admin, :event, { name: "Wordle", notes: "food" }, [
      ])
      expect_trigger_listeners(admin, :event, { name: "soda" }, [
        "event:name:ANY(food soda drink alcohol treat snack)"
      ])
    end
  end
end
