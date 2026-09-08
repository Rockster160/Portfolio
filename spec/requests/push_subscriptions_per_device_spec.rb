require "rails_helper"

# A push subscription belongs to a DEVICE. The endpoint is what identifies it —
# it's the address the push service delivers to — so one row per (user, channel,
# endpoint) is the only shape that lets a phone and a desktop both be subscribed
# at once.
#
# This used to be one row per (user, channel), with the endpoint overwritten on
# every sync. WebPushNotifications.send_to had already been changed to fan a push
# out to every registered subscription on the channel, and that fan-out could
# never reach more than one device, because there was never more than one row.
# The two devices took turns: opening Byte on the desktop pointed the row at the
# desktop and the phone went quiet, until the phone was opened and evicted the
# desktop in its turn. Re-subscribing on open — which Byte already does on every
# visibilitychange — could not fix it, because each device was undoing the other.
RSpec.describe "Push subscription registration", type: :request do
  let(:user) { create(:user) }

  let(:phone)   { "https://web.push.apple.com/PHONE-ENDPOINT" }
  let(:desktop) { "https://fcm.googleapis.com/fcm/send/DESKTOP-ENDPOINT" }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def subscribe(endpoint, channel: "byte", device_id: nil)
    body = { endpoint: endpoint, channel: channel, keys: { auth: "a-#{endpoint}", p256dh: "p-#{endpoint}" } }
    body[:device_id] = device_id if device_id

    post "/push_notification_subscribe",
      params:  body.to_json,
      headers: { "Content-Type" => "application/json", "JarvisPushVersion" => "2" }
  end

  def unsubscribe(endpoint, channel: "byte")
    post "/push_notification_unsubscribe",
      params:  { endpoint: endpoint, channel: channel }.to_json,
      headers: { "Content-Type" => "application/json" }
  end

  def byte_subs = user.push_subs.for_channel(:byte)

  describe "two devices on one channel" do
    it "keeps a row for each instead of one overwriting the other" do
      subscribe(phone)
      subscribe(desktop)

      expect(byte_subs.pluck(:endpoint)).to contain_exactly(phone, desktop)
    end

    it "leaves both registered, so a push reaches both" do
      subscribe(phone)
      subscribe(desktop)

      expect(user.all_push_subs_for_channel(:byte).pluck(:endpoint)).to contain_exactly(phone, desktop)
    end

    # The symptom: the phone opens Byte, everything works, then the desktop is
    # opened and the phone silently stops receiving anything.
    it "doesn't take the phone off the list when the desktop opens" do
      subscribe(phone)
      subscribe(desktop)

      expect(byte_subs.find_by(endpoint: phone).registered_at).to be_present
    end

    it "re-registering the same device updates its row rather than adding one" do
      subscribe(phone)
      original = byte_subs.sole
      travel_to(1.hour.from_now) { subscribe(phone) }

      expect(byte_subs.sole.id).to eq(original.id)
      expect(byte_subs.sole.registered_at).to be > original.registered_at
    end

    it "keeps channels apart" do
      subscribe(phone)
      subscribe(phone, channel: "whisper")

      expect(byte_subs.pluck(:endpoint)).to eq([phone])
      expect(user.push_subs.for_channel(:whisper).pluck(:endpoint)).to eq([phone])
    end
  end

  describe "turning them off" do
    before do
      subscribe(phone)
      subscribe(desktop)
    end

    # Tapping the bell off is a decision about the device in your hand.
    it "retires only the device that asked" do
      unsubscribe(desktop)

      expect(byte_subs.find_by(endpoint: desktop).registered_at).to be_nil
      expect(byte_subs.find_by(endpoint: phone).registered_at).to be_present
    end

    it "leaves both alone when it can't tell which device it is" do
      unsubscribe("")

      expect(user.all_push_subs_for_channel(:byte).count).to eq(2)
    end
  end

  # The endpoint is the device's ADDRESS, not its name. iOS revokes a push
  # subscription whenever a push arrives that shows no notification, and the
  # device comes back with a fresh endpoint — so keyed on the endpoint alone,
  # one phone filed itself as a new device every few hours. Twenty-one live rows
  # accumulated for one person across three real devices, and since the fan-out
  # is serial, the eighteen dead addresses were eighteen timeouts standing in
  # front of the live one.
  describe "a device whose endpoint was re-issued" do
    let(:phone_id) { "device-abcdef" }

    it "keeps one row and moves it to the new address" do
      subscribe(phone, device_id: phone_id)
      subscribe("#{phone}-REISSUED", device_id: phone_id)

      expect(byte_subs.sole.endpoint).to eq("#{phone}-REISSUED")
    end

    it "still tells two devices apart" do
      subscribe(phone, device_id: phone_id)
      subscribe(desktop, device_id: "device-123456")

      expect(byte_subs.pluck(:endpoint)).to contain_exactly(phone, desktop)
    end

    # The same install subscribes to more than one channel from the same origin
    # (Jarvis, Agenda, Timers and Chores all share the apex), and each channel
    # is its own subscription.
    it "keeps one row per channel for the same device" do
      subscribe(phone, device_id: phone_id)
      subscribe(phone, channel: "whisper", device_id: phone_id)

      expect(byte_subs.sole.channel).to eq("byte")
      expect(user.push_subs.for_channel(:whisper).sole.channel).to eq("whisper")
    end

    # Everything already in the table predates this, and a device that has not
    # been re-issued is still findable the old way.
    it "adopts the row an older client left behind, rather than duplicating it" do
      subscribe(phone)
      original = byte_subs.sole

      subscribe(phone, device_id: phone_id)

      expect(byte_subs.sole.id).to eq(original.id)
      expect(byte_subs.sole.device_id).to eq(phone_id)
    end

    it "retires the device that asked, by name" do
      subscribe(phone, device_id: phone_id)
      subscribe(desktop, device_id: "device-123456")

      post "/push_notification_unsubscribe",
        params:  { device_id: phone_id, channel: "byte" }.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(byte_subs.find_by(endpoint: phone).registered_at).to be_nil
      expect(byte_subs.find_by(endpoint: desktop).registered_at).to be_present
    end
  end

  # `PushSubscription#toJSON` nests the keys and most of the PWAs post that
  # straight through, but the Timers PWA builds its body by hand and sends them
  # flat. That raised NoMethodError on nil and 500'd every attempt, which is why
  # the timers channel has never held a single row.
  it "accepts keys sent flat rather than nested" do
    post "/push_notification_subscribe",
      params:  { endpoint: phone, channel: "timers", auth: "a", p256dh: "p" }.to_json,
      headers: { "Content-Type" => "application/json", "JarvisPushVersion" => "2" }

    expect(response).to have_http_status(:ok)
    expect(user.push_subs.for_channel(:timers).sole).to be_pushable
  end

  # Nothing can be delivered to it, and a second blank one would find this row
  # and overwrite it.
  it "refuses a subscription with no endpoint" do
    subscribe("")

    expect(response).to have_http_status(:bad_request)
    expect(byte_subs).to be_empty
  end
end
