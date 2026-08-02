require "rails_helper"

# Byte's page and the chips on its hero have to agree about who's allowed in.
# They didn't: ByteController let Eve open the page, while quick actions,
# timers, and routines each carried their own copy of the rule that still only
# named Rocco and Chelsea. She got the full row of buttons and a 403 from every
# one of them - including Stash, which was her only way to hand Suki anything
# to hold.
RSpec.describe "Byte hero access" do
  let(:eve)      { create(:user, id: 4) }
  let(:stranger) { create(:user) }

  describe Buddy::QuickActionsController, type: :controller do
    let!(:convo) { eve.byte_conversations.create!(mode: :buddy) }

    it "lets someone who can open Byte arm the stash" do
      sign_in eve

      post :create, params: { kind: :stash, category: :home, conversation_id: convo.id }

      expect(response).to be_successful
      expect(Buddy::Stash.armed_category(convo.reload)).to eq("home")
    end

    it "still refuses anyone who can't open Byte at all" do
      sign_in stranger

      post :create, params: { kind: :stash, category: :home, conversation_id: convo.id }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe Buddy::RoutinesController, type: :controller do
    it "lets someone who can open Byte read their routines" do
      sign_in eve

      get :index

      expect(response).to be_successful
    end

    it "still refuses anyone who can't open Byte at all" do
      sign_in stranger

      get :index

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe Buddy::TimersController, type: :controller do
    it "lets someone who can open Byte read their timers" do
      sign_in eve

      get :index

      expect(response).to be_successful
    end

    it "still refuses anyone who can't open Byte at all" do
      sign_in stranger

      get :index

      expect(response).to have_http_status(:forbidden)
    end
  end
end
