RSpec.describe Jarvis do
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
      expect(Jarvis::IM_HERE_RESPONSES).to include(jarvis("You there?"))
      # What did I have for breakfast?
      # > You had cereal this morning, sir.
      # Good morning / greeting
      # > Good morning, sir. The weather today is <>. You don't have anything scheduled after your morning meetings.
      # Good afternoon
      # > Good afternoon, sir. The weather for the rest of the day is <>. You don't have any more meetings scheduled.
      # Good night
      # > Good night, sir. The weather tomorrow is <>. You don't have anything scheduled after your morning meetings.
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
      allow(DataStorage).to receive(:[]).with(any_args).and_return("hi")
      allow(DataStorage).to receive(:[]).with(:jarvis_shortcuts).and_return({})
      allow(TeslaControl).to receive(:new).and_return(tesla_control)
    end

    actions = {
      start_car: {
        res: "Starting car",
        opts: [
          # "start climate",
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
          "open the car trunk",
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
        res: "Car temp set to 82 and seat heaters turned on",
        opts: [
          "warm my car",
          "heat my car",
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
      expect(jarvis("log thing at 7:52")).to eq("Logged Thing [6/24/22 7:52:00 AM]")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 7, 52))
    end

    it "can add action events with relative time" do
      expect(jarvis("log thing 10 minutes ago")).to eq("Logged Thing [6/24/22 5:35:00 AM]")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 5, 35))
    end

    it "can add action events with note and time" do
      expect(jarvis("log thing sup at 7:52")).to eq("Logged Thing (sup) [6/24/22 7:52:00 AM]")
      expect(@admin.action_events.pluck(:event_name)).to include("Thing")
      expect(@admin.action_events.pluck(:notes)).to include("sup")
      expect(@admin.action_events.pluck(:timestamp)).to include(Time.local(2022, 6, 24, 7, 52))
    end
  end

  context "with commands" do
  end

  context "with scheduling" do
    it "can schedule a job for later" do
      
    end
  end
end
