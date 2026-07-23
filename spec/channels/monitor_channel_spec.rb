require "rails_helper"

RSpec.describe MonitorChannel, type: :channel do
  let(:user) { User.me }

  before do
    stub_connection(current_user: user)
    # Skip the `subscribed` :startup branch — we are exercising the
    # action methods, not the connect-time SHA bookkeeping.
    allow(user).to receive(:me?).and_return(false)
    allow(::Jil).to receive(:trigger)
    subscribe
  end

  # The Task listener fast-path at app/models/task.rb:307 only matches
  # `monitor::<name>` listeners when trigger_data[:channel] is present.
  # Quick-actions widgets only send `{id}`, so the channel must default
  # from id server-side or every resync/refresh/execute silently misses.
  describe "channel defaulting from id" do
    %i[execute refresh resync].each do |action|
      it "fills channel from id when #{action} action arrives without channel" do
        perform action, { "id" => "garage" }

        expect(::Jil).to have_received(:trigger).with(
          user,
          :monitor,
          hash_including(id: "garage", channel: "garage", action => true),
          hash_including(auth: :userpass)
        )
      end

      it "preserves explicit channel when #{action} action provides one" do
        perform action, { "id" => "garage", "channel" => "garage-zone-2" }

        expect(::Jil).to have_received(:trigger).with(
          user,
          :monitor,
          hash_including(id: "garage", channel: "garage-zone-2", action => true),
          hash_including(auth: :userpass)
        )
      end
    end
  end

  describe "whisper page auto-refresh on subscribe" do
    let(:eve) { FactoryBot.create(:user) }

    it "kicks a whisper-durations refresh when the client subscribes from /whisper" do
      stub_connection(current_user: eve)
      allow(::Jil).to receive(:trigger)

      subscribe(page: "/whisper")

      expect(::Jil).to have_received(:trigger).with(
        User.me,
        :monitor,
        hash_including(channel: "whisper-durations", refresh: true),
        hash_including(auth: :userpass, auth_id: eve.id)
      )
    end

    it "does not kick a whisper refresh when the page is not /whisper" do
      stub_connection(current_user: eve)
      allow(::Jil).to receive(:trigger)

      subscribe(page: "/lists")

      expect(::Jil).not_to have_received(:trigger)
    end
  end
end
