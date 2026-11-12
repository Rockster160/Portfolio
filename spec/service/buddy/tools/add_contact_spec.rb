require "rails_helper"

RSpec.describe "add_contact tool" do
  let(:user) { create(:user) }
  let(:ctx) { Buddy::ToolContext.new(user) }
  let(:tool) { Buddy::Tools[:add_contact] }

  def confirm(**payload)
    tool[:confirm].call(payload, ctx)
  end

  def add(**payload)
    tool[:execute].call(payload.merge(confirm(**payload)[:resolved]), ctx)
  end

  it "saves a new contact with the address as its primary one" do
    result = add(name: "Whit", address: "1388 E Fort Union Blvd,\nCottonwood Heights")
    contact = user.contacts.find_by(name: "Whit")

    expect(result).to include(created: true, name: "Whit")
    expect(contact.primary_address.street).to eq("1388 E Fort Union Blvd, Cottonwood Heights")
    expect(contact.primary_address.user).to eq(user)
  end

  it "asks before saving, naming what goes in" do
    expect(confirm(name: "Whit", address: "1 Main St", phone: "8015550134")[:summary]).to eq(
      "Add Whit to contacts with 1 Main St · 8015550134?",
    )
  end

  it "keeps the map location when the address geocodes" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.62, -111.83])

    add(name: "Whit", address: "1388 E Fort Union Blvd")

    expect(user.contacts.find_by(name: "Whit").primary_address.loc).to eq([40.62, -111.83])
  end

  it "saves the address without a location when it doesn't geocode" do
    add(name: "Whit", address: "Somewhere Unfindable")

    expect(user.contacts.find_by(name: "Whit").primary_address.loc).to eq([nil, nil])
  end

  it "adds the address to a contact that already exists instead of a second one" do
    carlos = user.contacts.create!(name: "Carlos")
    carlos.addresses.create!(user: user, street: "2848 W 7500 S", primary: true)

    result = add(name: "carlos", address: "12 Office Park", label: "work")

    expect(result).to include(created: false, name: "Carlos")
    expect(user.contacts.where(name: "Carlos").count).to eq(1)
    expect(carlos.addresses.ordered.pluck(:street, :label, :primary)).to eq(
      [["2848 W 7500 S", nil, true], ["12 Office Park", "work", false]],
    )
  end

  it "refuses the same address twice" do
    user.contacts.create!(name: "Carlos").addresses.create!(user: user, street: "2848 W 7500 S")

    expect { confirm(name: "Carlos", address: "2848 w 7500 s") }.to raise_error(/already has/)
  end

  it "saves a phone and email with no address" do
    add(name: "Sarah", phone: "801-555-0134", email: "sarah@example.com")

    expect(user.contacts.find_by(name: "Sarah")).to have_attributes(
      phone: "801-555-0134",
      email: "sarah@example.com",
    )
  end

  it "needs something to save beyond the name" do
    expect { confirm(name: "Whit") }.to raise_error(/nothing to save/)
  end

  it "never touches someone else's contact of the same name" do
    other = create(:user)
    other.contacts.create!(name: "Whit")

    add(name: "Whit", address: "1 Main St")

    expect(other.contacts.find_by(name: "Whit").addresses).to be_empty
    expect(user.contacts.find_by(name: "Whit").primary_address.street).to eq("1 Main St")
  end
end
