require "rails_helper"

# Pin the destination-resolution priority used by Tesla.navigate (Jil method
# + TeslaControl#navigate): contact > lat,lng > raw address. The actual
# contact-name normalization (possessives/plurals/"X's house" etc.) lives
# in AddressBook now — see spec/service/address_book_spec.rb.
RSpec.describe "TeslaControl.resolve_destination" do
  subject(:resolve) { TeslaControl.resolve_destination(input) }

  let(:address_book) { instance_double("AddressBook") }
  before do
    allow(User.me).to receive(:address_book).and_return(address_book)
    # After a contact miss, resolve_destination asks Places to place the phrase
    # near us ("the plunge in Alpine" → the trailhead, not the town). nil is the
    # off-prod / can't-place answer, which is what makes it fall through to the
    # raw text. Stubbed here because the call is wrapped in `rescue nil`, and a
    # verifying double raises an Exception that a StandardError rescue misses —
    # so an unstubbed call fails the example instead of the lookup.
    allow(address_book).to receive(:nearest_from_name).and_return(nil)
  end

  context "when AddressBook returns a contact match" do
    let(:input) { "Sarah" }
    before do
      contact = double(primary_address: double(street: "123 Main St"))
      allow(address_book).to receive(:match_contact).with("Sarah").and_return(contact)
    end

    it "returns the contact's primary street address" do
      expect(resolve).to eq("123 Main St")
    end
  end

  context "when the input is a lat,lng pair (no contact match)" do
    let(:input) { "40.4804, -111.998191" }
    before { allow(address_book).to receive(:match_contact).and_return(nil) }

    it "returns whitespace-stripped coordinates" do
      expect(resolve).to eq("40.4804,-111.998191")
    end
  end

  context "when the input is a free-form address (no contact match)" do
    let(:input) { "1 Apple Park Way, Cupertino" }
    before { allow(address_book).to receive(:match_contact).and_return(nil) }

    it "passes through unchanged" do
      expect(resolve).to eq("1 Apple Park Way, Cupertino")
    end
  end

  context "with empty input" do
    let(:input) { "  " }

    it "returns an empty string without consulting the address book" do
      expect(address_book).not_to receive(:match_contact)
      expect(resolve).to eq("")
    end
  end
end

RSpec.describe "TeslaCommand navigate response" do
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

RSpec.describe "TeslaControl#add_stop" do
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
