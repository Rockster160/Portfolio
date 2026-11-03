require "rails_helper"

RSpec.describe ContactsController, type: :controller do
  let(:user) { create(:user) }

  before { sign_in user }

  describe "GET #lookup" do
    it "returns the primary address when a contact name matches" do
      contact = user.contacts.create!(name: "Mom")
      Address.create!(user: user, contact: contact, street: "123 Main St, Anytown, CA", primary: true)

      get :lookup, params: { name: "Mom" }

      expect(response).to be_successful
      body = JSON.parse(response.body)
      expect(body).to eq({ "name" => "Mom", "address" => "123 Main St, Anytown, CA" })
    end

    it "returns an empty object when the contact has no address, nobody matches, or the name is blank" do
      user.contacts.create!(name: "Friend")

      ["Friend", "Nobody", ""].each do |name|
        get :lookup, params: { name: name }
        expect(response).to be_successful
        expect(JSON.parse(response.body)).to eq({}), name
      end
    end

    it "does not leak addresses from other users' contacts" do
      other = create(:user, phone: "5559876543")
      other_contact = other.contacts.create!(name: "Mom")
      Address.create!(user: other, contact: other_contact, street: "Secret", primary: true)

      get :lookup, params: { name: "Mom" }
      expect(JSON.parse(response.body)).to eq({})
    end
  end
end
