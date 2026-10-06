require "rails_helper"

RSpec.describe ListBuildersController, type: :controller do
  let(:user) { FactoryBot.create(:user) }
  let(:list) { FactoryBot.create(:list, user: user) }
  let!(:builder) {
    ListBuilder.create!(
      user:  user,
      list:  list,
      name:  "Pantry",
      items: [{ name: "Milk", img: "🥛", stock: 3 }, { name: "Eggs", img: "🥚", stock: 0 }],
    )
  }

  before { sign_in user }

  describe "GET #show as JSON" do
    it "returns the builder items, the live list, and a snapshot stamp" do
      list.list_items.add("Milk")
      list.list_items.add("Bread")
      list.list_items.remove("Bread")

      get :show, params: { id: builder.to_param }, format: :json

      body = response.parsed_body
      expect(body["items"].pluck("name")).to eq(["Milk", "Eggs"])
      expect(body["list_items"]).to eq(["Milk"])
      expect(body["timestamp"]).to be_within(5_000).of((Time.current.to_f * 1000).round)
    end
  end

  describe "PATCH #update_stock" do
    it "writes absolute counts and returns the stamped snapshot" do
      patch :update_stock, params: { id: builder.to_param, stock: { "Milk" => 1 } }, format: :json

      body = response.parsed_body
      expect(builder.reload.items.to_h { |i| [i[:name], i[:stock]] }).to eq("Milk" => 1, "Eggs" => 0)
      expect(body["items"].to_h { |i| [i["name"], i["stock"]] }).to eq("Milk" => 1, "Eggs" => 0)
      expect(body["timestamp"]).to be_a(Integer)
    end

    it "is safe to replay, so a retry after a lost reply can't apply twice" do
      2.times {
        patch :update_stock, params: { id: builder.to_param, stock: { "Milk" => 2 } }, format: :json
      }

      expect(builder.reload.items.find { |i| i[:name] == "Milk" }[:stock]).to eq(2)
    end

    it "stamps its reply no earlier than the broadcast of the same write" do
      broadcasts = []
      allow(ActionCable.server).to receive(:broadcast) { |_channel, data| broadcasts << data }

      patch :update_stock, params: { id: builder.to_param, stock: { "Eggs" => 4 } }, format: :json

      sent = broadcasts.find { |data| data.key?(:builder_items) }
      expect(sent[:builder_items].find { |i| i[:name] == "Eggs" }[:stock]).to eq(4)
      expect(response.parsed_body["timestamp"]).to be >= sent[:timestamp]
    end
  end
end
