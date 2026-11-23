require "rails_helper"

RSpec.describe "Buddy app widgets", type: :request do
  let(:user) { User.me }
  let(:token) { AppDevice.issue!(user, name: "Phone", widget_push_token: "w1", features: ["widgets"]).last }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  it "draws a list with its unchecked items" do
    list = user.lists.create!(name: "Groceries")
    list.list_items.create!(name: "Milk")
    list.list_items.create!(name: "Eggs").update!(deleted_at: Time.current)

    get "/api/ios/widgets/list/#{list.id}", headers: headers

    expect(response.parsed_body).to include("name" => "Groceries", "items" => [hash_including("name" => "Milk")])
  end

  it "shows a panel a Jil task wrote, with its SVG as a PNG url", :aggregate_failures do
    allow(AppWidgetReloadWorker).to receive(:perform_in)
    token
    Jil::Executor.call(
      user,
      <<~JIL,
        panel = Widget.set("Garage Door", {
          kTitle = Keyval.new("title", "Garage")::Keyval
          kSvg = Keyval.new("svg", "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='red'/></svg>")::Keyval
        })::Hash
      JIL
    )

    get "/api/ios/widgets/panels/garage_door", headers: headers
    expect(response.parsed_body).to include("title" => "Garage", "key" => "garage_door")
    expect(response.parsed_body["svg_image_url"]).to include("/api/ios/widgets/panels/garage_door/svg.png?v=")
    expect(AppWidgetReloadWorker).to have_received(:perform_in).with(5.seconds, user.id)
  end

  it "rasterizes a panel's SVG" do
    user.app_panels.create!(key: "dot", content: { svg: "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10'/></svg>" })

    get "/api/ios/widgets/panels/dot/svg.png", params: { width: 40 }, headers: headers

    expect(response.media_type).to eq("image/png")
  end

  it "keeps a merge to the keys it names" do
    allow(AppWidgetReloadWorker).to receive(:perform_in)
    user.app_panels.create!(key: "door", content: { title: "Door", value: "Closed" })
    Jil::Executor.call(
      user,
      <<~JIL,
        panel = Widget.merge("door", {
          kValue = Keyval.new("value", "Open")::Keyval
        })::Hash
      JIL
    )

    expect(user.app_panels.find_by(key: "door").content).to eq("title" => "Door", "value" => "Open")
  end

  describe "the agenda" do
    let(:agenda) { create(:agenda, user: user) }

    def titles(query={})
      get "/api/ios/widgets/agenda", params: query, headers: headers
      response.parsed_body["items"].pluck("title")
    end

    it "filters with the agenda page's search, recurring occurrences included" do
      later = 2.hours.from_now
      create(:agenda_item, agenda: agenda, name: "Standup", kind: :event, start_at: later, end_at: later + 15.minutes)
      create(:agenda_item, agenda: agenda, name: "Lunch", kind: :event, start_at: later, end_at: later + 1.hour)
      create(:agenda_item, agenda: agenda, name: "Pay rent", kind: :task, start_at: later)
      tomorrow = Time.current.in_time_zone(user.timezone).to_date + 1
      create(:agenda_schedule, agenda: agenda, name: "Water plants", kind: :task, starts_on: tomorrow)

      expect(titles(q: "is:event -name:lunch", days: 3)).to eq(["Standup"])
      expect(titles(q: "plants", days: 3)).to eq(["Water plants", "Water plants"])
      expect(titles(days: 1)).to contain_exactly("Standup", "Lunch", "Pay rent")
    end

    it "leaves out what the agenda page hides and what's already over" do
      hidden = create(:agenda, user: user)
      create(:agenda_item, agenda: hidden, name: "Hidden thing", start_at: 1.hour.from_now)
      create(:agenda_item, agenda: agenda, name: "Done already", kind: :event, start_at: 3.hours.ago, end_at: 2.hours.ago)
      create(:agenda_item, agenda: agenda, name: "Still coming", start_at: 1.hour.from_now)
      AgendaPreference.for(user).update!(hidden_agenda_ids: [hidden.id])

      expect(titles(days: 1)).to eq(["Still coming"])
    end
  end
end
