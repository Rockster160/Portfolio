require "rails_helper"

RSpec.describe Contact, type: :model do
  let(:user) { create(:user, phone: 10.times.map { rand(0..9) }.join) }

  describe "new fields" do
    it "persists email, birthday, notes" do
      contact = user.contacts.create!(
        name:     "Alex",
        email:    "alex@example.com",
        birthday: Date.new(1990, 4, 12),
        notes:    "Met at the coffee shop",
      )

      contact.reload
      expect(contact.email).to eq("alex@example.com")
      expect(contact.birthday).to eq(Date.new(1990, 4, 12))
      expect(contact.notes).to eq("Met at the coffee shop")
    end

    it "includes new fields in serialize" do
      contact = user.contacts.create!(
        name:     "Sam",
        email:    "sam@example.com",
        birthday: Date.new(1985, 6, 1),
        notes:    "Owes me $5",
      )
      contact.tags = [Tag.find_or_create_by(name: "friend")]

      serialized = contact.serialize
      expect(serialized[:email]).to eq("sam@example.com")
      expect(serialized[:birthday]).to eq(Date.new(1985, 6, 1))
      expect(serialized[:notes]).to eq("Owes me $5")
      expect(serialized[:tags]).to eq(["friend"])
    end
  end

  describe "tag_strings" do
    it "creates and assigns tags from a comma-separated string" do
      contact = user.contacts.create!(name: "Jamie")
      contact.tag_strings = "Family, Coworker, Family"

      expect(contact.tags.map(&:name)).to match_array(["family", "coworker"])
      expect(contact.tag_strings).to include("family")
      expect(contact.tag_strings).to include("coworker")
    end

    it "reuses existing tags via find_or_create_by" do
      existing = Tag.create!(name: "family")
      contact = user.contacts.create!(name: "Riley")
      contact.tag_strings = "family"

      expect(contact.tags).to eq([existing])
    end

    it "removes tags dropped from the string" do
      contact = user.contacts.create!(name: "Pat")
      contact.tag_strings = "a, b"
      contact.tag_strings = "b"

      expect(contact.tags.map(&:name)).to eq(["b"])
    end
  end

  describe "#resync" do
    it "pulls email out of raw[:emails] the same way it pulls phone" do
      contact = user.contacts.create!(name: "Placeholder")
      contact.update_columns(
        raw: {
          name:   "Casey",
          phones: [{ value: "+18015551212" }],
          emails: [{ value: "casey@example.com" }],
        },
      )

      contact.resync
      contact.reload

      expect(contact.email).to eq("casey@example.com")
      expect(contact.phone).to eq("8015551212")
    end
  end

  describe "search_terms includes email" do
    it "finds contacts by email substring" do
      user.contacts.create!(name: "Nikki", email: "nikki@example.com")
      user.contacts.create!(name: "Other", email: "someone@else.com")

      results = user.contacts.search("nikki@")
      expect(results.map(&:name)).to eq(["Nikki"])
    end
  end
end
