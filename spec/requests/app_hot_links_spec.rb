require "rails_helper"

RSpec.describe "Buddy app hot links", type: :request do
  let(:user) { User.me }
  let!(:issued) { AppDevice.issue!(user, name: "Phone", apns_token: "cafe") }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }

  before { allow(AppDevicePushWorker).to receive(:perform_async) }

  it "keeps one list for the person, in order, and tells every phone", :aggregate_failures do
    second, = AppDevice.issue!(user, name: "Other phone")

    patch app_hot_links_path, params: {
      hot_links: {
        "0" => {
          title:  "Log water",
          icon:   "drop.fill",
          color:  "#22c55e",
          action: { kind: "command", value: "Log Water", inline: "false" },
        },
        "1" => {
          title:  "Take me to…",
          color:  "red",
          action: { kind: "prompt", send_as: "command", prefix: "Take me to ", inline: "true" },
        },
        "2" => { title: "", action: { kind: "command" } },
        "3" => { title: "Bad", action: { kind: "teleport" } },
      },
    }, headers: headers

    links = user.reload.hot_links
    expect(links.pluck("title")).to eq(["Log water", "Take me to…"])
    expect(links.first["action"]).to eq("kind" => "command", "value" => "Log Water", "inline" => false)
    expect(links.last["action"]).to eq("kind" => "prompt", "send_as" => "command", "prefix" => "Take me to ", "inline" => true)
    expect(links.last["icon"]).to eq("bolt.fill")
    expect(links.pluck("color")).to eq(["#22c55e", nil])
    expect(second.serialize[:hot_links]).to eq(links)
    expect(AppDevicePushWorker).to have_received(:perform_async).with(issued.first.id, { "settings" => true })
    expect(AppDevicePushWorker).to have_received(:perform_async).with(second.id, { "settings" => true })
  end

  it "refuses a hot link whose data isn't JSON, saying why", :aggregate_failures do
    patch app_hot_links_path, params: {
      hot_links: { "0" => { title: "Run it", action: { kind: "task", value: "1", data: "{nope" } } },
    }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["message"]).to include("isn't valid JSON")
    expect(user.reload.hot_links).to eq([])
  end

  it "lets a new link wait until it can run, but won't save a saved one broken", :aggregate_failures do
    patch app_hot_links_path, params: {
      hot_links: { "0" => { title: "Garage", action: { kind: "task", value: "" } } },
    }, headers: headers
    expect(response.parsed_body["hot_links"]).to eq([])

    patch app_hot_links_path, params: {
      hot_links: { "0" => { id: "abc", title: "Garage", action: { kind: "task", value: "" } } },
    }, headers: headers
    expect(response.parsed_body["message"]).to eq("Garage needs a task")
  end

  it "shows a saved link as a closed row in its color, under an open form for a new one", :aggregate_failures do
    user.update!(hot_links: [
      {
        id:     "abc",
        title:  "Log water",
        icon:   "drop.fill",
        color:  "#22c55e",
        action: { kind: "command", value: "Log" },
      },
    ])

    get app_hot_links_path, headers: headers

    page = Nokogiri::HTML(response.body)
    row = page.at_css("[data-hot-links-saved] [data-hot-link]")
    expect(row["style"]).to include("#22c55e")
    expect(row.at_css("[data-hot-link-summary-title]").text).to eq("Log water")
    expect(row.at_css("[data-hot-link-summary-kind]").text).to eq("Run a command")
    expect(row.at_css("[data-hot-link-editor]")["hidden"]).not_to be_nil
    expect(page.at_css("[data-hot-link-new] [data-hot-link-editor]")["hidden"]).to be_nil
  end

  it "keeps the item a list toggle names" do
    patch app_hot_links_path, params: {
      hot_links: { "0" => { title: "Milk", action: { kind: "list_toggle", value: "7", item: " Milk " } } },
    }, headers: headers

    expect(user.reload.hot_links.first["action"]).to eq(
      "kind"  => "list_toggle",
      "value" => "7",
      "data"  => { "item" => "Milk" },
    )
  end
end
