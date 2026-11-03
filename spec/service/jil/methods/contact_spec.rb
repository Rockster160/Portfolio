require "rails_helper"

RSpec.describe Jil::Methods::Contact, type: :service do
  let(:user) { create(:user) }
  let(:contact) { Contact.create!(user: user, name: "Target") }
  let(:tag) { Tag.find_or_create_by!(name: "store") }

  describe ".tags binding" do
    before { contact.tags << tag }

    it "returns the contact's tag names, which Array.include? reads" do
      ctx = Jil::Executor.call(user,
        <<~'JIL',
          c = Contact.find("Target")::Contact
          t = c.tags()::Array
          is_store = t.include?("store")::Boolean
        JIL
      )

      expect(ctx.ctx[:vars][:t][:value]).to eq(["store"])
      expect(ctx.ctx[:vars][:is_store][:value]).to be(true)
    end
  end

  it "returns [] when the contact has no tags" do
    ctx = Jil::Executor.call(user,
      <<~'JIL',
        c = Contact.find("Target")::Contact
        t = c.tags()::Array
      JIL
    )

    expect(ctx.ctx[:vars][:t][:value]).to eq([])
  end
end
