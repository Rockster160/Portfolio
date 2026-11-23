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

  it "saves one switch at a time and answers with what it saved", :aggregate_failures do
    json = headers.merge("Accept" => "application/json")

    patch app_device_path(device), params: { feature: :location, on: true }, headers: json, as: :json
    expect(response.parsed_body["features"]).not_to include("location")

    patch app_device_path(device), params: { feature: :battery, on: false }, headers: json, as: :json
    expect(device.reload.features).not_to include("battery")
    expect(device.features).to include("widgets")

    patch app_device_path(device), params: { preferences: { push_channels: [] } }, headers: json, as: :json
    expect(response.parsed_body.dig("preferences", "push_channels")).to eq([])
  end

  it "answers a test in place, saying why one wasn't sent", :aggregate_failures do
    json = headers.merge("Accept" => "application/json")
    allow(Apns).to receive(:deliver).and_return(Apns::Result.new(status: 0, reason: :NotConfigured))

    post test_push_app_device_path(device, kind: :alert), headers: json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["message"]).to eq("Not sent: the server has no APNs key for this build")
  end

  it "keeps a select to its own choices" do
    patch app_device_path(device), params: { preferences: { location_mode: "teleport" } }, headers: headers

    expect(device.reload.preference(:location_mode)).to eq(:significant)
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

  it "opens the only phone there is without the app's cookie" do
    get app_settings_path, headers: headers

    expect(response).to redirect_to(app_device_path(device))
  end

  it "does not show someone else's phone" do
    other, = AppDevice.issue!(create(:user), name: "Theirs")

    get app_device_path(other), headers: headers

    expect(response).not_to have_http_status(:ok)
  end
end
