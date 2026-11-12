require "rails_helper"

RSpec.describe ByteController, type: :controller do
  let(:rocco) { User.me }
  let(:convo) { rocco.byte_conversations.create!(name: :Buddy, mode: :buddy) }

  before {
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(FeatureBuildStartWorker).to receive(:perform_async)
  }

  describe "/feature" do
    it "starts a build and answers with the one message that will follow it" do
      sign_in rocco

      post :create_message, params: { conversation_id: convo.id, body: "/feature add build buttons on the requests page" }

      build = FeatureBuild.last
      expect(build.request).to eq("build buttons on the requests page")
      expect(build.byte_conversation).to eq(convo)
      expect(convo.byte_messages.count).to eq(1)
      expect(build.byte_message.body).to include("Starting a Feature Builder", "build buttons on the requests page")
      expect(FeatureBuildStartWorker).to have_received(:perform_async).with(build.id)
    end

    it "starts the build with the images sent alongside the command" do
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
end
