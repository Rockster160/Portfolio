require "rails_helper"

RSpec.describe ByteController, type: :controller do
  let(:rocco) { User.me }
  let(:convo) { rocco.byte_conversations.create!(name: :Buddy, mode: :buddy) }

  before {
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(FeatureBuildStartWorker).to receive(:perform_async)
  }

  describe "/feature" do
    it "keeps the request as their message, above the one that follows the build" do
      sign_in rocco

      post :create_message, params: {
        conversation_id: convo.id,
        body:            "/feature add build buttons on the requests page",
        local_id:        "local-1",
      }

      build = FeatureBuild.last
      request, status = convo.byte_messages.order(:id).to_a
      expect(build.request).to eq("build buttons on the requests page")
      expect(build.byte_conversation).to eq(convo)
      expect(request).to be_outbound
      expect(request.body).to eq("/feature add build buttons on the requests page")
      expect(request.metadata).to include("feature_build_id" => build.id, "local_id" => "local-1")
      expect(status).to eq(build.byte_message)
      expect(status.body).to include("Starting a Feature Builder", "build buttons on the requests page")
      expect(response.parsed_body["id"]).to eq(request.id)
      expect(FeatureBuildStartWorker).to have_received(:perform_async).with(build.id)
    end

    it "starts the build with the images sent alongside the command, and shows them on the request" do
      sign_in rocco
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("png"), filename: "mock.png", content_type: "image/png",
      )

      post :create_message, params: {
        conversation_id:       convo.id,
        body:                  "/feature add match this layout",
        attachment_signed_ids: [blob.signed_id],
      }

      build = FeatureBuild.last
      expect(build.images.map(&:blob)).to eq([blob])
      expect(build.byte_message.body).to include("with 1 image")
      expect(convo.byte_messages.find_by(direction: :outbound).files.map(&:blob)).to eq([blob])
    end

    it "takes the request without the `add`, and explains itself when there isn't one" do
      sign_in rocco

      post :create_message, params: { conversation_id: convo.id, body: "/feature dark mode" }
      post :create_message, params: { conversation_id: convo.id, body: "/feature" }

      expect(FeatureBuild.pluck(:request)).to eq(["dark mode"])
      expect(convo.byte_messages.order(:id).last.body).to include("usage")
    end

    it "is the owner's alone" do
      chelsea = create(:user, id: 58_128)
      thread = chelsea.byte_conversations.create!(name: :Buddy, mode: :buddy)
      sign_in chelsea

      post :create_message, params: { conversation_id: thread.id, body: "/feature add something" }

      expect(FeatureBuild.count).to eq(0)
    end
  end

  describe "/audit" do
    it "starts an audit build with the note as its focus, under their message" do
      sign_in rocco

      post :create_message, params: {
        conversation_id: convo.id,
        body:            "/audit reminders keep firing twice",
        local_id:        "local-2",
      }

      build = FeatureBuild.last
      request, status = convo.byte_messages.order(:id).to_a
      expect(build).to be_kind_audit
      expect(build.title).to eq("Audit: reminders keep firing twice")
      expect(build.request).to include("**reminders keep firing twice**", "WHERE THE DAY IS")
      expect(request.body).to eq("/audit reminders keep firing twice")
      expect(request.metadata).to include("feature_build_id" => build.id, "local_id" => "local-2")
      expect(status.body).to include("Starting an audit on the Mini")
      expect(FeatureBuildStartWorker).to have_received(:perform_async).with(build.id)
    end

    it "runs without a note" do
      sign_in rocco

      post :create_message, params: { conversation_id: convo.id, body: "/audit" }

      expect(FeatureBuild.last.title).to eq("Audit of the last 24 hours")
      expect(FeatureBuild.last.request).to include("judge for yourself")
    end

    it "is the owner's alone" do
      chelsea = create(:user, id: 58_128)
      thread = chelsea.byte_conversations.create!(name: :Buddy, mode: :buddy)
      sign_in chelsea

      post :create_message, params: { conversation_id: thread.id, body: "/audit" }

      expect(FeatureBuild.count).to eq(0)
    end
  end
end
