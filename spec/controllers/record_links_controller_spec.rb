require "rails_helper"

# The links manager. Its reason to exist is that a pairing used to be a Hash
# literal inside a Jil task — invisible unless you opened the editor — and a
# BROKEN one was invisible full stop, since a link that matches nothing looks
# exactly like one whose condition hasn't happened yet.
#
# It then spent a while as a read-only panel in Byte's drawer, which could show
# them but not make one. Creating is the point of this page.
RSpec.describe RecordLinksController, type: :controller do
  render_views

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
    it "shows each pairing with the whole rule in a sentence" do
      link!

      get :index

      expect(response.body).to include("completes chore &quot;Coffee Run&quot;")
    end

    it "flags an end pointing at a chore nobody has" do
      link!(target_name: "Ghost Chore")

      get :index

      expect(response.body).to include("no chore called")
      expect(response.body).to include("Ghost Chore")
    end

    it "flags an end pointing at a list nobody has" do
      link!(
        source_kind: :chore, source_name: "Coffee Run", target_kind: :list_item,
        target_name: "Beans", target_scope: "No Such List"
      )

      get :index

      expect(response.body).to include("no list called")
    end

    it "shows disabled ones too — off is a state, not a deletion" do
      link!(enabled: false)

      get :index

      expect(response.body).to include("is-off")
    end

    # Typing a chore that doesn't exist is the one way to make a link that
    # silently never runs, so the form offers the real names.
    it "offers the household's chore names for the form to complete against" do
      get :index

      expect(response.body).to include(%(<option value="Coffee Run">))
    end

    it "turns away someone who isn't signed in" do
      session[:current_user_id] = nil
      cookies.delete(:current_user_id)

      get :index

      expect(response).to redirect_to(login_path)
    end
  end

  describe "POST #create" do
    def create!(**params)
      post :create, params: {
        source_kind: :event,
        source_name: "Coffee",
        target_kind: :chore,
        target_name: "Coffee Run",
      }.merge(params)
    end

    it "makes the pairing" do
      expect { create! }.to change(RecordLink, :count).by(1)
      expect(RecordLink.last).to have_attributes(source_name: "Coffee", target_name: "Coffee Run")
    end

    it "belongs to whoever made it" do
      create!
      expect(RecordLink.last.user_id).to eq(user.id)
    end

    it "keeps a looser match when one is asked for" do
      create!(source_name_match: "contains")
      expect(RecordLink.last.source_name_match).to eq("contains")
    end

    it "falls back to an exact match rather than blowing up on a bad mode" do
      create!(source_name_match: "vibes")
      expect(RecordLink.last.source_name_match).to eq("exactly")
    end

    # The cascade runs event -> chore -> agenda -> list item, and only that way.
    it "refuses an uphill pairing and says why" do
      expect { create!(source_kind: :chore, target_kind: :event, target_name: "Coffee") }
        .not_to change(RecordLink, :count)
      expect(response.body).to include("must come after")
    end

    it "re-renders with the errors rather than losing what was typed" do
      create!(source_name: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("record-link-errors")
    end

    # The fields hide and show as the kinds change, so a note typed against an
    # event source is still in the payload after switching that source to a
    # chore — and a scope on the wrong kind is a validation error about a field
    # no longer on screen.
    it "drops a note that no longer belongs once the source isn't an event" do
      create!(
        source_kind: :chore, source_name: "Coffee Run", source_scope: "leftover",
        target_kind: :agenda, target_name: "Coffee"
      )

      expect(RecordLink.last.source_scope).to be_nil
    end

    it "drops ask_who when the target isn't a chore" do
      create!(
        source_kind: :chore, source_name: "Coffee Run", target_kind: :agenda,
        target_name: "Coffee", ask_who: "1"
      )

      expect(RecordLink.last.ask_who).to be(false)
    end

    it "keeps ask_who on a chore target" do
      create!(ask_who: "1")
      expect(RecordLink.last.ask_who).to be(true)
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
