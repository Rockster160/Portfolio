require "rails_helper"

# The links manager: lists, creates and edits pairings, and flags a BROKEN one,
# since a link that matches nothing looks exactly like one whose condition
# hasn't happened yet.
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
    def rows
      Nokogiri::HTML(response.body).css("li.record-link-row")
    end

    # Off is a state, not a deletion. Typing a chore that doesn't exist is the
    # one way to make a link that silently never runs, so the form offers the
    # real names.
    it "lists a healthy pairing, a disabled one, and offers the chore names", :aggregate_failures do
      link!
      link!(source_name: "Tea", enabled: false)

      get :index

      expect(rows.size).to eq(2)
      expect(rows.count { |r| r["class"].include?("is-off") }).to eq(1)
      expect(rows.none? { |r| r["class"].include?("is-broken") }).to be(true)
      expect(response.body).to include(%(<option value="Coffee Run">))
    end

    it "flags an end pointing at a chore or a list nobody has" do
      link!(target_name: "Ghost Chore")
      link!(
        source_kind: :chore, source_name: "Coffee Run", target_kind: :list_item,
        target_name: "Beans", target_scope: "No Such List"
      )

      get :index

      expect(rows.map { |r| r["class"].include?("is-broken") }).to eq([true, true])
      expect(response.body).to include("Ghost Chore")
    end

    it "turns away someone who isn't signed in" do
      session[:current_user_id] = nil
      cookies.delete(:current_user_id)

      get :index

      expect(response).to redirect_to(playground_project_path(PlaygroundProject.find(:chores)))
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

    it "makes the pairing, owned by whoever made it" do
      expect { create! }.to change(RecordLink, :count).by(1)
      expect(RecordLink.last).to have_attributes(source_name: "Coffee", target_name: "Coffee Run", user_id: user.id)
    end

    it "keeps a looser match when asked, falling back to exact on a bad mode" do
      [["contains", "contains"], ["vibes", "exactly"]].each do |mode, stored|
        create!(source_name: "Coffee #{mode}", source_name_match: mode)
        expect(RecordLink.last.source_name_match).to eq(stored)
      end
    end

    # The cascade runs event -> chore -> agenda -> list item, and only that way.
    it "refuses an uphill pairing" do
      expect { create!(source_kind: :chore, target_kind: :event, target_name: "Coffee") }.not_to change(RecordLink, :count)
      expect(response).to have_http_status(:unprocessable_entity)
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

    it "loosens the match, ignoring a mode it doesn't recognise" do
      link = link!

      patch :update, params: { id: link.id, source_name_match: "vibes" }
      expect(link.reload.source_name_match).to eq("exactly")

      patch :update, params: { id: link.id, source_name_match: "contains" }
      expect(link.reload.source_name_match).to eq("contains")
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
      expect(response.parsed_body["errors"]).to be_present
      expect(link.reload.source_name).to eq("Coffee")
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
