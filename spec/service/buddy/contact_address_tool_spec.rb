require "rails_helper"

RSpec.describe "Buddy contact_address tool" do
  let(:user) { create(:user) }
  let(:tool) { Buddy::Tools[:contact_address] }

  def ctx
    Buddy::ToolContext.new(user)
  end

  def look_up(name)
    payload = { name: name }
    tool[:execute].call(payload.merge(tool[:confirm].call(payload, ctx)[:resolved]), ctx)
  end

  def contact_with(name, addresses)
    user.contacts.create!(name: name).tap { |contact|
      addresses.each { |label, street, primary|
        contact.addresses.create!(user: user, label: label, street: street, primary: primary)
      }
    }
  end

  it "reads a person's primary address" do
    contact_with("Carlos", [[nil, "2848 W 7500 S, West Jordan", true]])

    expect(look_up("Carlos'")).to eq(name: "Carlos", address: { street: "2848 W 7500 S, West Jordan" })
  end

  it "leads with the address the phrase names by label and lists the rest" do
    contact_with("DMV", [["Herriman", "5278 W Anthem Peak Ln", true], ["Riverton", "12830 S Redwood Rd", false]])

    expect(look_up("Riverton DMV")).to eq(
      name:    "DMV",
      address: { street: "12830 S Redwood Rd", label: "Riverton" },
      others:  [{ street: "5278 W Anthem Peak Ln", label: "Herriman" }],
    )
  end

  it "says so when nobody matches" do
    expect { tool[:confirm].call({ name: "Zebulon" }, ctx) }.to raise_error(/no contact matching "Zebulon"/)
  end

  it "says so when the contact has no address" do
    user.contacts.create!(name: "Tim")

    expect { tool[:confirm].call({ name: "Tim" }, ctx) }.to raise_error(/Tim is saved with no address/)
  end

  it "only reads the asker's own contacts" do
    other = create(:user)
    other.contacts.create!(name: "Carlos").addresses.create!(user: other, street: "1 Elsewhere", primary: true)

    expect { tool[:confirm].call({ name: "Carlos" }, ctx) }.to raise_error(/no contact matching/)
  end
end
