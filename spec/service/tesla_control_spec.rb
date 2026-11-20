require "rails_helper"

RSpec.describe TeslaControl do
  # Pins the defensive nil-check on `RestClient::ExceptionWithResponse#response`
  # inside `TeslaControl#tesla_exc_code`. Some failure modes (connection
  # reset, DNS, timeout-without-response) raise the response-bearing
  # exception class with `response == nil` — calling `.code` on nil leaks
  # `NoMethodError` into the worker exception report instead of the
  # wakeup_retry's intentional `else` branch.
  describe "exception codes" do
    let(:control) { TeslaControl.new(User.me) }

    describe "#tesla_exc_code (private)" do
      it "returns 500 when the exception's response is nil" do
        exc = RestClient::ServerBrokeConnection.new(nil)
        expect(exc.response).to be_nil
        expect(control.send(:tesla_exc_code, exc)).to eq(500)
      end

      it "returns the exception's status code when response is present and non-500" do
        response = instance_double(RestClient::Response, code: 401)
        exc = instance_double(RestClient::ExceptionWithResponse, response: response)
        expect(control.send(:tesla_exc_code, exc)).to eq(401)
      end
    end

    describe "#wakeup_retry — home proxy unreachable" do
      before do
        allow(TeslaCommand).to receive(:broadcast)
        allow(control).to receive(:err)
      end

      TeslaErrorClassifier::PROXY_UNREACHABLE_CLASSES.each do |klass|
        it "returns false + calls err() (which posts a Slack notification) when #{klass} is raised" do
          called = 0
          result = control.send(:wakeup_retry) {
            called += 1
            raise klass, "boom"
          }
          expect(result).to be(false)
          expect(called).to eq(1)
          expect(control).to have_received(:err).with("Home proxy unreachable", kind_of(klass))
        end
      end
    end
  end

  # The "Alpine" bug: a fuzzy place name was handed straight to Tesla's onboard
  # search, which resolved the nearest matching CITY instead of the real spot.
  # resolve_destination now resolves fuzzy names to a concrete address first.
  describe "resolving a destination" do
    let(:address_book) { instance_double(AddressBook) }

    before do
      allow(User).to receive(:me).and_return(instance_double(User, address_book: address_book))
      allow(address_book).to receive_messages(contact_place: nil, nearest_from_name: nil)
      allow(address_book).to receive(:valid_loc?) { |loc| AddressBook.new(nil).valid_loc?(loc) }
    end

    def saved(street, loc=[nil, nil], name: "Saved")
      instance_double(Address, street: street, loc: loc, contact: instance_double(Contact, name: name))
    end

    it "uses a contact's address before asking Places" do
      allow(address_book).to receive(:contact_place).with("Herriman DMV").and_return(saved("5278 W Anthem Peak Ln"))

      expect(described_class.resolve_destination("Herriman DMV")).to eq("5278 W Anthem Peak Ln")
      expect(address_book).not_to have_received(:nearest_from_name)
    end

    it "passes a bare lat,lng pair straight through" do
      expect(described_class.resolve_destination("40.4804, -111.998")).to eq("40.4804,-111.998")
    end

    it "resolves a fuzzy place name to a concrete address instead of shipping the phrase" do
      allow(address_book).to receive(:nearest_from_name).with("the plunge in Alpine", extract: :place).and_return(
        { name: "Plunge Spot", address: "100 Plunge Way, Alpine, UT 84004, USA", loc: [40.4, -111.7] },
      )

      expect(described_class.resolve_destination("the plunge in Alpine"))
        .to eq("100 Plunge Way, Alpine, UT 84004, USA")
    end

    it "falls back to the raw text when nothing resolves" do
      expect(described_class.resolve_destination("somewhere unknowable")).to eq("somewhere unknowable")
    end

    describe "the text shared with the car" do
      def shared(input)
        described_class.share_text(described_class.resolve_place(input))
      end

      it "sends a place with coordinates as its name, its street on one line and a pinned map link" do
        falls = saved(
          "Horsetail Falls Trail\r\nDeer Creek-Dry Creek, Alpine, UT  84004, United States",
          [40.48301384647123, -111.7503783541636],
          name: "Horsetail Falls",
        )
        allow(address_book).to receive(:contact_place).with("the plunge").and_return(falls)

        expect(shared("the plunge")).to eq(
          <<~TEXT.chomp,
            Horsetail Falls
            Horsetail Falls Trail, Deer Creek-Dry Creek, Alpine, UT 84004, United States
            https://www.google.com/maps/search/?api=1&query=40.48301384647123,-111.7503783541636
          TEXT
        )
        expect(address_book).not_to have_received(:nearest_from_name)
      end

      it "keeps the house number" do
        allow(address_book).to receive(:contact_place).with("Sarah").and_return(
          saved("123 Main St, Draper, UT", [40.5, -111.9], name: "Sarah"),
        )

        expect(shared("Sarah").lines[1].strip).to eq("123 Main St, Draper, UT")
      end

      it "sends just the street for a saved place with no coordinates" do
        allow(address_book).to receive(:contact_place).with("Sarah").and_return(saved("123 Main\nSt"))

        expect(shared("Sarah")).to eq("123 Main, St")
      end

      it "sends a Places hit the same way, pinned to its point" do
        allow(address_book).to receive(:nearest_from_name).with("Costco", extract: :place).and_return(
          { name: "Costco Wholesale", address: "13123 S 5600 W, Herriman, UT 84096", loc: [40.51, -112.01] },
        )

        expect(shared("Costco")).to eq(
          "Costco Wholesale\n13123 S 5600 W, Herriman, UT 84096\n" \
          "https://www.google.com/maps/search/?api=1&query=40.51,-112.01",
        )
      end

      it "sends a bare lat,lng pair and unknown text unchanged" do
        expect(shared("40.4804, -111.998")).to eq("40.4804,-111.998")
        expect(shared("somewhere unknowable")).to eq("somewhere unknowable")
      end

      it "is what navigate shares" do
        allow(address_book).to receive(:contact_place).with("Sarah").and_return(saved("123 Main St"))
        ctrl = described_class.allocate
        allow(ctrl).to receive(:command)

        ctrl.navigate("Sarah")

        expect(ctrl).to have_received(:command).with(
          :navigation_request,
          hash_including(type: :share_ext_content_raw, value: { "android.intent.extra.TEXT": "123 Main St" }),
        )
      end
    end
  end

  describe "navigating to nothing" do
    subject(:resolve) { TeslaControl.resolve_destination(input) }

    let(:address_book) { instance_double(AddressBook) }

    let(:input) { "  " }

    before { allow(User.me).to receive(:address_book).and_return(address_book) }

    it "returns an empty string without consulting the address book" do
      expect(address_book).not_to receive(:match_contact)
      expect(resolve).to eq("")
    end
  end

  describe "TeslaCommand navigate response" do
    subject(:response) { TeslaCommand.quick_command(:navigate, "Home Depot") }

    let(:address_book) { instance_double("AddressBook") }

    before do
      allow(TeslaCommand).to receive(:address_book).and_return(address_book)
      allow(TeslaCommand).to receive(:broadcast)
      allow(TeslaCommandWorker).to receive(:perform_async)
      allow(DataStorage).to receive(:[]).with(:tesla_forbidden).and_return(false)
      contact = double(primary_address: double(street: "123 Main St"))
      allow(address_book).to receive(:match_contact).with("Home Depot").and_return(contact)
    end

    it "includes the drive time in the navigating message" do
      allow(address_book).to receive(:traveltime_seconds).with("123 Main St").and_return(12.minutes.to_i)
      expect(response).to eq("Navigating to Home Depot — 12 minutes away")
    end

    it "still navigates without a drive time when the lookup fails" do
      allow(address_book).to receive(:traveltime_seconds).with("123 Main St").and_return(nil)
      expect(response).to eq("Navigating to Home Depot")
    end

    it "cancels when already at the destination" do
      allow(address_book).to receive(:traveltime_seconds).with("123 Main St").and_return(30)
      expect(TeslaCommandWorker).not_to receive(:perform_async)
      expect(response).to eq("You're already at your destination.")
    end
  end

  describe "TeslaControl#add_stop" do
    let(:ctrl) { TeslaControl.new(User.me) }
    let(:address_book) { instance_double("AddressBook") }

    before do
      allow(User.me).to receive(:address_book).and_return(address_book)
      allow(TeslaControl).to receive(:resolve_place).with("Costco").and_return({ text: "Costco" })
    end

    it "geocodes the resolved address and sends a single navigation_gps_request at order:1" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      expect(ctrl).to receive(:proxy_command).with(:navigation_gps_request, lat: 40.5, lon: -111.9, order: 1)
      expect(ctrl.add_stop("Costco")).to be(true)
    end

    it "uses the place's stored coordinates without geocoding" do
      allow(TeslaControl).to receive(:resolve_place).with("the plunge").and_return(
        { name: "Horsetail Falls", street: "Horsetail Falls Trailhead", loc: [40.483, -111.7504] },
      )
      expect(address_book).not_to receive(:geocode)
      expect(ctrl).to receive(:proxy_command).with(:navigation_gps_request, lat: 40.483, lon: -111.7504, order: 1)
      expect(ctrl.add_stop("the plunge")).to be(true)
    end

    it "returns false without sending if address resolves blank" do
      allow(TeslaControl).to receive(:resolve_place).with("").and_return({ text: "" })
      expect(ctrl).not_to receive(:proxy_command)
      expect(ctrl.add_stop("")).to be(false)
    end

    it "returns false without sending if geocoding fails" do
      allow(address_book).to receive(:geocode).with("Costco").and_return(nil)
      expect(ctrl).not_to receive(:proxy_command)
      expect(ctrl.add_stop("Costco")).to be(false)
    end

    it "accepts a custom order" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      expect(ctrl).to receive(:proxy_command).with(:navigation_gps_request, lat: 40.5, lon: -111.9, order: 2)
      expect(ctrl.add_stop("Costco", order: 2)).to be(true)
    end
  end

  # Verifies TeslaControl entry points short-circuit when TeslaSwitch is muted,
  # and that the previously-silent PROXY_UNREACHABLE_ERRORS branch now posts a
  # tailored Slack message via the classifier when the switch is on.
  describe "switches" do
    let(:user) { User.me }
    let(:ctrl) { TeslaControl.new(user) }

    before do
      user.caches.set(TeslaSwitch::CACHE_KEY, {})
      allow(SlackNotifier).to receive(:notify)
      allow(TeslaCommand).to receive(:broadcast)
    end

    context "when switch is muted" do
      before { TeslaSwitch.disable!(reason: "spec") }

      it "touches no API from any entry point, and posts the muted reminder" do
        expect(ctrl.api).not_to receive(:proxy_post)
        expect(ctrl.api).not_to receive(:post)
        expect(ctrl.api).not_to receive(:get)

        expect(ctrl.send(:proxy_command, :flash_lights)).to be(false)
        expect(ctrl.send(:command, :navigation_request, {})).to be(false)
        expect(ctrl.wake_up).to be(false)
        ctrl.vehicle_data
        expect(SlackNotifier).to have_received(:notify).once
      end
    end

    context "when switch is enabled but proxy is unreachable" do
      it "wakeup_retry posts a proxy_unreachable Slack message via err()" do
        allow(ctrl).to receive(:perform_requests?).and_return(true)
        allow(ctrl).to receive(:proxy_post_vehicle).and_raise(Errno::EHOSTUNREACH)
        ctrl.send(:proxy_command, :flash_lights)
        expect(SlackNotifier).to have_received(:notify)
      end
    end
  end

  describe "controls with a direction" do
    let(:ctrl) { TeslaControl.new(User.me) }

    before { allow(ctrl).to receive(:proxy_command).and_return({}) }

    def car(data)
      allow(ctrl).to receive(:vehicle_data).and_return(data)
    end

    it "closes an open trunk and leaves a closed one alone" do
      car(doors: { trunk: true })
      ctrl.pop_boot(:close)
      expect(ctrl).to have_received(:proxy_command).with(:actuate_trunk, which_trunk: :rear).once

      car(doors: { trunk: false })
      expect(ctrl.pop_boot(:close)).to eq(:already)
      expect(ctrl).to have_received(:proxy_command).once
    end

    it "reads the endpoint poll's numeric trunk position as open" do
      car(doors: { trunk: 1 })
      expect(ctrl.pop_boot(:open)).to eq(:already)
      car(doors: { trunk: 0 })
      ctrl.pop_boot(:open)
      expect(ctrl).to have_received(:proxy_command).with(:actuate_trunk, which_trunk: :rear)
    end

    it "refuses to guess when it can't tell where the trunk is" do
      car({})
      expect { ctrl.pop_boot(:close) }.to raise_error(TeslaError)
      expect(ctrl).not_to have_received(:proxy_command)
    end

    it "closes the trunk an awake car reports open" do
      allow(ctrl).to receive(:vehicle_data).and_call_original
      allow(ctrl).to receive_messages(perform_requests?: true, maintain_tire_pressure_alerts!: nil)
      allow(ctrl).to receive(:get).and_return(
        response: { state: "online", vehicle_state: { rt: 32, timestamp: 1 } },
      )

      ctrl.pop_boot(:close)
      expect(ctrl).to have_received(:proxy_command).with(:actuate_trunk, which_trunk: :rear)
    end

    it "toggles the trunk without reading the car" do
      expect(ctrl).not_to receive(:vehicle_data)
      ctrl.pop_boot(:toggle)
      expect(ctrl).to have_received(:proxy_command).with(:actuate_trunk, which_trunk: :rear)
    end

    it "toggles climate and charging from what the car reports" do
      car(climate: { hvac_on: true }, charging: { active: false })
      ctrl.climate(:toggle)
      ctrl.charging(:toggle)
      expect(ctrl).to have_received(:proxy_command).with(:auto_conditioning_stop)
      expect(ctrl).to have_received(:proxy_command).with(:charge_start)
    end

    it "sends each switch as the car expects it" do
      ctrl.climate(:on)
      ctrl.charging(:stop)
      ctrl.charge_port(:close)
      ctrl.charge_port(:open)
      ctrl.sentry(true)
      ctrl.steering_heat(false)
      ctrl.seat_heat(:passenger, 2)
      ctrl.seat_heat(:driver, 9)
      expect(ctrl).to have_received(:proxy_command).with(:auto_conditioning_start)
      expect(ctrl).to have_received(:proxy_command).with(:charge_stop)
      expect(ctrl).to have_received(:proxy_command).with(:charge_port_door_close)
      expect(ctrl).to have_received(:proxy_command).with(:charge_port_door_open)
      expect(ctrl).to have_received(:proxy_command).with(:set_sentry_mode, on: true)
      expect(ctrl).to have_received(:proxy_command).with(:remote_steering_wheel_heater_request, on: false)
      expect(ctrl).to have_received(:proxy_command).with(:remote_seat_heater_request, heater: 1, level: 2)
      expect(ctrl).to have_received(:proxy_command).with(:remote_seat_heater_request, heater: 0, level: 3)
    end
  end
end
