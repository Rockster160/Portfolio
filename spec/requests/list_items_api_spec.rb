require "rails_helper"

# The Claude hooks reach this over plain curl, with no format in the path. That
# makes content negotiation part of the contract: the controller's respond_to
# offers html first, so a caller that wants the created row's id back has to ask
# for json. It does - the id is how a session finds the row it posted last, and
# the whole one-row-per-conversation rule rests on getting it.
RSpec.describe "List items API", type: :request do
  let(:user) { create(:user) }
  let(:user_list) { create(:user_list, user: user) }
  let(:list) { user_list.list }
  let!(:section) { create(:section, list: list, name: "Portfolio") }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def add(name, section_name)
    post "/api/v1/lists/#{list.id}/list_items",
      params:  { name: name, section: section_name }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    response.parsed_body
  end

  it "returns the created item's id" do
    body = add(">abcd Done", "Portfolio")

    expect(response).to have_http_status(:ok)
    expect(body.dig("data", "id")).to eq(ListItem.last.id)
    expect(body.dig("data", "section_id")).to eq(section.id)
  end

  it "deletes by that id alone" do
    id = add(">abcd Done", "Portfolio").dig("data", "id")

    delete "/api/v1/lists/#{list.id}/list_items",
      params:  { id: id }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:ok)
    expect(ListItem.with_deleted.find(id)).to be_deleted
  end

  it "drops an item into no section when the section is not on the list" do
    body = add(">abcd Done", "SomeOtherProject")

    expect(body.dig("data", "section_id")).to be_nil
  end
end
