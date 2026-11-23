require "rails_helper"

RSpec.describe "Buddy app submissions", type: :request do
  let(:user) { User.me }
  let(:device_and_token) { AppDevice.issue!(user, name: "Phone", features: ["battery", "health"]) }
  let(:device) { device_and_token.first }
  let(:headers) { { "Authorization" => "Bearer #{device_and_token.last}" } }

  before do
    allow(Jil).to receive(:trigger).and_call_original
    allow(WebPushNotifications).to receive(:send_to)
  end

  def submit(**body)
    post "/api/ios/submissions", params: { id: SecureRandom.uuid, source: "test", **body }, headers: headers, as: :json
  end

  describe "a command" do
    it "runs once with the time it was pressed, however many times it arrives", :aggregate_failures do
      allow(Jarvis).to receive(:command).and_return("Logged Water")
      id = SecureRandom.uuid
      pressed = "2026-11-20T07:02:00.000-07:00"

      2.times {
        post "/api/ios/submissions", params: {
          id: id, kind: "command", text: "Log Water", pressed_at: pressed
        }, headers: headers, as: :json
      }

      expect(Jarvis).to have_received(:command).once.with(user, "Log Water", at: Time.zone.parse(pressed))
      expect(response.parsed_body).to include("duplicate" => true, "response" => "Logged Water", "status" => "processed")
      expect(AppDeviceSubmission.where(uuid: id).count).to eq(1)
    end

    it "files a log at the press time when the words name none" do
      user.update!(role: :admin)
      submit(kind: "command", text: "Log Water", pressed_at: "2026-11-20T07:02:00-07:00")

      expect(ActionEvent.last).to have_attributes(name: "Water", timestamp: Time.zone.parse("2026-11-20T14:02:00Z"))
    end

    it "lets words that carry a time keep it" do
      submit(kind: "command", text: "Log Coffee at 6am", pressed_at: "2026-11-20T09:00:00-07:00")

      expect(ActionEvent.last.timestamp.in_time_zone(user.timezone).hour).to eq(6)
    end
  end

  describe "a trigger" do
    it "fires the trigger with the press time and device" do
      submit(kind: "trigger", key: "ios_hot_link", data: { name: "Garage" }, pressed_at: "2026-11-20T07:02:00-07:00")

      expect(Jil).to have_received(:trigger).with(
        user, "ios_hot_link", hash_including(name: "Garage", device: "Phone", pressed_at: "2026-11-20T07:02:00-07:00"),
        auth: :trigger, auth_id: user.id
      )
    end

    it "writes the battery where the dashboard reads it" do
      submit(kind: "trigger", key: "ios_battery", data: { device: "phone", level: 42, charging: true })

      expect(user.caches.dig(:battery, :phone)).to include(value: 42, charging: true)
    end

    it "leaves the dashboard alone when the device says not to" do
      device.update!(preferences: { battery_writes_dashboard: false })
      submit(kind: "trigger", key: "ios_battery", data: { level: 42 })

      expect(user.caches.get(:battery)).to be_empty
    end

    it "logs a workout as a Workout event once, however often HealthKit sends it", :aggregate_failures do
      workout = {
        uuid:             "w-1",
        type:             "running",
        started_at:       "2026-11-20T06:00:00-07:00",
        duration_minutes: 31.5,
        calories:         402.4,
        distance_miles:   3.1,
      }
      submit(kind: "trigger", key: "ios_workout", data: workout)
      submit(kind: "trigger", key: "ios_workout", data: workout)

      events = user.action_events.where(name: "Workout")
      expect(events.count).to eq(1)
      expect(events.first.data).to include("Calories" => 402, "Duration" => 31.5, "Distance" => 3.1, "Type" => "running")
    end

    it "fires one trigger per change of a batched contact sync and stores none of them", :aggregate_failures do
      submit(kind: "trigger", key: "ios_contacts", data: {
        action:  "batch",
        changes: [
          { action: "added", contact: { id: "CN-1", name: "Eve", phones: ["(801) 555-0100"] } },
          { action: "added", contact: { id: "CN-2", name: "Kevin", emails: ["k@example.com"] } },
        ],
      })
      submit(kind: "trigger", key: "ios_contacts", data: {
        action: "updated", contact: { id: "CN-1", name: "Eve", nickname: "Evie" }
      })

      expect(user.contacts.where(apple_contact_id: ["CN-1", "CN-2"])).to be_empty
      expect(Jil).to have_received(:trigger).with(user, "ios_contacts", anything, anything).exactly(3).times
    end

    it "saves a shared place as a new contact with its address" do
      submit(kind: "trigger", key: "ios_contacts", data: {
        action: "added", save: true, contact: { name: "Taco Spot", street: "1 Main St", lat: 40.5, lng: -111.9 }
      })

      contact = user.contacts.find_by(name: "Taco Spot")
      expect(contact.addresses.first).to have_attributes(street: "1 Main St", lat: 40.5, lng: -111.9, primary: true)
    end
  end

  describe "a list tick" do
    let(:list) { user.lists.create!(name: "Groceries") }

    it "checks an item and adds a new one", :aggregate_failures do
      item = list.list_items.create!(name: "Milk")

      submit(kind: "list_toggle", key: list.id.to_s, data: { item_id: item.id, checked: true })
      expect(item.reload).to be_deleted

      submit(kind: "list_toggle", key: list.id.to_s, text: "Eggs")
      expect(ListItem.where(list_id: list.id).pluck(:name)).to include("Eggs")
    end

    it "toggles the item a hot link names, adding it when the list doesn't have it", :aggregate_failures do
      item = list.list_items.create!(name: "Milk")

      submit(kind: "list_toggle", key: list.id.to_s, data: { item: "milk" })
      expect(item.reload).to be_deleted

      submit(kind: "list_toggle", key: list.id.to_s, data: { item: "Milk" })
      expect(item.reload).not_to be_deleted

      submit(kind: "list_toggle", key: list.id.to_s, data: { item: "Bread" })
      expect(ListItem.where(list_id: list.id).pluck(:name)).to include("Bread")
    end
  end

  describe "a Live Activity button pressed with no signal" do
    around { |example| Sidekiq::Testing.fake! { example.run } }
    before { allow(AppTimerPushWorker).to receive(:perform_async) }

    it "pauses and cancels the timer once it lands", :aggregate_failures do
      timer = Buddy::Timers.create!(user: user, seconds: 600, label: "Pasta")

      submit(kind: "timer", key: timer.id.to_s, text: "pause")
      expect(timer.reload).to be_paused

      submit(kind: "timer", key: timer.id.to_s, text: "cancel")
      expect(timer.reload.archived_at).to be_present
    end
  end

  describe "an answer" do
    it "answers a prompt from a notification button and completes it", :aggregate_failures do
      prompt = user.prompts.create!(question: "Feeling?", options: [{ type: "choices", question: "Mood", choices: ["Good", "Meh"] }])

      submit(kind: "answer", data: { prompt_id: prompt.id, question: "Mood", value: "Good" })

      expect(prompt.reload.response).to eq("Mood" => "Good")
      expect(Jil).to have_received(:trigger).with(user, :prompt, prompt, anything)
      expect(Jil).to have_received(:trigger).with(user, :ios_notification_action, hash_including(prompt_id: prompt.id), anything)
    end
  end

  describe "a Buddy message" do
    it "goes into the primary conversation and reads back its reply", :aggregate_failures do
      conversation = user.byte_conversations.create!(mode: :buddy, name: "Byte")
      allow(ByteMessageIntake).to(receive(:call).and_wrap_original { |_original, **args|
        conversation.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: args[:body])
      })

      submit(kind: "buddy", text: "hey")
      body = response.parsed_body
      message_id = body["message_id"]
      expect(ByteMessageIntake).to have_received(:call).with(hash_including(conversation: conversation, body: "hey"))

      conversation.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "Hi!", metadata: { in_reply_to: message_id },
      )
      get "/api/ios/submissions/#{body["id"]}", headers: headers
      expect(response.parsed_body["response"]).to eq("Hi!")
    end
  end

  it "refuses an unknown kind without recording it" do
    submit(kind: "teleport")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(AppDeviceSubmission.count).to eq(0)
  end

  it "records a failure on the row instead of raising" do
    submit(kind: "task", key: "999999")

    expect(response.parsed_body).to include("status" => "failed")
  end
end
