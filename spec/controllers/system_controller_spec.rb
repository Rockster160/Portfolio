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

    render_views

    it "is 404 for anyone but User.me, signed out, standard or another admin" do
      [nil, standard, other_admin].each do |viewer|
        sign_in(viewer) if viewer
        [:index, :connections].each do |action|
          get action
          expect(response).to have_http_status(:not_found), "#{viewer&.id.inspect} #{action}"
        end
      end
    end

    context "when signed in as User.me" do
      before { sign_in me }

      it "renders the index" do
        get :index
        expect(response).to be_successful
      end

      # pg_stat_activity may be empty in restricted test environments; what
      # matters is the structure when rows do come back.
      it "renders the connections page with db rows, a state summary, the WS pid and the pool stat", :aggregate_failures do
        get :connections

        expect(response).to be_successful
        rows = controller.instance_variable_get(:@db_connections)
        expect(rows).to be_an(Array)
        expect(rows.first.keys).to include("pid", "state", "query") if rows.any?
        expect(controller.instance_variable_get(:@db_summary).values.sum).to eq(rows.length)
        expect(controller.instance_variable_get(:@ws_worker_pid)).to eq(Process.pid)
        stat = controller.instance_variable_get(:@pool_stat)
        expect(stat).to include(:size, :busy, :idle, :waiting)
        expect(stat[:size]).to be_positive
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

      # The only ones with anything left to decide go first. Landing on the page
      # IS reading them, so everything is marked seen.
      it "lists them open first, counted per status, with a button per status, marking all seen", :aggregate_failures do
        request!("Shipped one", status: :shipped)
        request!("Open one")
        request!("Declined one", status: :declined)

        expect { get :feature_requests }.to change { FeatureRequest.where(seen_at: nil).count }.to(0)

        expect(response.body.index("Open one")).to be < response.body.index("Shipped one")
        expect(response.body).to include("1 open").and include("1 declined").and include("0 planned")
        FeatureRequest.statuses.each_key { |status| expect(response.body).to include(%(data-fr-set="#{status}")) }
      end

      it "renders with nothing on the list" do
        get :feature_requests

        expect(response).to be_successful
      end
    end

    describe "PATCH #update_feature_request" do
      # The row can go back as readily as forward, and the new open count comes
      # back so the blip can follow.
      it "marks one resolved and back to open, handing back the open count" do
        request!("Still open")
        row = request!("Closing this")

        patch :update_feature_request, params: { id: row.id, status: :shipped }
        expect(response).to be_successful
        expect(row.reload).to be_status_shipped
        expect(response.parsed_body["open"]).to eq(1)

        patch :update_feature_request, params: { id: row.id, status: :open }
        expect(row.reload).to be_status_open
        expect(response.parsed_body["open"]).to eq(2)
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

      # Two different questions: the blip is what needs deciding, the unread mark
      # is whether the page has been looked at since one landed.
      it "shows a blip for what's still open, and marks the card unread while any are unseen" do
        request!("One")
        request!("Two", seen: true)
        request!("Three", status: :shipped)

        get :index

        expect(response.body).to match(/system-card-blip">\s*2\s*</)
        expect(response.body).to include("system-card unread")
      end

      it "shows no blip and no unread mark when nothing is open and all are seen" do
        request!("One", status: :shipped, seen: true)

        get :index

        # The class name is in the stylesheet either way; the SPAN is the blip.
        expect(response.body).not_to include(%(<span class="system-card-blip">))
        expect(response.body).not_to include("system-card unread")
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

  # Curating what the companions have kept, outside Byte.
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
      def visible?(content) = response.body.include?(content)

      # The id is what goes into a script or a query afterwards. Deleting is the
      # one control that can't be undone, so UJS asks first via `data-confirm`.
      it "lists everything the companions are holding, weightiest first, with ids, dates and tags", :aggregate_failures do
        preference.update!(expires_at: 30.days.from_now, relevant_at: 3.days.from_now)

        get(:memories)

        expect(response).to have_http_status(:ok)
        expect(response.body.index("cat is in hospital")).to be < response.body.index("oat milk lattes")
        expect(response.body).to include("Their own private thing.", "3 total")
        expect(response.body).to include("##{followup.id}")
        expect(response.body).to match(/expires /)
        expect(response.body).to match(/wakes /)

        form = response.body[/<form[^>]*memory-delete-form[^>]*>/]
        expect(form).to include("data-confirm")
        expect(form).not_to include("turbo-confirm")

        tags = response.body[%r{<div class="memories-tags">.*?</div>}m].to_s
        expect(tags).to include("pets", "health", "food")

        # Landing on the page is a real query, not a hidden default.
        expect(response.body).to include(SystemController::DEFAULT_MEMORY_QUERY)
      end

      # The bar is the filter state. A chip is that query with one term written
      # in, ORed with a sibling value, or taken back out if it's already there.
      describe "chips writing into the search bar" do
        def chip_queries
          response.body.scan(/<a\b[^>]*\bdata-query-chip\b[^>]*?href="[^"]*\?q=([^"]*)"/m)
            .flatten.map { |q| CGI.unescape(q.tr("+", " ")) }
        end

        it "adds, ORs and removes terms against what's already in the bar" do
          [
            ["", "kind:followup"],
            ["hospital", "hospital kind:followup"],
            ["kind:followup", "(kind:concept OR kind:followup)"],
            ["kind:followup hospital", "hospital"],
          ].each do |q, chip|
            get(:memories, params: { q: q })
            expect(chip_queries).to include(chip), "q=#{q.inspect}"
          end
        end

        # The greying-out is done by JS; rendered disabled, a page without JS
        # would have no way to search at all.
        it "marks the chips the query already names, and ships the button enabled" do
          get(:memories, params: { q: "kind:followup" })

          on = response.body.scan(/class="memory-check is-on"[^>]*>([^<]*)</m).flatten.map(&:strip)
          expect(on).to include("Follow-up")
          expect(on).not_to include("Stash")

          button = response.body[/<button[^>]*data-query-submit[^>]*>/]
          expect(button).not_to include("disabled")
          expect(response.body).to include('data-query-initial="kind:followup"')
        end
      end

      # Dropping is what makes a companion's own judgement reversible, so the
      # rows stay; they just don't pad the default list. Clearing the bar means
      # "stop narrowing", not "reapply the default".
      it "shows dropped rows only when asked for, offering to restore them" do
        me.buddy_memories.create!(kind: :stash, content: "A thing let go of.", severity: 0, status: :dropped)

        get(:memories)
        expect(visible?("A thing let go of.")).to be(false)

        get(:memories, params: { q: "status:dropped" })
        expect(visible?("A thing let go of.")).to be(true)
        expect(visible?("cat is in hospital")).to be(false)
        expect(response.body).to include(">restore<")

        get(:memories, params: { q: "" })
        expect(response.body).to include("A thing let go of.", "cat is in hospital")
      end

      # A bare word still searches the prose, so the bar is usable without
      # knowing any of the field names.
      it "narrows by kind, tag, person, prose and negation" do
        cat, latte, private = "cat is in hospital", "oat milk lattes", "Their own private thing."
        [
          ["kind:followup", [cat], [latte]],
          ["(kind:followup OR kind:preference)", [cat, latte], [private]],
          ["(who:#{me.username} OR who:#{other.username})", [cat, private], []],
          ["kind:followup hospital", [cat], [latte]],
          ["-kind:followup", [latte], [cat]],
          ["tag:pets", [cat], [private]],
          ["who:#{other.username}", [private], [cat]],
          ["hospital", [cat], [latte]],
        ].each do |q, shown, hidden|
          get(:memories, params: { q: q })
          shown.each { |c| expect(visible?(c)).to be(true), "#{q}: expected #{c}" }
          hidden.each { |c| expect(visible?(c)).to be(false), "#{q}: did not expect #{c}" }
        end
      end

      it "is refused to anyone who isn't me" do
        allow(User).to receive(:me).and_return(other)
        allow_any_instance_of(User).to receive(:me?).and_return(false)

        get(:memories)

        expect(response).not_to have_http_status(:ok)
      end
    end

    describe "PATCH #update_memory" do
      it "edits severity (clamped), content, tags, kind and priority" do
        [
          [followup, { severity: 30 }, ->(m) { m.severity }, 30],
          [followup, { severity: 500 }, ->(m) { m.severity }, 100],
          [followup, { content: "Their cat came home." }, ->(m) { m.content }, "Their cat came home."],
          [followup, { tags: "Pets, Vet " }, ->(m) { m.tag_list }, %w[pets vet]],
          [preference, { kind: "concept" }, ->(m) { m.kind }, "concept"],
          [preference, { priority: 7 }, ->(m) { m.priority }, 7],
        ].each do |memory, edit, read, value|
          patch(:update_memory, params: { id: memory.id, **edit }, as: :json)

          expect(response).to have_http_status(:ok)
          expect(read.call(memory.reload)).to eq(value), edit.to_s
        end
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

      it "queues the job for a check-in time set by hand" do
        Sidekiq::Testing.fake! {
          BuddyCheckInWorker.clear
          at = 3.days.from_now.change(sec: 0)

          patch(:update_memory, params: { id: followup.id, check_in_at: at.iso8601 })

          expect(BuddyCheckInWorker.jobs.map { |job| [job["args"], job["at"].to_i] }).to eq([[[followup.id], at.to_i]])
        }
      end

      it "refuses an edit the model itself would refuse" do
        patch(:update_memory, params: { id: followup.id, content: "" })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(followup.reload.content).to eq("Their cat is in hospital.")
      end
    end

    describe "DELETE #destroy_memory" do
      it "deletes one that landed wrong, notes and all" do
        followup.notes.create!(body: "still in overnight")

        expect { delete(:destroy_memory, params: { id: followup.id }) }.to change(BuddyMemory, :count).by(-1)
        expect(BuddyMemoryNote.where(buddy_memory_id: followup.id)).to be_empty
      end
    end
  end
end
