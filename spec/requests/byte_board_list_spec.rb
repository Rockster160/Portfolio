require "rails_helper"

# A list connected to a board (Buddy::BoardList): its items are circles, a
# press checks one off, and the board's own settings say when a checked item
# leaves and which items are high or very high.
RSpec.describe "Byte board list", type: :request do
  let(:user) { User.me }
  let!(:board) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Garage", last_message_at: Time.current,
      metadata: { "board" => true, "chore_tags" => ["Garage"] },
    )
  }
  let!(:list) { List.create!(name: "GO").tap { |l| UserList.create!(user: user, list: l, is_owner: true) } }
  let!(:very_high) { list.sections.create!(name: "Very High", color: "#EF4444") }
  let!(:high) { list.sections.create!(name: "High", color: "#F97316") }
  let!(:chairs) { list.list_items.create!(name: "Chairs") }
  let!(:cards) { list.list_items.create!(name: "Cards", section: high) }
  let!(:keys) { list.list_items.create!(name: "🔑 Keys", section: very_high) }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    host! "byte.example.com"
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  def connect(**opts)
    post "/byte/board/list", params: {
      conversation_id: board.id, list_id: list.id, clear_after: 3600, very_high: "Very High", high: "High",
    }.merge(opts), as: :json
  end

  def items
    get "/byte/board/items", params: { conversation_id: board.id }
    response.parsed_body["items"].select { |item| item["kind"] == "list" }
  end

  it "puts nothing from a list on a board that has none" do
    expect(items).to be_empty
  end

  describe "connecting a list" do
    it "shows its items as circles, very high first, then high, then the rest" do
      connect
      expect(response).to have_http_status(:ok)

      expect(items.map { |item| [item["name"], item["priority"]] }).to eq(
        [["🔑 Keys", "very_high"], ["Cards", "high"], ["Chairs", "normal"]],
      )
    end

    it "takes a leading emoji as the picture" do
      connect

      keys_item = items.first
      expect(keys_item).to include("icon" => "🔑", "short_name" => "Keys", "icon_kind" => "emoji")
      expect(items.last).to include("icon" => nil, "short_name" => "Chairs")
    end

    it "matches a /pattern/ on the item's name" do
      connect(very_high: "/chair/", high: "")

      expect(items.to_h { |item| [item["name"], item["priority"]] }).to eq(
        "Chairs" => "very_high", "Cards" => "normal", "🔑 Keys" => "normal",
      )
    end

    it "refuses a pattern that can't be read, and says why" do
      connect(high: "/(/")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("/(/")
    end

    it "refuses a list that isn't the owner's" do
      other = List.create!(name: "Theirs")
      connect(list_id: other.id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(board.reload.metadata).not_to have_key("board_list")
    end

    it "leaves out items that can't be checked off" do
      list.list_items.create!(name: "Milk", permanent: true)
      connect

      expect(items.pluck("name")).not_to include("Milk")
    end

    it "disconnects with no list" do
      connect
      connect(list_id: "")

      expect(items).to be_empty
    end
  end

  describe "pressing a circle" do
    before { connect }

    it "checks the item off its list, telling Jil, and keeps it on the board until its time is up" do
      expect(Jil).to receive(:trigger).with(user, :item, hash_including(action: :removed), auth: :trigger)
      post "/byte/board/list_items/#{chairs.id}/check", params: { conversation_id: board.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(chairs.reload).to be_deleted
      item = response.parsed_body["item"]
      expect(item["checked"]).to be(true)
      expect(Time.zone.parse(item["clears_at"])).to be_within(2.seconds).of(1.hour.from_now)

      expect(items.find { |i| i["id"] == chairs.id }).to include("checked" => true)
      travel(61.minutes) { expect(items.pluck("id")).not_to include(chairs.id) }
    end

    it "is checked as of when it was pressed" do
      pressed = 10.minutes.ago.change(usec: 0)
      post "/byte/board/list_items/#{chairs.id}/check",
        params: { conversation_id: board.id, client_checked_at: pressed.iso8601 }, as: :json

      expect(chairs.reload.deleted_at).to eq(pressed)
    end

    it "puts it back on Undo" do
      post "/byte/board/list_items/#{chairs.id}/check", params: { conversation_id: board.id }, as: :json
      delete "/byte/board/list_items/#{chairs.id}/check", params: { conversation_id: board.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(chairs.reload).not_to be_deleted
      expect(response.parsed_body["item"]).to include("checked" => false, "clears_at" => nil)
    end

    it "stays for a time of the owner's choosing, down to seconds" do
      connect(clear_after: 30)
      post "/byte/board/list_items/#{chairs.id}/check", params: { conversation_id: board.id }, as: :json

      expect(Time.zone.parse(response.parsed_body["item"]["clears_at"])).to be_within(2.seconds).of(30.seconds.from_now)
      travel(20.seconds) { expect(items.pluck("id")).to include(chairs.id) }
      travel(40.seconds) { expect(items.pluck("id")).not_to include(chairs.id) }
    end

    it "refuses a stay longer than a week" do
      connect(clear_after: 8.days.to_i)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "leaves straight away when set to" do
      connect(clear_after: 0)
      post "/byte/board/list_items/#{chairs.id}/check", params: { conversation_id: board.id }, as: :json

      expect(items.pluck("id")).not_to include(chairs.id)
    end

    it "stays until the chore day ends when set to the end of the day" do
      connect(clear_after: "end_of_day")
      post "/byte/board/list_items/#{chairs.id}/check", params: { conversation_id: board.id }, as: :json

      ends = ChoreDay.ends_at(ChoreDay.current(user), user)
      expect(Time.zone.parse(response.parsed_body["item"]["clears_at"])).to eq(ends)
      travel_to(ends - 1.minute) { expect(items.pluck("id")).to include(chairs.id) }
      travel_to(ends + 1.minute) { expect(items.pluck("id")).not_to include(chairs.id) }
    end

    it "refuses an item from another list" do
      other = List.create!(name: "Other").tap { |l| UserList.create!(user: user, list: l, is_owner: true) }
      stray = other.list_items.create!(name: "Stray")
      post "/byte/board/list_items/#{stray.id}/check", params: { conversation_id: board.id }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(stray.reload).not_to be_deleted
    end
  end

  it "tells the boards showing a list when it changes" do
    connect
    allow(MonitorChannel).to receive(:broadcast_to)
    list.list_items.create!(name: "Ladder")

    expect(MonitorChannel).to have_received(:broadcast_to).with(
      user, hash_including(data: { kind: :board_list, list_id: list.id }),
    ).at_least(:once)
  end

  it "offers the owner's lists and says how the board is set" do
    connect
    get "/board/#{board.id}"

    expect(response.body).to include("data-board-list-dialog")
    expect(response.body).to include(%(<option value="#{list.id}">GO</option>))
    setting = JSON.parse(response.body[/data-board-list="([^"]*)"/, 1].gsub("&quot;", '"'))
    expect(setting).to include("list_id" => list.id, "list_name" => "GO", "clear_after" => 3600)
  end
end
