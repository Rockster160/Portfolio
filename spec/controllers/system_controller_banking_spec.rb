require "rails_helper"

RSpec.describe SystemController, type: :controller do
  let(:me) { FactoryBot.create(:user, phone: "5550003000", role: :admin) }
  let(:standard) { FactoryBot.create(:user, phone: "5550003001") }

  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "ACT-0001", name: "PREMIER PLUS CKG (2363)", last4: "2363",
      balance_cents: 1_832_024, available_balance_cents: 1_832_024,
      balance_date: 1.hour.ago
    )
  }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "ACT-0002", name: "AMZ Prime (7283)", last4: "7283",
      kind: :credit, balance_cents: -198_853, available_balance_cents: 0
    )
  }

  before do
    allow(User).to receive(:me).and_return(me)
    me_id = me.id
    allow_any_instance_of(User).to receive(:me?) { |u| u.id == me_id }
  end

  # Scoped on purpose: the page prints "$0.00" in the results totals whenever a
  # search matched nothing, so a bare `include` says nothing about the accounts.
  def accounts_table
    response.body[%r{<table class="bank-table bank-accounts">.*?</table>}m].to_s
  end

  describe "GET #banking" do
    render_views

    it "is not reachable by a standard user" do
      sign_in standard
      get :banking
      expect(response).to have_http_status(:not_found)
    end

    context "when signed in as me" do
      before { sign_in me }

      # A card sends "0.00" available, which is a placeholder rather than
      # headroom, and an account that has never reported is not zero either.
      # The chosen name is what you read and edit; the institution's own name
      # sits underneath, and rows save in place with no Save buttons.
      it "lists the accounts as inline-editable rows with their real balances", :aggregate_failures do
        checking.update!(friendly_name: "Checking")
        BankAccount.create!(name: "Chase Credit (4842)", last4: "4842", kind: :credit)

        get :banking

        expect(response.body).to include("$18,320.24")
        expect(accounts_table).to include("-$1,988.53", "Chase Credit (4842)")
        expect(accounts_table).not_to include("$0.00")
        expect(response.body).to match(/data-field="friendly_name".*?>Checking<\/span>/m)
        expect(response.body).to include(%(<span class="sub">PREMIER PLUS CKG (2363)</span>))
        expect(response.body).to include(%(data-text data-field="friendly_name"), %(data-select="true" data-field="kind"))
        expect(response.body).not_to include(%(<input type="submit" name="commit" value="Save"))
      end

      # The published figure is the AVAILABLE total netted against the cards,
      # loans left out; the posted total sits beside it, and the balance only
      # shows beside an account where the two differ.
      it "publishes and shows the dashboard figure, marking what counts toward it", :aggregate_failures do
        checking.update!(kind: :checking, available_balance_cents: 1_692_699)
        loan = BankAccount.create!(
          simplefin_id: "ACT-M", name: "MORTGAGE LOAN (7153)", last4: "7153",
          kind: :loan, balance_cents: -33_718_397
        )

        get :banking

        expect(SimpleFin::DashboardCache.balance_cents).to eq(1_633_171)
        expect(SimpleFin::DashboardCache.included?(loan)).to be(false)
        expect(response.body).to include("$16,926.99", "$18,320.24 balance", "$14,938.46", "$16,331.71 balance")
        expect(response.body).not_to include("-$1,988.53 balance")
        expect(response.body.scan(%(<em class="tag primary")).size).to eq(2)
        expect(response.body).to include("Checking")
      end

      it "marks nothing as feeding the dashboard when every account is a loan" do
        checking.update!(kind: :loan)
        card.update!(kind: :loan)

        get :banking

        expect(response).to be_successful
        expect(response.body).not_to include(%(<em class="tag primary"))
      end

      # A row with no alert behind it offers the same category picker as every
      # other row, and the categories are read off the transactions themselves.
      it "lists transactions with their categories, linked or not, and links to the uncategorized", :aggregate_failures do
        event = ActionEvent.create!(
          user: me, name: "Transaction", timestamp: 1.day.ago,
          data: { amount: 21.48, account: "(...7283)", category: "subscriptions" }
        )
        BankTransaction.create!(
          simplefin_id: "TRN-0001", bank_account: card, action_event: event,
          posted_at: 1.day.ago, amount_cents: -2148, payee: "Netflix"
        )
        BankTransaction.create!(
          simplefin_id: "TRN-0002", bank_account: card,
          posted_at: 1.day.ago, amount_cents: -500, payee: "Mystery"
        )
        BankTransaction.create!(
          simplefin_id: "TRN-0003", bank_account: card,
          posted_at: 1.day.ago, amount_cents: -100, payee: "Odd", category: "Extra Expense"
        )

        get :banking

        expect(response.body).to include("Netflix", "subscriptions", "Mystery", "Extra Expense")
        expect(response.body).to include(%(data-field="category"), "q=category%3Anone")
      end
    end
  end

  describe "GET #banking formatting and search" do
    render_views
    before { sign_in me }

    def linked_transaction(cents:, category:, payee:, id: "TRN-A", at: Time.utc(2026, 8, 10, 21, 15))
      event = ActionEvent.create!(
        user: me, name: "Transaction", timestamp: at,
        data: { amount: (cents.abs / 100.0), account: "(...7283)", category: category }
      )
      BankTransaction.create!(
        simplefin_id: id, bank_account: card, action_event: event,
        posted_at: at, transacted_at: at, amount_cents: cents, payee: payee,
        category: category
      )
    end

    def search_notes = controller.instance_variable_get(:@search_notes)

    # The dates belong to the query, so the pickers are a view onto it. A bare
    # term names a whole unit, `>` skips the unit named, and a negated term
    # names dates to EXCLUDE, which is no range at all.
    describe "the date pickers" do
      it "fill from the timestamp terms in the query" do
        [
          ["timestamp>=2026-07-01 timestamp<=2026-07-31", "2026-07-01", "2026-07-31"],
          ["timestamp:2026-07", "2026-07-01", "2026-07-31"],
          ["timestamp>2026-07-01 timestamp<2026-08-01", "2026-07-02", "2026-07-31"],
          ["-timestamp:2026-07", "", ""],
        ].each do |q, from, to|
          get :banking, params: { q: q }

          expect(response.body).to include(%(data-date-from value="#{from}")), q
          expect(response.body).to include(%(data-date-to value="#{to}")), q
        end
      end

      # Failing closed is right but invisible, so the page says which part of
      # the search it could not read.
      it "notes the part of the search it could not read, and stays quiet otherwise" do
        get :banking, params: { q: "timestamp>=notadate" }
        expect(response).to have_http_status(:ok)
        expect(search_notes).to be_present
        expect(response.body).to include("notadate")

        get :banking, params: { q: "payee:amazon timestamp>" }
        expect(search_notes).to be_present

        get :banking, params: { q: "payee:amazon" }
        expect(search_notes).to be_blank
      end

      # `basic` opts the pickers out of the global full-width input rule.
      it "sits inside the search row rather than taking one of its own" do
        get :banking

        row = response.body[%r{<form[^>]*class="basic bank-search".*?</form>}m].to_s
        expect(row).to include("data-date-from", "data-date-to", %(<input type="date" class="basic"))
      end
    end

    # The legend is the category picker, so it lists what is NOT on the chart
    # as well as what is, and its totals hold still as you pick.
    describe "the legend" do
      before do
        linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix")
        linked_transaction(cents: -9900, category: "groceries", payee: "Sprouts", id: "TRN-B")
        linked_transaction(cents: -500, category: "eat out", payee: "Cafe", id: "TRN-C")
      end

      def legend
        response.body[%r{<div class="cc-legend bank-legend".*?</div>\s*</details>}m].to_s
      end

      # `category:eat out` would parse as `category:eat` plus a stray word.
      it "lists every category, undimmed, quoting a two-word one, when nothing is picked" do
        get :banking

        expect(legend).to include("Subscriptions", "Groceries", "Eat Out")
        expect(legend).to include(%(data-any-picked="false"))
        expect(legend).to include(CGI.escapeHTML(system_banking_path(q: %(category:"eat out"))))
      end

      it "keeps offering the others once one is picked, ORing a second in, totals over the wider set" do
        get :banking, params: { q: "category:groceries" }

        expect(legend).to include("Subscriptions", "Eat Out", "picked", %(data-any-picked="true"))
        expect(legend).to include(CGI.escapeHTML(system_banking_path(q: "(category:groceries OR category:subscriptions)")))
        expect(legend).to include("$21.48", "$99.00")
      end

      it "drops one category out of the group and leaves the other" do
        get :banking, params: { q: "(category:groceries OR category:subscriptions)" }

        expect(legend).to include(CGI.escapeHTML(system_banking_path(q: "category:subscriptions")))
      end
    end

    # The bucket is a way of looking at the results rather than a filter, so it
    # rides as its own param, hung off the search form by id, and survives the
    # links that rebuild the page. Most visits are not about the bars, so the
    # drawer starts closed.
    describe "the over-time chart" do
      before { linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix") }

      it "buckets by month unless told a bucket it has, in a closed drawer" do
        [[{}, "month", "Month"], [{ bucket: "week" }, "week", "Week"], [{ bucket: "fortnight" }, "month", "Month"]].each do |params, value, label|
          get :banking, params: params

          expect(response.body).to include(%(<option selected="selected" value="#{value}">#{label}</option>)), params.to_s
        end
        expect(response.body).to include(%(id="bank-search-form"), %(form="bank-search-form"))
        expect(response.body).to include(%(<details class="bank-drawer bank-chart">))
        expect(response.body).not_to include(%(<details class="bank-drawer bank-chart" open))

        get :banking, params: { bucket: "week" }
        expect(response.body).to include("bucket=week")
      end

      it "charts only the rows the search matched" do
        linked_transaction(cents: -9900, category: "groceries", payee: "Sprouts", id: "TRN-B")

        get :banking, params: { q: "payee:sprouts" }
        payload = JSON.parse(response.body[%r{data-bank-chart-payload>(.*?)</script>}m, 1])

        expect(payload["datasets"].pluck("label")).to eq(["Groceries"])
      end
    end

    # Clicking an account adds it to the search without discarding what was
    # typed, ORs a second one in (two bare account terms AND to nothing), and
    # takes it back out whole, negation included.
    it "builds account filters that keep, OR, drop and un-negate terms in the search" do
      [
        ["payee:amazon", "/system/banking?q=payee%3Aamazon+account%3A2363"],
        ["account:7283", "/system/banking?q=%28account%3A2363+OR+account%3A7283%29"],
        ["(account:2363 OR account:7283) payee:amazon", "/system/banking?q=payee%3Aamazon+account%3A7283"],
        ["account:2363 payee:amazon", "/system/banking?q=payee%3Aamazon"],
        ["-account:7283 payee:amazon", "/system/banking?q=payee%3Aamazon+account%3A2363"],
      ].each do |q, url|
        get :banking, params: { q: q }

        expect(response.body).to include(%(data-filter-url="#{url}")), q
      end

      get :banking, params: { q: "(account:2363 OR account:7283) payee:amazon" }
      expect(response.body.scan(%(class="picked")).size).to eq(2)
    end

    # Last four is the only key that cannot also match a second account.
    it "gives an account with no last four no filter at all" do
      BankAccount.create!(simplefin_id: "ACT-X", name: "Mystery", kind: :savings, balance_cents: 100)

      get :banking
      expect(response.body).to include(%(data-filter-url=""))
    end

    # SimpleFIN's figure is routinely most of a day stale and an alert arrives in
    # seconds, so the page carries the figure forward, says what it was built on,
    # and marks it as an estimate.
    describe "the projected balance" do
      before { checking.update!(kind: :checking) }

      def since(cents, at: 10.minutes.ago, account: checking, **attrs)
        BankTransaction.create!(
          bank_account: account, amount_cents: cents, transacted_at: at,
          payee: "direct deposit", **attrs
        )
      end

      # Scoped to the warning itself: the uploader's help text uses similar words.
      def attribution_warning
        response.body[%r{<p class="bank-warn">.*?</p>}m].to_s
      end

      it "carries forward a deposit the bank's figure is too old to include", :aggregate_failures do
        since(437_070)

        get :banking

        # 18,320.24 + 4,370.70
        expect(accounts_table).to include("$22,690.94", "$18,320.24 reported")
        expect(accounts_table).to match(/<td class="right [a-z]+ projected"/)
        expect(attribution_warning).to eq("")
      end

      it "shows the reported figure alone when nothing new, nothing uncovered and nothing live has happened" do
        [[], [437_070, { at: 3.hours.ago }], [-437_070, { voided_at: Time.current }]].each do |cents, attrs|
          BankTransaction.delete_all
          since(cents, **(attrs || {})) if cents

          get :banking

          expect(accounts_table).to include("$18,320.24")
          expect(accounts_table).not_to include("$18,320.24 reported", "$22,690.94", "$13,949.54")
        end
      end

      it "names the rows it could not attribute rather than dropping them" do
        since(437_070, account: nil)

        get :banking

        expect(attribution_warning).to include("$4,370.70")
        expect(accounts_table).not_to include("$22,690.94")
      end
    end

    # An authorization cancelled before it posted never arrives to be netted off,
    # so it is struck through, left out of the totals, and still findable.
    it "strikes a cancelled charge through, keeps it listed and findable, and leaves it out of the totals", :aggregate_failures do
      cancelled = linked_transaction(cents: -1_955, category: "pets", payee: "Amazon.com")
      cancelled.update!(voided_at: Time.current)
      linked_transaction(cents: -2_078, category: "pets", payee: "AMAZON MKTPLACE", id: "TRN-B")

      get :banking

      expect(response.body).to include("data-void", "Amazon.com")
      expect(response.body).to match(/<tr data-row[^>]*class="voided"/)
      totals = response.body[%r{<div class="bank-totals">.*?</div>\s*</div>}m].to_s
      expect(totals).to include("$20.78")
      expect(totals).not_to include("$19.55")

      get :banking, params: { q: "transfer:false" }
      expect(response.body).to include("Amazon.com")
    end

    # The bulk form lives in a closed modal and reaches the row checkboxes by id.
    # The syntax reference lists values FROM the code that accepts them, and
    # leaves out mcc, which SimpleFIN never sends.
    it "carries the bulk category modal and a collapsed search syntax reference", :aggregate_failures do
      linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix")

      get :banking

      body = response.body
      expect(body).to include(%(data-modal="#bank-bulk"), %(id="bank-bulk"), "modal-wrapper hidden")
      expect(body).to include(%(form="bank-bulk-form"), %(class="basic bank-bulk"))

      TransactionCategory::ALL.each { |category| expect(body).to include(category.to_s) }
      expect(body).to include("none")
      (BankTransaction::WITHDRAWAL_WORDS + BankTransaction::DEPOSIT_WORDS).each { |word| expect(body).to include(word) }
      %w[payee memo description category account amount timestamp posted_at transacted_at direction pending linked transfer id simplefin_id].each { |field|
        expect(body).to include(field)
      }
      expect(body).not_to include("mcc")
      expect(body).to include(%(<details class="bank-drawer bank-syntax">))
      expect(body).not_to include(%(<details class="bank-drawer bank-syntax" open))
    end

    # The ids are the way to go and find either record behind two rows that read
    # the same; the SimpleFIN UUID identifies nothing new.
    it "names the records behind a row in its tooltip, without the SimpleFIN id" do
      row = linked_transaction(cents: -970, category: "fun", payee: "Arcade")
      row.action_event.update!(data: row.action_event.data.merge("email_id" => 51_450))

      get :banking

      expect(response.body).to include(
        %(title="BankTransaction##{row.id} ActionEvent##{row.action_event_id} Email#51450"),
      )
      expect(response.body).not_to include("SimpleFIN TRN-A")
    end

    describe "the metadata drawer" do
      it "shows what is known about the purchase, grouped by source, in a closed row" do
        row = linked_transaction(cents: -970, category: "fun", payee: "Arcade")
        row.update!(metadata: {
          "amazon" => { "order_id" => "112-6608200-0828238", "asins" => %w[B0C1XLC962 B07VWX9DMJ] },
        })

        get :banking

        expect(response.body).to include("112-6608200-0828238", "B0C1XLC962, B07VWX9DMJ", "order id", "Amazon")
        expect(response.body).to include(%(<tr class="bank-meta-row hidden" data-meta-row>))
      end

      # Matched on the markup: the page's own JS mentions `[data-meta-toggle]`.
      it "offers no button on a row with no metadata" do
        linked_transaction(cents: -970, category: "fun", payee: "Arcade")

        get :banking

        expect(response.body).not_to include(%(<button type="button" class="tag meta"), %(<tr class="bank-meta-row))
      end
    end

    # The memo edits in place as a contenteditable span, and the account sits
    # under the payee rather than in a column of its own.
    it "formats rows: cents, thousands, local date and time, titleized categories, negatives", :aggregate_failures do
      linked_transaction(cents: -970, category: "eat out", payee: "Arcade")
      linked_transaction(cents: -1_234_567, category: "home", payee: "Roofer", id: "TRN-B")

      get :banking

      body = response.body
      expect(body).to include("-$9.70", "-$12,345.67")
      expect(body).not_to include("-$9.7<")
      # 21:15 UTC is 3:15 PM Mountain.
      expect(body).to include(%(<span class="date">Aug 10, 2026</span>), %(<span class="time">3:15 PM</span>))
      expect(body).to include("Eat Out", "#D95926")
      expect(body).to include(%(class="right neg"))
      expect(body).to include(%(data-text data-field="memo"), "contenteditable")
      expect(body).not_to include(%(<input type="text" data-memo))
      expect(body).to include(%(<span class="acct">AMZ Prime (7283)</span>))
      expect(body).to match(%r{<th>Payee</th>\s*<th>Memo</th>})
      expect(body).to include("bank-pagination")
    end

    it "narrows the list with a search" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway", id: "TRN-A")
      linked_transaction(cents: -999, category: "groceries", payee: "Costco", id: "TRN-B", at: Time.utc(2026, 8, 9, 18, 0))

      get :banking, params: { q: "payee:subway" }
      expect(response.body).to include("Subway")
      expect(response.body).not_to include("Costco")
    end

    # The tokenizer rarely raises, so this drives the rescue directly: a query
    # that blows up shows its error and no rows, never every row.
    it "reports a failed search instead of returning everything" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway")
      allow(BankTransaction).to receive(:query).and_raise(StandardError, "bad token")

      get :banking, params: { q: "payee:whatever" }
      expect(response.body).to include("bad token")
      expect(response.body).not_to include("Subway")
    end

    # Both halves of a pair are the same money; listed twice they read as a
    # spend and a deposit that never happened.
    context "with a transfer pair" do
      let!(:mortgage) {
        BankAccount.create!(
          simplefin_id: "ACT-9", name: "MORTGAGE LOAN (7153)", last4: "7153",
          friendly_name: "Mortgage"
        )
      }
      let!(:out) {
        BankTransaction.create!(
          simplefin_id: "TRN-OUT", bank_account: card, payee: "Payment Sent",
          posted_at: 1.day.ago, transacted_at: 1.day.ago, amount_cents: -139_325
        )
      }
      let!(:incoming) {
        BankTransaction.create!(
          simplefin_id: "TRN-IN", bank_account: mortgage, payee: "Payment Received",
          posted_at: 1.day.ago, transacted_at: 1.day.ago, amount_cents: 139_325
        )
      }

      before do
        card.update!(friendly_name: "Prime")
        SimpleFin::TransferDetector.call
      end

      def results_one = %(<span class="bank-totals-label">Results</span>1</div>)

      # Asserted as one string so a route that renders the institution's own
      # name on either side fails here.
      it "pairs the halves and shows one row, routed in friendly names on the leaving side", :aggregate_failures do
        expect(out.reload.transfer_counterpart).to eq(incoming)
        expect(out).to be_transfer_source

        get :banking

        expect(response.body).to include(%(Prime<span class="arrow">→</span>Mortgage), "Payment Sent", results_one)
        expect(response.body).not_to include("AMZ Prime (7283)<span", %(<em class="tag xfer"), "Payment Received")
      end

      # Hiding a row must not make it unfindable.
      it "finds the pair by the account it went to" do
        get :banking, params: { q: "account:mortgage" }

        expect(response.body).to include("Payment Sent", results_one)
      end

      it "keeps the tag on a hand-flagged transfer" do
        event = ActionEvent.create!(
          user: me, name: "Transaction", timestamp: 1.day.ago,
          data: { amount: 40, account: "(...7283)", transfer: true }
        )
        BankTransaction.create!(
          simplefin_id: "TRN-FLAG", bank_account: card, action_event: event,
          posted_at: 2.days.ago, transacted_at: 2.days.ago, amount_cents: -4_000
        )

        get :banking
        expect(response.body).to include(%(<em class="tag xfer"))
      end
    end

    # A date with no clock time arrives as midnight UTC, which Mountain reads as
    # 6pm the day before.
    describe "the When column" do
      def row_at(id, at)
        BankTransaction.create!(
          simplefin_id: id, bank_account: card, payee: "Arcade",
          amount_cents: -500, posted_at: at, transacted_at: at
        )
      end

      it "shows the time when the bank gave one" do
        row_at("TIMED", Time.utc(2026, 8, 10, 22, 31))

        get :banking
        expect(response.body).to include(%(<span class="time">4:31 PM</span>))
      end

      # Asserted on the cell, not the page, which mentions dates elsewhere.
      it "shows a date-only row's own date alone, never slipped back a day" do
        row_at("DATEONLY", Time.utc(2026, 8, 10))

        get :banking
        expect(response.body).to include(%(<span class="date">Aug 10, 2026</span>))
        expect(response.body).not_to include(%(<span class="time">), %(<span class="date">Aug 9, 2026</span>))
      end
    end

    # Asserted on the markup, not the class name — the stylesheet ships on every
    # render and would match either way.
    it "draws the backfill progress bar only once something has synced, full when done" do
      get :banking
      expect(response.body).not_to include(%(<div class="bank-progress">))

      linked_transaction(cents: -500, category: "fun", payee: "Arcade")
      DataStorage[SimpleFin::Backfill::STORAGE_KEY] = { cursor: Time.utc(2024, 2, 16).iso8601, empty_runs: 0, done: false }
      get :banking
      expect(response.body).to match(/bank-progress-fill" *\n? *style="width: \d+%;/)
      expect(response.body).to include("Feb 16, 2024")

      DataStorage[SimpleFin::Backfill::STORAGE_KEY] = { cursor: Time.utc(2019, 5, 1).iso8601, empty_runs: 2, done: true }
      get :banking
      expect(response.body).to include("bank-progress-fill done", "width: 100%")
    end
  end

  describe "PATCH #update_transaction" do
    before { sign_in me }

    let(:event) {
      ActionEvent.create!(
        user: me, name: "Transaction", timestamp: 1.day.ago,
        notes: "Mom Solder Iron",
        data: { amount: 21.48, account: "(...7283)", category: "other" }
      )
    }
    let(:linked) {
      BankTransaction.create!(
        simplefin_id: "TRN-A", bank_account: card, action_event: event,
        posted_at: 1.day.ago, amount_cents: -2148, payee: "Netflix",
        category: "other"
      )
    }
    let(:unlinked) {
      BankTransaction.create!(
        simplefin_id: "TRN-B", bank_account: card,
        posted_at: 1.day.ago, amount_cents: -300, payee: "Mystery"
      )
    }

    # A cancelled charge never posts, so nothing arrives to net it off. Marking
    # it has to move the published balance too, or the row greys out here while
    # the dashboard goes on counting it.
    describe "cancelling" do
      it "marks it, republishing the balance and leaving the category alone, and clears it back" do
        expect(SimpleFin::DashboardCache).to receive(:refresh!).at_least(:once)

        patch :update_transaction, params: { id: linked.id, voided: true }
        expect(linked.reload).to be_voided
        expect(response.parsed_body["voided"]).to be(true)
        expect(linked.category).to eq("other")

        patch :update_transaction, params: { id: linked.id, voided: false }
        expect(linked.reload.voided_at).to be_nil
        expect(response.parsed_body["voided"]).to be(false)
      end
    end

    it "sets one row's category and answers with its color" do
      patch :update_transaction, params: { id: linked.id, category: "subscriptions" }

      expect(linked.reload.category).to eq("subscriptions")
      expect(response.parsed_body["color"]).to eq(TransactionCategory.color("subscriptions"))
    end

    it "refuses a category outside the vocabulary" do
      patch :update_transaction, params: { id: linked.id, category: "Extra Expense" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(linked.reload.category).to eq("other")
    end

    # The point of the column: a row the bank reported and no alert ever
    # described is categorizable like any other.
    it "categorizes a row that has no linked event" do
      patch :update_transaction, params: { id: unlinked.id, category: "groceries" }

      expect(response).to have_http_status(:ok)
      expect(unlinked.reload.category).to eq("groceries")
    end

    it "shows the alert's note as the memo when the row has none" do
      expect(linked.display_memo).to eq("Mom Solder Iron")
      expect(linked).to be_memo_from_event
    end

    it "saves an edited memo onto the row, overriding the inherited note" do
      patch :update_transaction, params: { id: linked.id, memo: "Soldering iron for Mum" }

      expect(linked.reload.memo).to eq("Soldering iron for Mum")
      expect(linked.display_memo).to eq("Soldering iron for Mum")
      expect(linked).not_to be_memo_from_event
      expect(event.reload.notes).to eq("Mom Solder Iron")
    end

    it "falls back to the alert's note when the memo is cleared" do
      linked.update!(memo: "typed")

      patch :update_transaction, params: { id: linked.id, memo: "  " }

      expect(linked.reload.memo).to be_nil
      expect(linked.display_memo).to eq("Mom Solder Iron")
    end

    it "saves a memo on an unlinked row, which has no event to write to" do
      patch :update_transaction, params: { id: unlinked.id, memo: "Cash withdrawal" }

      expect(unlinked.reload.display_memo).to eq("Cash withdrawal")
    end

    it "is not reachable by a standard user" do
      sign_in standard

      patch :update_transaction, params: { id: linked.id, category: "groceries" }

      expect(response).to have_http_status(:not_found)
      expect(linked.reload.category).to eq("other")
    end
  end

  describe "PATCH #bulk_update_transactions" do
    before { sign_in me }

    let(:event) {
      ActionEvent.create!(
        user: me, name: "Transaction", timestamp: 1.day.ago,
        data: { amount: 21.48, account: "(...7283)", category: "other" }
      )
    }
    let(:linked) {
      BankTransaction.create!(
        simplefin_id: "TRN-A", bank_account: card, action_event: event,
        posted_at: 1.day.ago, amount_cents: -2148, payee: "Netflix",
        category: "other"
      )
    }
    let(:unlinked) {
      BankTransaction.create!(
        simplefin_id: "TRN-B", bank_account: card,
        posted_at: 1.day.ago, amount_cents: -300, payee: "Mystery"
      )
    }

    # An unlinked row holds its own category, so a bulk pick reaches every row
    # in the selection; a linked one writes through to its ActionEvent.
    it "categorizes the selected rows, linked or not, writing through to the event" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id, unlinked.id], category: "subscriptions"
      }

      expect(linked.reload.category).to eq("subscriptions")
      expect(event.reload.data["category"]).to eq("subscriptions")
      expect(unlinked.reload.category).to eq("subscriptions")
    end

    it "refuses a category outside the vocabulary" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id], category: "Extra Expense"
      }

      expect(flash[:alert]).to be_present
      expect(linked.reload.category).to eq("other")
    end

    it "applies across a whole search when asked, leaving rows outside it alone" do
      linked
      untouched_event = ActionEvent.create!(
        user: me, name: "Transaction", timestamp: 1.day.ago,
        data: { amount: 5.0, account: "(...7283)", category: "groceries" }
      )
      BankTransaction.create!(
        simplefin_id: "TRN-D", bank_account: card, action_event: untouched_event,
        posted_at: 1.day.ago, amount_cents: -500, payee: "Costco"
      )
      other_event = ActionEvent.create!(
        user: me, name: "Transaction", timestamp: 1.day.ago,
        data: { amount: 5.0, account: "(...7283)", category: "other" }
      )
      BankTransaction.create!(
        simplefin_id: "TRN-C", bank_account: card, action_event: other_event,
        posted_at: 1.day.ago, amount_cents: -500, payee: "Netflix Extra"
      )

      patch :bulk_update_transactions, params: {
        q: "payee:netflix", apply_to_search: "1", category: "subscriptions"
      }

      expect(linked.reload.category).to eq("subscriptions")
      expect(other_event.reload.data["category"]).to eq("subscriptions")
      expect(untouched_event.reload.data["category"]).to eq("groceries")
    end

    it "is not reachable by a standard user" do
      sign_in standard

      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id], category: "subscriptions"
      }

      expect(response).to have_http_status(:not_found)
      expect(linked.reload.category).to eq("other")
    end
  end

  describe "PATCH #update_bank_account" do
    before { sign_in me }

    it "sets a friendly name" do
      patch :update_bank_account, params: { id: checking.id, friendly_name: "Main Checking" }

      expect(checking.reload.friendly_name).to eq("Main Checking")
      expect(response.parsed_body["display_name"]).to eq("Main Checking")
    end

    # Blank is a real choice — the row falls back to the institution name it
    # already prints underneath, rather than storing "".
    it "clears a friendly name back to nil" do
      checking.update!(friendly_name: "Main Checking")

      patch :update_bank_account, params: { id: checking.id, friendly_name: "  " }

      expect(checking.reload.friendly_name).to be_nil
      expect(response.parsed_body["friendly_name"]).to eq("")
      expect(response.parsed_body["display_name"]).to eq("PREMIER PLUS CKG (2363)")
    end

    # The dashboard reads a cache key, not the table, so designating checking
    # has to republish or the home cell stays stale until the next sync.
    it "sets the kind and republishes the dashboard balance" do
      expect(SimpleFin::DashboardCache).to receive(:refresh!)

      patch :update_bank_account, params: { id: checking.id, kind: :checking }

      expect(checking.reload).to be_checking
    end

    # A 500 is unparseable to the row's error handler, which would leave the
    # select showing a value that never saved.
    it "rejects a kind outside the enum without raising" do
      patch :update_bank_account, params: { id: checking.id, kind: "wire-transfers" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("wire-transfers")
      expect(checking.reload).to be_unknown
    end

    it "leaves the other field alone when only one is sent" do
      checking.update!(friendly_name: "Main Checking", kind: :checking)

      patch :update_bank_account, params: { id: checking.id, friendly_name: "Everyday" }

      expect(checking.reload).to be_checking
      expect(checking.friendly_name).to eq("Everyday")
    end

    it "is not reachable by a standard user" do
      sign_in standard

      patch :update_bank_account, params: { id: checking.id, friendly_name: "Nope" }

      expect(response).to have_http_status(:not_found)
      expect(checking.reload.friendly_name).to be_nil
    end
  end
end
