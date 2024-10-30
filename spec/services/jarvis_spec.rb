RSpec.describe Jarvis do
  include ActiveJob::TestHelper

  def jarvis(msg, user=@user)
    res = Jarvis.command(user, msg)
    Array.wrap(res)[0]
  end

  before do
    Time.zone = User.timezone
    Timecop.freeze(Time.local(2022, 6, 24, 5, 45))
  end

  after do
    Timecop.return
  end

  before(:context) do
    @admin = User.me
    @admin.contacts.create(JSON.parse(File.read("address_book.json"), symbolize_names: true))
    contact_id = @admin.contacts.find_by(name: "Brendan").id
    mom_id = @admin.contacts.find_by(name: "Mom").id
    @admin.caches.dig_set(:oauth, :venmo_api, :contact_ids, contact_id.to_s, "brendanvenmoid")
    @admin.caches.dig_set(:oauth, :venmo_api, :contact_ids, mom_id.to_s, "momvenmoid")
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

    it "says hi" do
      expect(jarvis("say hi")).to eq("hi")
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
    let(:tesla_control) { double("TeslaControl", vin: 1, vehicle_data: {}, cached_vehicle_data: {}) }

    before do
      allow(TeslaControl).to receive(:new).and_return(tesla_control)
    end

    address = "123 fake street"
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
      x_pop_boot: { # x_ allows multiple keys at the same time
        res: "Closing the boot",
        opts: [
          "close boot",
          "close the boot",
          "close the trunk",
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
      navigate: {
        res: "It will take about 1 hour to get to #{address}",
        opts: [
          "#{address}",
          " go to #{address}",
          "Navigate #{address}",
          "Take me to #{address}",
        ]
      },
    }

    actions.each do |action, data|
      action = action.to_s.gsub(/x+_/, "").to_sym
      data[:opts].each do |opt|
        it "can #{opt}" do
          allow(tesla_control).to receive(:loc)
          allow(tesla_control).to receive(:start_car)
          data[:others]&.each do |k, args|
            expect(tesla_control).to receive(k).with(*args) if args.present?
            expect(tesla_control).to receive(k) unless args.present?
          end
          unless data[:others]&.any? { |o| o.is_a?(Array) ? o[0] == action : o == action }
            expect(tesla_control).to receive(action) unless data[:skip]
          end
          expect(jarvis(opt)).to eq(data[:res])
        end
      end
    end

    specific_actions = {
      "take me home" => {
        res: "It will take about 1 hour to get to home",
        stub: [[:navigate, "4512 W Bartlett Dr, Herriman, UT 84096"]],
      },
      "take me to PT" => {
        res: "It will take about 1 hour to get to PT",
        stub: [[:navigate, "12197 S Draper Gate Dr., Ste B, Draper, UT 84020"]],
      },
      "take me to home depot" => {
        res: "It will take about 1 hour to get to home depot",
        stub: [[:navigate, "3852 13400 S, Riverton, UT 84065"]],
      },
      "go to Home Depot" => {
        res: "It will take about 1 hour to get to Home Depot",
        stub: [[:navigate, "3852 13400 S, Riverton, UT 84065"]],
      },
    }

    specific_actions.each do |action, data|
      it "can #{action}" do
        allow(tesla_control).to receive(:loc)
        allow(tesla_control).to receive(:start_car)
        data[:stub]&.each do |k, args|
          expect(tesla_control).to receive(k).with(args) if args
          expect(tesla_control).to receive(k) unless args
        end
        expect(jarvis(action)).to eq(data[:res])
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

  # Garage is now a task, so would have to pull that in to get it working.
  # context "with garage" do
  #   before do
  #     allow(DataStorage).to receive(:[]).with(any_args).and_return("unimportant")
  #   end
  #
  #   actions = {
  #     "open my garage"   => "Opening the garage",
  #     "Open the garage"  => "Opening the garage",
  #     "open garage"      => "Opening the garage",
  #     "garage open"      => "Opening the garage",
  #
  #     "garage"           => "Toggling the garage",
  #     "garage toggle"    => "Toggling the garage",
  #
  #     "close my garage"  => "Closing the garage",
  #     "Close the garage" => "Closing the garage",
  #     "close garage"     => "Closing the garage",
  #     "garage close"     => "Closing the garage",
  #   }
  #
  #   actions.each do |action, res|
  #     it "can #{action}" do
  #       expect(jarvis(action)).to eq(res)
  #     end
  #   end
  # end

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

  context "with pings" do
    actions = {
      "Send me a ping saying go running" => "Go running",
      "Ping me go do something" => "Go do something",
      "Ping me" => "You asked me to text you, sir.",
      "Ping me The garage was left open." => "The garage was left open.",
    }

    actions.each do |action, msg|
      it "can #{action}" do
        ::WebPushNotifications.send_to(@user, { title: @args })
        expect(WebPushNotifications).to receive(:send_to).with(an_instance_of(User), {title: msg})
        expect(jarvis(action)).to eq("Sending you a ping saying: #{msg}")
      end
    end
  end

  context "with printer" do
    actions = {
      "turn my printer on" => ["Pre-heating your printer", :pre],
      "preheat printer" => ["Pre-heating your printer", :pre],
      "turn printer off" => ["Cooling your printer", :cool],
      "move printer back and forth" => ["Moving the print head back and forth 10mm", :move, :move],
      "move printer side to side" => ["Moving the print head side to side 10mm", :move, :move],
      "move printer up and down" => ["Moving the print head up and down 10mm", :move, :move],
      "printer up" => ["Moving the print head up 10mm", :move],
      "home printer" => ["Homing printer head", :home],
    }

    actions.each do |action, (msg, *cmds)|
      it "can #{action}" do
        Array.wrap(cmds).each do |cmd|
          expect(PrinterApi).to receive(cmd)
        end
        expect(jarvis(action)).to eq(msg)
      end
    end
  end

  context "with action events" do
    it "can add action events" do
      expect(jarvis("log thing")).to eq("Logged Thing")
      expect(@admin.action_events.pluck(:name)).to include("Thing")
    end

    it "can add action events with note" do
      expect(jarvis("log thing sup")).to eq("Logged Thing (sup)")
      expect(@admin.action_events.pluck(:name)).to include("Thing")
      expect(@admin.action_events.pluck(:notes)).to include("sup")
    end

    it "can add action events with time" do
      expect(jarvis("Log thing at 4:52")).to eq("Logged Thing [Today 4:52 AM]")
      expect(@admin.action_events.pluck(:name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 4, 52))
    end

    it "can add action events with fraction" do
      expect(jarvis("Log thing something x1/2")).to eq("Logged Thing (something x1/2)")
      expect(@admin.action_events.pluck(:name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 5, 45))
    end

    it "can add action events with relative time" do
      expect(jarvis("Log thing 10 minutes ago.")).to eq("Logged Thing [Today 5:35 AM]")
      expect(@admin.action_events.pluck(:name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 5, 35))
    end

    it "can add action events with note and time" do
      expect(jarvis("log thing sup at 4:52.")).to eq("Logged Thing (sup) [Today 4:52 AM]")
      expect(@admin.action_events.pluck(:name)).to include("Thing")
      expect(@admin.action_events.pluck(:notes)).to include("sup")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 4, 52))
    end
  end

  context "with Venmo" do
    context "sending money" do
      charges = [
        ["venmo B $10 for 🐱", [:Brendan, 10, "🐱"]],
        ["Venmo B $10.47 bowling and pizza", [:Brendan, 10.47, "bowling and pizza"]],
        ["Venmo Mom $10.47 🎳 and 🍕", [:Mom, 10.47, "🎳 and 🍕"]],
        ["Venmo Mom $10.47 🎳🍕🐱 food", [:Mom, 10.47, "🎳🍕🐱 food"]],
        ["Venmo Sending $15.50 to B for the Uber ride 🚗.", [:Brendan, "15.50", "Uber ride 🚗"]],
        ["Venmo charge $12 to B for 2 coffees ☕☕.", [:Brendan, 12, "2 coffees ☕☕"]],
      ].each do |msg, (name, amount, note)|
        it "can #{msg}" do
          expect(jarvis(msg)).to eq("Paying #{name} $#{amount} for #{note}")
        end
      end
    end

    context "requesting money" do
      charges = [
        ["venmo request B $10 🐱", [:Brendan, 10, "🐱"]],
        ["venmo request $10 from B for 🐱", [:Brendan, 10, "🐱"]],
        ["Venmo Requesting a payment of $100 from B for rent 💸.", [:Brendan, 100, "rent 💸"]],
        ["Venmo Request $65 from Mom for 🚙📃", [:Mom, 65, "🚙📃"]],
        ["Venmo Request Mom $40 🏦", [:Mom, 40, "🏦"]],
      ].each do |msg, (name, amount, note)|
        it "can #{msg}" do
          expect(jarvis(msg)).to eq("Requesting $#{amount} from #{name} for #{note}")
        end
      end
    end
  end

  context "with scheduling" do
    # now Time.local(2022, 6, 24, 5, 45)
    it "can schedule a job for later" do
      expect(::Jil::Schedule).to receive(:add_schedule).with(@admin.id, 10.minutes.from_now, :command, { words: "add something to list"})
      expect(jarvis("add something to list in 10 minutes")).to eq("I'll add something to list today at 5:55am")
    end

    it "can schedule a job for a time" do
      expect(::Jil::Schedule).to receive(:add_schedule).with(@admin.id, Time.local(2022, 6, 24, 21, 45), :command, { words: "add something to list"})
      expect(jarvis("add something to list at 9:45 PM")).to eq("I'll add something to list today at 9:45pm")
    end

    it "can schedule a job in the middle of a command" do
      msg = "Do the laundry"
      # Jil::Schedule.add_schedule(user, execute_at, trigger, data)
      perform_enqueued_jobs {
        expect(Jil::Schedule).to receive(:add_schedule).with(
          @admin.id,
          be_within(1.second).of(5.minutes.from_now),
          :command,
          { words: "Text me to do the laundry" }
        ).and_call_original
        # Call original above to make sure the SmsWorker gets called

        expect(SmsWorker).to receive(:perform_async).with("3852599640", msg)

        expect(jarvis("Text me in 5 minutes to do the laundry")).to eq("I'll text you to do the laundry today at 5:50am")

        Timecop.travel(5.minutes.from_now) do
          # Trigger Worker is run immediately because of inline jobs, but then cancels since
          #   the schedule time is in the future. Re-run the job.
          ::TriggerWorker.perform_async(::ScheduledTrigger.maximum(:id))
        end
      }
    end

    actions = {
      # Time.local(2022, 6, 24, 5, 45),
      # If the middle of the day, check "morning" is the next morning and "11:15" does that night
      "tomorrow" => [Time.local(2022, 6, 25, 12, 00), "tomorrow at noon"], # Default time is noon
      "in an hour" => [Time.local(2022, 6, 24, 6, 45), "today at 6:45am"],
      "in an hour 20" => [Time.local(2022, 6, 24, 7, 05), "today at 7:05am"],
      "in an hour and 20" => [Time.local(2022, 6, 24, 7, 05), "today at 7:05am"],
      "in an hour and 20 minutes" => [Time.local(2022, 6, 24, 7, 05), "today at 7:05am"],
      "in an hour and a half" => [Time.local(2022, 6, 24, 7, 15), "today at 7:15am"],
      "in 3 and a half hours" => [Time.local(2022, 6, 24, 9, 15), "today at 9:15am"],
      "in 3 hours and 30 minutes" => [Time.local(2022, 6, 24, 9, 15), "today at 9:15am"],
      "3 hours and 30 minutes ago" => [Time.local(2022, 6, 24, 2, 15), "today at 2:15am"],
      "in 3.5 hours" => [Time.local(2022, 6, 24, 9, 15), "today at 9:15am"],
      "tonight" => [Time.local(2022, 6, 24, 22, 0), "today at 10pm"],
      "at 11:15 tomorrow" => [Time.local(2022, 6, 25, 11, 15), "tomorrow at 11:15am"],
      "at 9:15 tomorrow night" => [Time.local(2022, 6, 25, 21, 15), "tomorrow at 9:15pm"],
      "in the morning" => [Time.local(2022, 6, 24, 9, 00), "today at 9am"], # Morning is 9am - same day because it's early
      "at 5:30am" => [Time.local(2022, 6, 25, 5, 30), "tomorrow at 5:30am"], # Morning is 9am - same day because it's early
      "at 9:45 pm" => [Time.local(2022, 6, 24, 21, 45), "today at 9:45pm"],
      "tomorrow afternoon" => [Time.local(2022, 6, 25, 15, 00), "tomorrow at 3pm"], # Afternoon is 3pm
      "next wednesday" => [Time.local(2022, 6, 29, 12, 00), "on Wed, Jun 29 at noon"], # Default is noon
      "on wednesday" => [Time.local(2022, 6, 29, 12, 00), "on Wed, Jun 29 at noon"], # Default is noon
      "oct 23" => [Time.local(2022, 10, 23, 12, 00), "on Sun, Oct 23 at noon"], # Default is noon
      "oct 23, 2022" => [Time.local(2022, 10, 23, 12, 00), "on Sun, Oct 23 at noon"], # Default is noon
      "october 23 25 at 9" => [Time.local(2025, 10, 23, 9, 00), "on Thu, Oct 23, 2025 at 9am"],
    }

    actions.each do |time_words, (timestamp, rel_time)|
      it "can schedule #{time_words}" do
        expect(::Jil::Schedule).to receive(:add_schedule).with(@admin.id, timestamp, :command, { words: "Do thing"})
        if rel_time.present?
          expect(jarvis("Do thing #{time_words}")).to eq("I'll do thing #{rel_time}")
        else
          expect(jarvis("Do thing #{time_words}")).to eq("I'll do thing on #{timestamp.strftime("%a, %b %-d at %-l:%M%P")}")
        end
      end
    end
  end
end
