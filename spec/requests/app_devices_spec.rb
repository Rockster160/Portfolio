require "rails_helper"

RSpec.describe "Buddy app device settings", type: :request do
  let(:user) { User.me }
  let!(:issued) { AppDevice.issue!(user, name: "Phone", apns_token: "cafe") }
  let(:device) { issued.first }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }

  before { allow(AppDevicePushWorker).to receive(:perform_async) }

  it "keeps a permission feature off until the phone is allowed it", :aggregate_failures do
    patch app_device_path(device), params: { features: ["", "battery", "location"] }, headers: headers
    expect(device.reload.features).to eq(["battery"])

    device.update!(permissions: { location: "granted" })
    patch app_device_path(device), params: { features: ["", "battery", "location"] }, headers: headers
    expect(device.reload.features).to contain_exactly("battery", "location")
  end

  it "saves each option as its own type and tells the phone", :aggregate_failures do
    patch app_device_path(device), params: {
      preferences: {
        push_badges:             "false",
        location_mode:           "continuous",
        location_minimum_meters: "9000",
        push_channels:           ["", "byte", "nonsense"],
        made_up:                 "1",
      },
    }, headers: headers

    expect(device.reload.preferences).to eq(
      "push_badges"             => false,
      "location_mode"           => "continuous",
      "location_minimum_meters" => 2000,
      "push_channels"           => ["byte"],
    )
    expect(AppDevicePushWorker).to have_received(:perform_async).with(device.id, { "settings" => true })
  end

  it "keeps a select to its own choices" do
    patch app_device_path(device), params: { preferences: { location_mode: "teleport" } }, headers: headers

    expect(device.reload.preference(:location_mode)).to eq(:significant)
  end

  it "saves hot links in order, dropping blank rows", :aggregate_failures do
    patch hot_links_app_device_path(device), params: {
      hot_links: {
        "0" => { title: "Log water", icon: "drop.fill", action: { kind: "command", value: "Log Water", inline: "false" } },
        "1" => { title: "Take me to…", action: { kind: "prompt", send_as: "command", prefix: "Take me to ", inline: "true" } },
        "2" => { title: "", action: { kind: "command" } },
        "3" => { title: "Bad", action: { kind: "teleport" } },
      },
    }, headers: headers

    links = device.reload.hot_links
    expect(links.pluck("title")).to eq(["Log water", "Take me to…"])
    expect(links.first["action"]).to eq("kind" => "command", "value" => "Log Water", "inline" => false)
    expect(links.last["action"]).to eq("kind" => "prompt", "send_as" => "command", "prefix" => "Take me to ", "inline" => true)
    expect(links.last["icon"]).to eq("bolt.fill")
  end

  it "refuses a hot link whose data isn't JSON", :aggregate_failures do
    patch hot_links_app_device_path(device), params: {
      hot_links: { "0" => { title: "Run it", action: { kind: "task", value: "1", data: "{nope" } } },
    }, headers: headers

    expect(flash[:alert]).to include("isn't valid JSON")
    expect(device.reload.hot_links).to eq([])
  end

  it "runs one of the phone's own tasks through a push", :aggregate_failures do
    post run_app_device_path(device, task: :sync_calendar), headers: headers
    expect(AppDevicePushWorker).to have_received(:perform_async).with(device.id, { "device_task" => "sync_calendar" })

    post run_app_device_path(device, task: :format_disk), headers: headers
    expect(flash[:alert]).to eq("Unknown task")
  end

  it "renders every feature, locking the ones waiting on a permission", :aggregate_failures do
    get app_device_path(device), headers: headers

    page = Nokogiri::HTML(response.body)
    expect(page.at("#feature-toggle-battery")["disabled"]).to be_nil
    expect(page.at("#feature-toggle-location")["disabled"]).to eq("disabled")
    expect(page.css("[data-buddy-allow]").to_a.pluck("data-buddy-allow")).to include("location", "health")
  end

  it "does not show someone else's phone" do
    other, = AppDevice.issue!(create(:user), name: "Theirs")

    get app_device_path(other), headers: headers

    expect(response).not_to have_http_status(:ok)
  end
end
