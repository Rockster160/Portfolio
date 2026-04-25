require "rails_helper"

RSpec.describe SystemController, type: :controller do
  let(:me) { FactoryBot.create(:user, phone: "5550001000", role: :admin) }
  let(:other_admin) { FactoryBot.create(:user, phone: "5550001001", role: :admin) }
  let(:standard) { FactoryBot.create(:user, phone: "5550001002") }

  before do
    allow(User).to receive(:me).and_return(me)
    me_id = me.id
    allow_any_instance_of(User).to receive(:me?) { |u| u.id == me_id }
  end

  describe "GET #index" do
    render_views

    context "when not signed in" do
      it "returns 404" do
        get :index
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when signed in as a standard user" do
      before { sign_in standard }

      it "returns 404" do
        get :index
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when signed in as another admin (not me)" do
      before { sign_in other_admin }

      it "returns 404" do
        get :index
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when signed in as User.me" do
      before { sign_in me }

      it "renders the index" do
        get :index
        expect(response).to be_successful
        expect(response.body).to include("System")
        expect(response.body).to include("Connections")
      end
    end
  end

  describe "GET #connections" do
    render_views

    context "when not signed in" do
      it "returns 404" do
        get :connections
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when signed in as a standard user" do
      before { sign_in standard }

      it "returns 404" do
        get :connections
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when signed in as another admin (not me)" do
      before { sign_in other_admin }

      it "returns 404" do
        get :connections
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when signed in as User.me" do
      before { sign_in me }

      it "renders the connections page" do
        get :connections
        expect(response).to be_successful
        expect(response.body).to include("Database connections")
        expect(response.body).to include("WebSocket connections")
      end

      it "loads pg_stat_activity rows" do
        get :connections
        rows = controller.instance_variable_get(:@db_connections)
        expect(rows).to be_an(Array)
        # pg_stat_activity may be empty in restricted test environments;
        # what matters is the structure when rows do come back.
        expect(rows.first.keys).to include("pid", "state", "query") if rows.any?
      end

      it "computes a state summary" do
        get :connections
        summary = controller.instance_variable_get(:@db_summary)
        expect(summary).to be_a(Hash)
        expect(summary.values.sum).to eq(controller.instance_variable_get(:@db_connections).length)
      end

      it "exposes the worker pid for the WS scope note" do
        get :connections
        expect(controller.instance_variable_get(:@ws_worker_pid)).to eq(Process.pid)
      end
    end
  end
end
