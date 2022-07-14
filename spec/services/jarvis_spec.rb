RSpec.describe Jarvis do
  include ActiveJob::TestHelper

  def jarvis(msg, user=@user)
    res = Jarvis.command(user, msg)
    res.is_a?(Array) ? res[0] : res
  end

  before do
    Timecop.freeze(Time.local(2022, 6, 24, 5, 45))
  end

  after do
    Timecop.return
  end

  before(:context) do
    @admin = User.find_or_create_by!(username: :rocco, role: :admin) { |u|
      u.password = :password
      u.password_confirmation = :password
    }
    @default_list = @admin.lists.find_or_create_by(name: "TODO")
    @other_list = @admin.lists.find_or_create_by(name: "Home Depot")
    @user = @admin
  end

  context "as non-admin" do
    before { @user = User.new(role: :guest) }
    # disallow: fn, car, log
    # allows: list

    it "does not allow many functions" do
      expect(jarvis("Start the car")).to eq("Sorry, you can't do that.")
    end
  end

  context "with regular words as admin" do
    it "responds" do
      expect(jarvis("Do my homework")).to eq("I don't know how to do your homework, sir.")
      expect(Jarvis::Text::IM_HERE_QUESTION_RESPONSES.map { |r| Jarvis::Text.decorate(r) }).to include(jarvis("You there?"))
    end
  end

  context "with lists" do
    it "can add items to a list with elaborate text" do
      expect(jarvis("add miter saw to my home depot list")).to eq("Home Depot:\n - miter saw")
      expect(@other_list.list_items.pluck(:name)).to include("miter saw")
    end
    specify { expect(jarvis("add miter saw to home depot")).to eq("Home Depot:\n - miter saw") }
    specify { expect(jarvis("add miter saw home depot")).to eq("Home Depot:\n - miter saw") }

    it "can retrieve lists" do
      @other_list.list_items.create(name: "Hammer")

      expect(jarvis("home depot")).to eq("Home Depot:\n - Hammer")
    end

    it "can retrieve lists with a question" do
      @other_list.list_items.create(name: "Hammer")

      expect(jarvis("What's on my Home Depot list?")).to eq("Home Depot:\n - Hammer")
    end

    it "can remove items from a list" do
      @other_list.list_items.create(name: "Hammer")

      expect(jarvis("remove hammer from home depot")).to eq("Home Depot:\n<No items>")
    end

    it "can add (multiple) items to the default list" do
      expect(jarvis("add salt and baking powder")).to eq("TODO:\n - baking powder\n - salt")
    end

    it "can add a list of items to the default list" do
      expect(jarvis("add salt, baking powder, and eggs to my list")).to eq("TODO:\n - eggs\n - baking powder\n - salt")
    end
  end

  context "with car" do
    # turn the ac|heater on in my car|at home
    let(:tesla_control) { double("TeslaControl", vehicle_id: 1, vehicle_data: {}) }

    before do
      allow(DataStorage).to receive(:[]).with(any_args).and_return("unimportant")
      allow(TeslaControl).to receive(:new).and_return(tesla_control)
    end

    actions = {
      start_car: {
        res: "Starting car",
        opts: [
          "start climate",
          "start the car",
          "start my car",
          "turn my car on",
          "car on",
        ]
      },
      off_car: {
        res: "Stopping car",
        opts: [
          "stop the car",
          "turn my car off",
          "car off",
        ]
      },
      honk: {
        res: "Honking the horn",
        opts: [
          "honk the horn",
          "honk horn",
          "honk",
          "horn",
        ]
      },
      defrost: {
        others: [:start_car, [:set_temp, 82], :heat_driver, :heat_passenger],
        res: "Defrosting the car",
        opts: [
          "defrost my car",
          "defrost",
        ]
      },
      doors: {
        res: "Unlocking car doors",
        opts: [
          "unlock my car",
          "unlock my car doors",
          "unlock doors",
        ]
      },
      windows: {
        res: "Opening car windows",
        opts: [
          "vent",
          "vent car",
          "open my car windows",
          "open windows",
        ]
      },
      pop_boot: {
        res: "Popping the boot",
        opts: [
          "boot",
          "pop boot",
          "pop trunk",
          "Open the car trunk!",
        ]
      },
      pop_frunk: {
        res: "Opening frunk",
        opts: [
          "frunk",
          "pop frunk",
          "open the car frunk",
        ]
      },
      set_temp: {
        others: [:start_car, [:set_temp, 71]],
        res: "Car temp set to 71",
        opts: [
          "car 71",
          "car temp 71",
          "set car temp 71",
        ]
      },
      heat: {
        skip: true,
        others: [:start_car, [:set_temp, 82], :heat_driver, :heat_passenger, :defrost],
        res: "Defrosting the car",
        opts: [
          "warm my car",
          "Heat my car",
          "car heat",
        ]
      },
      cool: {
        skip: true,
        others: [:start_car, [:set_temp, 59]],
        res: "Car temp set to 59",
        opts: [
          "cool my car",
          "car cool",
        ]
      },
    }

    actions.each do |action, data|
      data[:opts].each do |opt|
        it "can #{opt}" do
          data[:others]&.each do |k, args|
            expect(tesla_control).to receive(k).with(args) if args
            expect(tesla_control).to receive(k) unless args
          end
          unless data[:others]&.any? { |o| o.is_a?(Array) ? o[0] == action : o == action }
            expect(tesla_control).to receive(action) unless data[:skip]
          end
          expect(jarvis(opt)).to eq(data[:res])
        end
      end
    end
  end

  context "with home" do
    let(:home_control) { double("GoogleNestControl") }
    let(:upstairs) { { key: "", name: "Upstairs" } }
    let(:entryway) { { key: "", name: "Entryway" } }
    let(:devices) { { "Upstairs": upstairs, "Entryway": entryway } }

    before do
      allow(DataStorage).to receive(:[]).with(any_args).and_return("unimportant")
      allow(DataStorage).to receive(:[]).with(:nest_devices).and_return(devices)
      allow(GoogleNestControl).to receive(:new).and_return(home_control)
      allow(home_control).to receive(:devices) do
        devices.map { |device_name, device_data|
          GoogleNestDevice.new(home_control).set_all(device_data)
        }
      end
    end

    actions = {
      "turn the upstairs heat to 69" => {
        res: "Set house upstairs heat to 69°.",
        actions: [:set_mode, :set_temp],
      },
      "set upstairs 69" => {
        res: "Set house upstairs to 69°.",
        actions: [:set_temp],
      },
      "upstairs to heat" => {
        res: "Set house upstairs to heat.",
        actions: [:set_mode],
      },
      "cool upstairs" => {
        res: "Set house upstairs to cool.",
        actions: [:set_mode],
      },
      "cool house" => {
        res: "Set house entryway to cool.",
        actions: [:set_mode],
      },
      "set ac to 69" => {
        res: "Set house entryway AC to 69°.",
        actions: [:set_mode, :set_temp],
      },
    }

    actions.each do |action, data|
      it "can #{action}" do
        data[:actions]&.each do |k, args|
          expect(home_control).to receive(k)
        end

        expect(jarvis(action)).to eq(data[:res])
      end
    end
  end

  context "with garage" do
    before do
      allow(DataStorage).to receive(:[]).with(any_args).and_return("unimportant")
    end

    actions = {
      "open my garage"   => "Opening the garage",
      "Open the garage"  => "Opening the garage",
      "open garage"      => "Opening the garage",
      "garage open"      => "Opening the garage",

      "garage"           => "Toggling the garage",
      "garage toggle"    => "Toggling the garage",

      "close my garage"  => "Closing the garage",
      "Close the garage" => "Closing the garage",
      "close garage"     => "Closing the garage",
      "garage close"     => "Closing the garage",
    }

    actions.each do |action, res|
      it "can #{action}" do
        expect(jarvis(action)).to eq(res)
      end
    end
  end

  context "with texts" do
    actions = {
      "Send me a text saying go running" => "Go running",
      "Message me hype train" => "Hype train",
      "Send me a msg that says time to go shopping" => "Time to go shopping",
      "Text me go do something" => "Go do something",
      "Text me" => "You asked me to text you, sir.",
    }

    actions.each do |action, msg|
      it "can #{action}" do
        expect(SmsWorker).to receive(:perform_async).with("3852599640", msg)
        expect(jarvis(action)).to eq("Sending you a text saying: #{msg}")
      end
    end
  end

  context "with action events" do
    it "can add action events" do
      expect(jarvis("log thing")).to eq("Logged Thing")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
    end

    it "can add action events with note" do
      expect(jarvis("log thing sup")).to eq("Logged Thing (sup)")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:notes)).to include("sup")
    end

    it "can add action events with time" do
      expect(jarvis("Log thing at 7:52")).to eq("Logged Thing [Today 7:52 AM]")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 7, 52))
    end

    it "can add action events with relative time" do
      expect(jarvis("Log thing 10 minutes ago.")).to eq("Logged Thing [Today 5:35 AM]")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 5, 35))
    end

    it "can add action events with note and time" do
      expect(jarvis("log thing sup at 7:52.")).to eq("Logged Thing (sup) [Today 7:52 AM]")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:notes)).to include("sup")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 7, 52))
    end
  end

  context "with commands" do
    # Verify passing arguments works as expected
    let!(:command) { ::CommandProposal::Task.create(name: "Lumber Spacer", session_type: :function) }

    before do
      command.update(code: "print 'Lumber output!'")
      command.current_iteration.update(status: :approved)
    end

    it "can run a function" do
      perform_enqueued_jobs {
        expect(jarvis("run lumber spacer")).to eq("Lumber output!")
      }
    end
  end

  context "with scheduling" do
    # now Time.local(2022, 6, 24, 5, 45)
    it "can schedule a job for later" do
      expect(JarvisWorker).to receive(:perform_at).with(10.minutes.from_now, @admin.id, "add something to list")
      expect(jarvis("add something to list in 10 minutes")).to eq("I'll add something to list on Fri Jun 24, 5:55 AM")
    end

    it "can schedule a job for a time" do
      expect(JarvisWorker).to receive(:perform_at).with(Time.local(2022, 6, 24, 21, 45), @admin.id, "add something to list")
      expect(jarvis("add something to list at 9:45 PM")).to eq("I'll add something to list on Fri Jun 24, 9:45 PM")
    end

    it "can understand time names" do
      msg = "Do the laundry"
      perform_enqueued_jobs {
        expect(JarvisWorker).to receive(:perform_at).with(Time.local(2022, 6, 25, 11, 15), @admin.id, "Remind me saying #{msg}").and_call_original
        # Call original above to make sure the SmsWorker gets called
        expect(SmsWorker).to receive(:perform_async).with("3852599640", msg)

        expect(jarvis("Remind me at 11:15 AM tomorrow saying #{msg}")).to eq("I'll remind you saying #{msg} on Sat Jun 25, 11:15 AM")
      }
    end

    it "can schedule a job in the middle of a command" do
      msg = "Do the laundry"
      perform_enqueued_jobs {
        expect(JarvisWorker).to receive(:perform_at).with(5.minutes.from_now, @admin.id, "Message me saying do the laundry").and_call_original
        # Call original above to make sure the SmsWorker gets called
        expect(SmsWorker).to receive(:perform_async).with("3852599640", msg)

        expect(jarvis("Message me in 5 minutes saying do the laundry")).to eq("I'll message you saying do the laundry on Fri Jun 24, 5:50 AM")
      }
    end
  end
end
