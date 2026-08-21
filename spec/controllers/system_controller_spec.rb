require "rails_helper"

RSpec.describe SystemController, type: :controller do
  describe "the controller" do
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

        it "loads the ActiveRecord pool stat for this process" do
          get :connections
          stat = controller.instance_variable_get(:@pool_stat)
          expect(stat).to include(:size, :busy, :idle, :waiting)
          expect(stat[:size]).to be_positive
        end

        it "renders the connection pool panel with the waiting metric" do
          get :connections
          expect(response.body).to include("Connection pool")
          expect(response.body).to include("Waiting")
        end
      end
    end
  end

  describe "feature requests" do
    let(:user) { User.me }
    let(:eve)  { create(:user) }

    before { sign_in user }

    def request!(title, status: :open, seen: false)
      FeatureRequest.create!(
        user: eve, title: title, body: "they wanted #{title}",
        status: status, seen_at: (Time.current if seen)
      )
    end

    describe "GET #feature_requests" do
      render_views

      # The only ones with anything left to decide go first.
      it "lists them, open first" do
        request!("Shipped one", status: :shipped)
        request!("Open one")

        get :feature_requests

        expect(response.body.index("Open one")).to be < response.body.index("Shipped one")
      end

      # Landing on the page IS reading them, so the unread mark can't sit there
      # counting things already looked at.
      it "marks everything seen" do
        request!("Open one")

        expect { get :feature_requests }.to change { FeatureRequest.where(seen_at: nil).count }.to(0)
      end

      it "counts them per status for the header" do
        request!("A")
        request!("B", status: :declined)

        get :feature_requests

        expect(response.body).to include("1 open").and include("1 declined").and include("0 planned")
      end

      it "gives every row a button for every status" do
        request!("Open one")

        get :feature_requests

        FeatureRequest.statuses.each_key { |status| expect(response.body).to include(%(data-fr-set="#{status}")) }
      end

      it "says so plainly when there's nothing on the list" do
        get :feature_requests

        expect(response.body).to include("Nothing on the list")
      end
    end

    describe "PATCH #update_feature_request" do
      it "marks one resolved" do
        row = request!("Open one")

        patch :update_feature_request, params: { id: row.id, status: :shipped }

        expect(response).to be_successful
        expect(row.reload).to be_status_shipped
      end

      # The row can go back as readily as forward — a decision made here is as
      # reversible as one made anywhere else.
      it "moves one back to open" do
        row = request!("Declined one", status: :declined)

        patch :update_feature_request, params: { id: row.id, status: :open }

        expect(row.reload).to be_status_open
      end

      it "hands back the new count so the blip can follow" do
        request!("Still open")
        row = request!("Closing this")

        patch :update_feature_request, params: { id: row.id, status: :shipped }

        expect(response.parsed_body["open"]).to eq(1)
      end

      it "refuses a status that isn't one" do
        row = request!("Open one")

        patch :update_feature_request, params: { id: row.id, status: "sideways" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(row.reload).to be_status_open
      end
    end

    describe "the System index" do
      render_views

      it "shows the link with a blip for what's still open" do
        request!("One")
        request!("Two")
        request!("Three", status: :shipped)

        get :index

        expect(response.body).to include("Feature Requests")
        expect(response.body).to match(/system-card-blip">\s*2\s*</)
      end

      # Two different questions: the blip is what needs deciding, the unread mark
      # is whether the page has been looked at since one landed.
      it "marks the card unread while any are unseen" do
        request!("One")

        get :index

        expect(response.body).to include("system-card unread")
      end

      it "drops the unread mark once they've been looked at" do
        request!("One", seen: true)

        get :index

        expect(response.body).not_to include("system-card unread")
      end

      it "shows no blip when nothing is open" do
        request!("One", status: :shipped, seen: true)

        get :index

        # The class name is in the stylesheet either way; the SPAN is the blip.
        expect(response.body).not_to include(%(<span class="system-card-blip">))
      end
    end
  end

  describe "gpt spending" do
    render_views

    let(:me) { User.me }

    # The JSON payload the Chart.js init reads.
    def chart_payload
      blob = response.body[%r{<script id="spend-data"[^>]*>(.+?)</script>}m, 1]
      JSON.parse(blob)
    end

    describe "GET #gpt_spending" do
      # Every bucket here is derived from the wall clock in America/Denver, and
      # the labels are what the assertions read. Pinned to a mid-afternoon instant
      # where UTC and Denver agree on the date, so nothing shifts by a day
      # depending on when the suite runs.
      around { |example| travel_to(Time.utc(2026, 5, 14, 21, 30)) { example.run } }

      before { sign_in me }

      it "buckets spend by local day and by user, defaulting to a 30-day window" do
        tz = ActiveSupport::TimeZone["America/Denver"]
        other = create(:user, username: "alex")
        convo = ByteConversation.create!(user: me, mode: :buddy, name: "Buddy")

        BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4-mini", cost_micros: 1_500)
        BuddyUsage.create!(user: other, byte_conversation: convo, model: "gpt-5.4", cost_micros: 4_000)
        old = BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4-mini", cost_micros: 900)
        old.update_column(:created_at, 3.days.ago)

        get :gpt_spending
        expect(response).to have_http_status(:ok)

        payload = chart_payload
        expect(payload["labels"].length).to eq(30)
        expect(payload["labels"].last).to eq(tz.today.strftime("%b %-d"))

        # Users ranked by spend desc; totals rendered in the legend. `me` (id 1)
        # renders as its friendly first name; `alex` falls back to its username.
        users = payload["datasets"].map { |d| d["label"] }
        expect(users).to eq(["alex", "Rocco"])
        expect(response.body).to include("$0.0064") # total, last 30 days
        expect(response.body).to include("3</div>")  # api call count

        rocco = payload["datasets"].find { |d| d["label"] == "Rocco" }
        today_i = payload["labels"].index(tz.today.strftime("%b %-d"))
        old_i = payload["labels"].index(3.days.ago.in_time_zone(tz).to_date.strftime("%b %-d"))
        expect(rocco["data"][today_i]).to eq(0.0015)
        expect(rocco["data"][old_i]).to eq(0.0009)

        # The call-count line runs across every bucket, counting all users' calls
        # in each — two today, one three days back.
        expect(payload["calls"].length).to eq(30)
        expect(payload["calls"][today_i]).to eq(2)
        expect(payload["calls"][old_i]).to eq(1)
        expect(payload["calls"].sum).to eq(3)
      end

      it "honors an allowed window and ignores a bogus one" do
        get :gpt_spending, params: { days: 7 }
        expect(chart_payload["labels"].length).to eq(7)

        get :gpt_spending, params: { days: 999 }
        expect(chart_payload["labels"].length).to eq(30)
      end

      it "buckets the last 24 hours by the hour for the 1-day window" do
        tz = ActiveSupport::TimeZone["America/Denver"]
        convo = ByteConversation.create!(user: me, mode: :buddy, name: "Buddy")

        two_pm = BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4-mini", cost_micros: 2_000)
        two_pm.update_column(:created_at, (tz.now.beginning_of_day + 14.hours).utc)

        get :gpt_spending, params: { days: 1 }
        expect(response).to have_http_status(:ok)

        payload = chart_payload
        expect(payload["labels"].length).to eq(24)
        # A ROLLING 24 hours ending at the current hour (3:30 PM local here), not
        # a midnight-anchored day.
        expect(payload["labels"].first).to eq("4 PM")
        expect(payload["labels"].last).to eq("3 PM")
        expect(payload["labels"]).to include("2 PM")
        expect(response.body).to include("Total, last 24h")
        expect(response.body).to include("Per hour (avg)")

        rocco = payload["datasets"].find { |d| d["label"] == "Rocco" }
        two_pm_i = payload["labels"].index("2 PM")
        expect(rocco["data"][two_pm_i]).to eq(0.002)
        expect(rocco["data"].sum).to eq(0.002) # nothing outside 2 PM

        expect(payload["calls"].length).to eq(24)
        expect(payload["calls"][two_pm_i]).to eq(1)
        expect(payload["calls"].sum).to eq(1)
      end

      it "renders empty gracefully with no usage" do
        get :gpt_spending
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No GPT spending recorded")
        expect(chart_payload["datasets"]).to be_empty
      end
    end

    describe "access" do
      it "is not found for non-me users" do
        sign_in create(:user)
        get :gpt_spending
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Curating what the companions have kept. Deliberately outside Byte: a companion
  # that offers to manage its own memory in the chat is a companion spending the
  # conversation on bookkeeping.
  describe "memories" do
    render_views

    let(:me)    { FactoryBot.create(:user, phone: "5550004000", role: :admin) }
    let(:other) { FactoryBot.create(:user, phone: "5550004001") }

    before do
      allow(User).to receive(:me).and_return(me)
      me_id = me.id
      allow_any_instance_of(User).to receive(:me?) { |u| u.id == me_id }
      sign_in(me)
    end

    let!(:preference) {
      me.buddy_memories.create!(kind: :preference, content: "Drinks oat milk lattes.", severity: 5, tags: %w[food])
    }
    let!(:followup) {
      me.buddy_memories.create!(
        kind: :followup, content: "Their cat is in hospital.", severity: 70,
        tags: %w[pets health], check_in_at: 2.days.from_now,
      )
    }
    let!(:theirs) {
      other.buddy_memories.create!(kind: :concept, content: "Their own private thing.", severity: 20)
    }

    describe "GET #memories" do
      it "lists everything the companions are holding, weightiest first" do
        get(:memories)

        expect(response).to have_http_status(:ok)
        # Weightiest first: the cat (70) above the latte preference (5).
        expect(response.body.index("cat is in hospital")).to be < response.body.index("oat milk lattes")
        expect(response.body).to include("Their own private thing.", "3 total")
      end

      # The id is the reason to open this page rather than the app: it's what
      # goes into a script or a query afterwards.
      it "shows each memory's id" do
        get(:memories)

        expect(response.body).to include("##{followup.id}")
      end

      # A bare number says nothing about what it counts or which way is worse,
      # and a bare date can't say whether it's when the memory was written, last
      # read, or about to go away.
      it "labels both numbers and every date" do
        get(:memories)

        expect(response.body).to match(/<span>sev<\/span>/)
        expect(response.body).to match(/<span>pri<\/span>/)
        expect(response.body).to match(/added /)
      end

      it "shows an expiry and a wake date when the memory has them" do
        preference.update!(expires_at: 30.days.from_now, relevant_at: 3.days.from_now)

        get(:memories)

        expect(response.body).to match(/expires /)
        expect(response.body).to match(/wakes /)
      end

      # The pile a stashed thought went into is the same sort of thing as a tag —
      # how it gets found again — so it sits with them.
      it "puts the category in front of the tags" do
        stash = me.buddy_memories.create!(kind: :stash, content: "Fix the gate.", severity: 0, category: :home)

        get(:memories)

        row = response.body[/data-memory-id="#{stash.id}".*?<\/textarea>.*?<\/div>/m]
        expect(row.index("memory-cat")).to be < row.index("memory-tags-input")
      end

      # The stylesheet resets `button.memory-delete` and `.memory-delete-form`
      # separately, and `button_to` decides which element each lands on.
      it "puts the reset classes where the stylesheet expects them" do
        get(:memories)

        expect(response.body).to match(/<form[^>]*class="[^"]*memory-delete-form/)
        expect(response.body).to match(/<button[^>]*class="[^"]*memory-delete[^-]/)
      end

      # Deleting is the one control here that can't be undone, sitting beside one
      # that can. UJS reads `data-confirm` off the form.
      it "asks before deleting" do
        get(:memories)

        form = response.body[/<form[^>]*memory-delete-form[^>]*>/]
        expect(form).to include("data-confirm")
        expect(form).not_to include("turbo-confirm")
      end

      # The prompt names the row and quotes it, because on a page of near-identical
      # cards "are you sure" cannot tell you which one you are about to lose.
      it "says which memory, and that drop is the reversible one" do
        get(:memories)

        form = response.body[/<form[^>]*memory-delete-form[^>]*>/]
        expect(form).to match(/Delete #\d+ for good/)
        expect(form).to match(/Drop keeps it/)
      end

      # The bar is the filter state, the way it is on banking and emails. A chip
      # is that query with one term written in, or taken back out if it's already
      # there — so the two can never disagree about what is being shown.
      describe "chips writing into the search bar" do
        def chip_queries
          response.body.scan(/<a\b[^>]*\bdata-query-chip\b[^>]*?href="[^"]*\?q=([^"]*)"/m)
            .flatten.map { |q| CGI.unescape(q.tr("+", " ")) }
        end

        it "adds a term to an empty bar" do
          get(:memories, params: { q: "" })

          expect(chip_queries).to include("kind:followup")
        end

        it "keeps what's already in the bar when adding one" do
          get(:memories, params: { q: "hospital" })

          expect(chip_queries).to include("hospital kind:followup")
        end

        it "ORs a second value for the same field rather than replacing it" do
          get(:memories, params: { q: "kind:followup" })

          expect(chip_queries).to include("(kind:concept OR kind:followup)")
        end

        it "takes a term back out when its chip is already on" do
          get(:memories, params: { q: "kind:followup hospital" })

          expect(chip_queries).to include("hospital")
        end

        it "marks the chips the query already names" do
          get(:memories, params: { q: "kind:followup" })

          on = response.body.scan(/class="memory-check is-on"[^>]*>([^<]*)</m).flatten.map(&:strip)
          expect(on).to include("Follow-up")
          expect(on).not_to include("Stash")
        end

        # Landing on the page is a real query, not a hidden default, so the bar
        # says what is being hidden and clearing it is one gesture.
        it "starts with the live clause written out" do
          get(:memories)

          expect(response.body).to include(SystemController::DEFAULT_MEMORY_QUERY)
        end

        # The greying-out is done by JS once it decides nothing has changed.
        # Rendered disabled, a page without JS would have no way to search at all.
        it "ships the button enabled and the bar's starting value beside it" do
          get(:memories, params: { q: "kind:stash" })

          button = response.body[/<button[^>]*data-query-submit[^>]*>/]
          expect(button).to be_present
          expect(button).not_to include("disabled")
          expect(response.body).to include('data-query-initial="kind:stash"')
        end
      end

      describe "rows that were put aside" do
        let!(:dropped) {
          me.buddy_memories.create!(kind: :stash, content: "A thing let go of.", severity: 0, status: :dropped)
        }

        # Dropping is what makes a companion's own judgement reversible — three of
        # Eve's pile items were dropped wrongly on 18 Aug and could only be put
        # back because the rows were still there. They just aren't what this page
        # is for, so they don't pad the default list.
        it "leaves them out unless they're asked for" do
          get(:memories)

          expect(response.body).not_to include("A thing let go of.")
        end

        it "shows them when the query asks" do
          get(:memories, params: { q: "status:dropped" })

          expect(response.body).to include("A thing let go of.")
          expect(response.body).not_to include("cat is in hospital")
        end

        # Clearing the bar means "stop narrowing", not "reapply the default".
        it "shows everything once the query is emptied" do
          get(:memories, params: { q: "" })

          expect(response.body).to include("A thing let go of.", "cat is in hospital")
        end

        it "offers to put one back rather than only to delete it" do
          get(:memories, params: { q: "status:dropped" })

          expect(response.body).to include(">restore<")
        end
      end

      it "narrows by kind" do
        get(:memories, params: { q: "kind:followup" })

        expect(response.body).to include("cat is in hospital")
        expect(response.body).not_to include("oat milk lattes")
      end

      it "takes several kinds at once" do
        get(:memories, params: { q: "(kind:followup OR kind:preference)" })

        expect(response.body).to include("cat is in hospital", "oat milk lattes")
        expect(response.body).not_to include("Their own private thing.")
      end

      it "takes several people at once" do
        get(:memories, params: { q: "(who:#{me.username} OR who:#{other.username})" })

        expect(response.body).to include("cat is in hospital", "Their own private thing.")
      end

      # A bare word still searches the prose, so the bar is usable without
      # knowing any of the field names.
      it "searches the prose alongside the terms" do
        get(:memories, params: { q: "kind:followup hospital" })

        expect(response.body).to include("cat is in hospital")
        expect(response.body).not_to include("oat milk lattes")
      end

      it "excludes with a negated term" do
        get(:memories, params: { q: "-kind:followup" })

        expect(response.body).to include("oat milk lattes")
        expect(response.body).not_to include("cat is in hospital")
      end

      # `followup` is the one the enum name gets wrong on its own.
      it "names the kinds the way a person would" do
        get(:memories)

        expect(response.body).to include("Follow-up")
        expect(response.body).not_to match(/>followup</)
      end

      it "narrows by tag" do
        get(:memories, params: { q: "tag:pets" })

        expect(response.body).to include("cat is in hospital")
        expect(response.body).not_to include("Their own private thing.")
      end

      it "narrows by person" do
        get(:memories, params: { q: "who:#{other.username}" })

        expect(response.body).to include("Their own private thing.")
        expect(response.body).not_to include("cat is in hospital")
      end

      it "searches the prose with a bare word" do
        get(:memories, params: { q: "hospital" })

        expect(response.body).to include("cat is in hospital")
        expect(response.body).not_to include("oat milk lattes")
      end

      it "offers the tags actually in use, commonest first" do
        get(:memories)

        tags = response.body[%r{<div class="memories-tags">.*?</div>}m].to_s
        expect(tags).to include("pets", "health", "food")
      end

      it "is refused to anyone who isn't me" do
        allow(User).to receive(:me).and_return(other)
        allow_any_instance_of(User).to receive(:me?).and_return(false)

        get(:memories)

        expect(response).not_to have_http_status(:ok)
      end
    end

    describe "PATCH #update_memory" do
      it "edits a severity that landed too high" do
        patch(:update_memory, params: { id: followup.id, severity: 30 })

        expect(response).to have_http_status(:ok)
        expect(followup.reload.severity).to eq(30)
      end

      it "clamps a severity outside the scale rather than storing it" do
        patch(:update_memory, params: { id: followup.id, severity: 500 })

        expect(followup.reload.severity).to eq(100)
      end

      it "rewrites content that came out wrong" do
        patch(:update_memory, params: { id: followup.id, content: "Their cat came home." })

        expect(followup.reload.content).to eq("Their cat came home.")
      end

      it "retags" do
        patch(:update_memory, params: { id: followup.id, tags: "Pets, Vet " })

        expect(followup.reload.tag_list).to eq(%w[pets vet])
      end

      it "moves something into a different kind" do
        patch(:update_memory, params: { id: preference.id, kind: "concept" })

        expect(preference.reload).to be_kind_concept
      end

      # The likeliest reason to open this page at all.
      it "edits the priority that orders the always-loaded preferences" do
        patch(:update_memory, params: { id: preference.id, priority: 7 }, as: :json)

        expect(preference.reload.priority).to eq(7)
      end

      it "drops one and puts it back, both without a reload" do
        patch(:update_memory, params: { id: preference.id, status: "dropped" }, as: :json)
        expect(preference.reload.status).to eq("dropped")

        patch(:update_memory, params: { id: preference.id, status: "active" }, as: :json)
        expect(preference.reload.status).to eq("active")
      end

      it "disarms a check-in without deleting the memory" do
        patch(:update_memory, params: { id: followup.id, check_in_at: "" })

        expect(followup.reload.check_in_at).to be_nil
        expect(followup).to be_persisted
      end

      it "refuses an edit the model itself would refuse" do
        patch(:update_memory, params: { id: followup.id, content: "" })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(followup.reload.content).to eq("Their cat is in hospital.")
      end
    end

    describe "DELETE #destroy_memory" do
      it "deletes one that landed wrong" do
        expect { delete(:destroy_memory, params: { id: followup.id }) }
          .to change(BuddyMemory, :count).by(-1)
      end

      it "takes its notes with it" do
        followup.notes.create!(body: "still in overnight")

        delete(:destroy_memory, params: { id: followup.id })

        expect(BuddyMemoryNote.where(buddy_memory_id: followup.id)).to be_empty
      end
    end
  end
end
