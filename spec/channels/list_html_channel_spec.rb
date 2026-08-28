require "rails_helper"

RSpec.describe ListHtmlChannel, type: :channel do
  let(:user) { User.me }
  let(:list) { List.create!(name: "Before Bed Spec") }
  let(:item) { list.list_items.create!(name: "Dish washer set to delay") }

  before do
    UserList.create!(user: user, list: list, is_owner: true)
    allow(::Jil).to receive(:trigger)
    stub_connection(current_user: user)
    subscribe(channel_id: "list_#{list.id}")
  end

  it "fires :removed when a box is ticked" do
    perform :receive, { "list_item" => { "id" => item.id, "checked" => true } }

    expect(item.reload.deleted?).to be(true)
    expect(::Jil).to have_received(:trigger).with(
      user,
      :item,
      hash_including(id: item.id, action: :removed),
      hash_including(auth: :trigger),
    )
  end

  it "fires :added when a ticked box is unticked" do
    item.soft_destroy

    perform :receive, { "list_item" => { "id" => item.id, "checked" => false } }

    expect(item.reload.deleted?).to be(false)
    expect(::Jil).to have_received(:trigger).with(
      user,
      :item,
      hash_including(id: item.id, action: :added),
      hash_including(auth: :trigger),
    )
  end

  it "fires :changed when nothing left or joined the list" do
    perform :receive, { "list_item" => { "id" => item.id, "name" => "Renamed" } }

    expect(::Jil).to have_received(:trigger).with(
      user,
      :item,
      hash_including(id: item.id, action: :changed),
      hash_including(auth: :trigger),
    )
  end
end
