require "rails_helper"

# The links panel. Its reason to exist is that a pairing used to be a Hash
# literal inside a Jil task — invisible unless you opened the editor — and a
# BROKEN one was invisible full stop, since a link that matches nothing looks
# exactly like one whose condition hasn't happened yet.
RSpec.describe Buddy::LinksController, type: :controller do
  let(:user)      { User.me }
  let(:household) { user.chore_household }

  def link!(**opts)
    RecordLink.create!({
      user:        user,
      source_kind: :event,
      source_name: "Coffee",
      target_kind: :chore,
      target_name: "Coffee Run",
    }.merge(opts))
  end

  before do
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(MonitorChannel).to receive(:broadcast_to)
    RecordLink.delete_all
    Chore.where(chore_household: household).delete_all
    Chore.create!(chore_household: household, created_by_user: user, name: "Coffee Run")
    sign_in user
  end

  describe "GET #index" do
    it "lists each pairing with the whole rule in a sentence" do
      link!

      get :index

      row = response.parsed_body["links"].first
      expect(row["sentence"]).to include("completes chore \"Coffee Run\"")
      expect(row["source"]["name"]).to eq("Coffee")
      expect(row["target"]["kind"]).to eq("chore")
    end

    it "hands over the cascade order and the match modes so the UI can't drift" do
      get :index

      expect(response.parsed_body["cascade"]).to eq(%w[event chore agenda list_item])
      expect(response.parsed_body["matches"]).to eq(%w[exactly starts_with contains])
    end

    it "flags an end pointing at a chore nobody has" do
      link!(target_name: "Ghost Chore")

      get :index

      expect(response.parsed_body["links"].first["broken"].join).to include("Ghost Chore")
    end

    it "flags an end pointing at a list nobody has" do
      link!(
        source_kind: :chore, source_name: "Coffee Run", target_kind: :list_item,
        target_name: "Beans", target_scope: "No Such List"
      )

      get :index

      expect(response.parsed_body["links"].first["broken"].join).to include("No Such List")
    end

    it "is quiet when both ends resolve" do
      link!

      get :index

      expect(response.parsed_body["links"].first["broken"]).to be_empty
    end

    it "lists disabled ones too — off is a state, not a deletion" do
      link!(enabled: false)

      get :index

      expect(response.parsed_body["links"].first["enabled"]).to be(false)
    end
  end

  describe "PATCH #update" do
    it "turns one off" do
      link = link!

      patch :update, params: { id: link.id, enabled: false }

      expect(link.reload.enabled).to be(false)
    end

    it "loosens the match" do
      link = link!

      patch :update, params: { id: link.id, source_name_match: "contains" }

      expect(link.reload.source_name_match).to eq("contains")
    end

    it "ignores a match mode it doesn't recognise" do
      link = link!

      patch :update, params: { id: link.id, source_name_match: "vibes" }

      expect(link.reload.source_name_match).to eq("exactly")
    end

    it "renames an endpoint" do
      link = link!

      patch :update, params: { id: link.id, source_name: "Cold Brew" }

      expect(link.reload.source_name).to eq("Cold Brew")
    end

    # Flipping a kind would reverse the cascade, and a link pointing the other
    # way is a different link, made deliberately.
    it "refuses to change either kind" do
      link = link!

      patch :update, params: { id: link.id, source_kind: "chore", target_kind: "event" }

      expect(link.reload.source_kind).to eq("event")
      expect(link.reload.target_kind).to eq("chore")
    end

    it "reports a validation failure rather than swallowing it" do
      link = link!

      patch :update, params: { id: link.id, source_name: "" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join).to match(/name/i)
    end

    it "refuses a link that isn't theirs" do
      theirs = RecordLink.create!(
        user: create(:user), source_kind: :event, source_name: "X",
        target_kind: :chore, target_name: "Y"
      )

      patch :update, params: { id: theirs.id, enabled: false }

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.enabled).to be(true)
    end
  end

  describe "DELETE #destroy" do
    it "removes it" do
      link = link!

      expect { delete :destroy, params: { id: link.id } }.to change(RecordLink, :count).by(-1)
    end

    it "refuses a link that isn't theirs" do
      theirs = RecordLink.create!(
        user: create(:user), source_kind: :event, source_name: "X",
        target_kind: :chore, target_name: "Y"
      )

      expect { delete :destroy, params: { id: theirs.id } }.not_to change(RecordLink, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
