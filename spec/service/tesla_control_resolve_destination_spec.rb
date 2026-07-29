require "rails_helper"

# The "Alpine" bug: a fuzzy place name was handed straight to Tesla's onboard
# search, which resolved the nearest matching CITY instead of the real spot.
# resolve_destination now resolves fuzzy names to a concrete address first.
RSpec.describe TeslaControl, ".resolve_destination" do
  let(:address_book) { instance_double(AddressBook) }

  before do
    allow(User).to receive(:me).and_return(instance_double(User, address_book: address_book))
    allow(address_book).to receive_messages(match_contact: nil, nearest_from_name: nil)
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
