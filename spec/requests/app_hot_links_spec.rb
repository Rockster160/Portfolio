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
        "0" => { title: "Log water", icon: "drop.fill", action: { kind: "command", value: "Log Water", inline: "false" } },
        "1" => { title: "Take me to…", action: { kind: "prompt", send_as: "command", prefix: "Take me to ", inline: "true" } },
        "2" => { title: "", action: { kind: "command" } },
        "3" => { title: "Bad", action: { kind: "teleport" } },
      },
    }, headers: headers

    links = user.reload.hot_links
    expect(links.pluck("title")).to eq(["Log water", "Take me to…"])
    expect(links.first["action"]).to eq("kind" => "command", "value" => "Log Water", "inline" => false)
    expect(links.last["action"]).to eq("kind" => "prompt", "send_as" => "command", "prefix" => "Take me to ", "inline" => true)
    expect(links.last["icon"]).to eq("bolt.fill")
    expect(second.serialize[:hot_links]).to eq(links)
    expect(AppDevicePushWorker).to have_received(:perform_async).with(issued.first.id, { "settings" => true })
    expect(AppDevicePushWorker).to have_received(:perform_async).with(second.id, { "settings" => true })
  end

  it "refuses a hot link whose data isn't JSON", :aggregate_failures do
    patch app_hot_links_path, params: {
      hot_links: { "0" => { title: "Run it", action: { kind: "task", value: "1", data: "{nope" } } },
    }, headers: headers

    expect(flash[:alert]).to include("isn't valid JSON")
    expect(user.reload.hot_links).to eq([])
  end
end
