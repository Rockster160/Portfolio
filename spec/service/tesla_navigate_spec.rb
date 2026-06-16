require "rails_helper"

# Pin the destination-resolution priority used by Tesla.navigate (Jil method
# + TeslaControl#navigate): contact > lat,lng > raw address. Matches the
# same precedence Jarvis voice nav has always used.
RSpec.describe "TeslaControl.resolve_destination" do
  subject(:resolve) { TeslaControl.resolve_destination(input) }

  let(:address_book) { instance_double("AddressBook") }
  before { allow(User.me).to receive(:address_book).and_return(address_book) }

  context "contact name resolution" do
    let(:sarah) { double(primary_address: double(street: "123 Main St")) }
    before do
      # contact_by_name returns sarah only when called with "Sarah";
      # variants miss until the normalizer feeds the bare name.
      allow(address_book).to receive(:contact_by_name).and_return(nil)
      allow(address_book).to receive(:contact_by_name).with("Sarah").and_return(sarah)
    end

    {
      "Sarah"            => "123 Main St",
      "Sarah's"          => "123 Main St",
      "Sarah’s"          => "123 Main St", # curly apostrophe
      "Sarah's house"    => "123 Main St",
      "Sarah's place"    => "123 Main St",
      "Sarahs"           => "123 Main St",
    }.each do |variant, expected|
      it "resolves #{variant.inspect} to the contact's address" do
        expect(TeslaControl.resolve_destination(variant)).to eq(expected)
      end
    end
  end

  context "when input is a lat,lng pair" do
    let(:input) { "40.4804, -111.998191" }
    before { allow(address_book).to receive(:contact_by_name).and_return(nil) }

    it "returns whitespace-stripped coordinates" do
      expect(resolve).to eq("40.4804,-111.998191")
    end
  end

  context "when input is a free-form address" do
    let(:input) { "1 Apple Park Way, Cupertino" }
    before { allow(address_book).to receive(:contact_by_name).and_return(nil) }

    it "passes through unchanged" do
      expect(resolve).to eq("1 Apple Park Way, Cupertino")
    end
  end

  context "with empty input" do
    let(:input) { "  " }

    it "returns an empty string without consulting the address book" do
      expect(address_book).not_to receive(:contact_by_name)
      expect(resolve).to eq("")
    end
  end
end
