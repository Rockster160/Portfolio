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
      allow(address_book).to receive_messages(match_contact: nil, address_in_phrase: nil, nearest_from_name: nil)
    end

    it "uses a contact named inside the phrase before asking Places" do
      address = instance_double(Address, street: "5278 W Anthem Peak Ln")
      allow(address_book).to receive(:address_in_phrase).with("Herriman DMV").and_return(address)

      expect(described_class.resolve_destination("Herriman DMV")).to eq("5278 W Anthem Peak Ln")
      expect(address_book).not_to have_received(:nearest_from_name)
    end

    it "returns a matched contact's street address first" do
      contact = instance_double(Contact, primary_address: instance_double(Address, street: "123 Main St"))
      allow(address_book).to receive(:match_contact).with("Sarah").and_return(contact)

      expect(described_class.resolve_destination("Sarah")).to eq("123 Main St")
    end

    it "passes a bare lat,lng pair straight through" do
      expect(described_class.resolve_destination("40.4804, -111.998")).to eq("40.4804,-111.998")
    end

    it "resolves a fuzzy place name to a concrete address instead of shipping the phrase" do
      allow(address_book).to receive(:nearest_from_name)
        .with("the plunge in Alpine")
        .and_return("100 Plunge Way, Alpine, UT 84004, USA")

      expect(described_class.resolve_destination("the plunge in Alpine"))
        .to eq("100 Plunge Way, Alpine, UT 84004, USA")
    end

    it "falls back to the raw text when nothing resolves" do
      expect(described_class.resolve_destination("somewhere unknowable")).to eq("somewhere unknowable")
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
      allow(TeslaControl).to receive(:resolve_destination).with("Costco").and_return("Costco")
    end

    it "geocodes the resolved address and sends a single navigation_gps_request at order:1" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      expect(ctrl).to receive(:proxy_command).with(:navigation_gps_request, lat: 40.5, lon: -111.9, order: 1)
      expect(ctrl.add_stop("Costco")).to be(true)
    end

    it "returns false without sending if address resolves blank" do
      allow(TeslaControl).to receive(:resolve_destination).with("").and_return("")
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
end
