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

      it "lists the accounts with balances" do
        get :banking

        expect(response.body).to include("PREMIER PLUS CKG (2363)")
        expect(response.body).to include("$18,320.24")
        expect(response.body).to include("-$1,988.53")
      end

      it "warns while an account is still unclassified" do
        get :banking
        expect(response.body).to include("still unclassified")
      end

      # A card sends "0.00" available, which is a placeholder rather than
      # headroom. Taking it at face value would headline the card as holding
      # nothing instead of owing $1,988.53.
      it "headlines a card with its balance, not its placeholder zero" do
        checking.update!(kind: :checking)

        get :banking
        expect(accounts_table).to include("-$1,988.53")
        expect(accounts_table).not_to include("$0.00")
      end

      # The two figures are the same number on a card and on an account with
      # nothing authorized, and printing it twice says nothing.
      it "shows the balance beside it only where the two differ" do
        checking.update!(kind: :checking, available_balance_cents: 1_692_699)

        get :banking
        expect(response.body).to include("$16,926.99")
        expect(response.body).to include("$18,320.24 balance")
        expect(response.body).not_to include("-$1,988.53 balance")
      end

      # Two closed cards will never be reported by anyone. "$0.00" reads as a
      # real balance; nothing reported is not zero.
      it "leaves an account that has never reported blank rather than zero" do
        BankAccount.create!(name: "Chase Credit (4842)", last4: "4842", kind: :credit)

        get :banking
        expect(accounts_table).to include("Chase Credit (4842)")
        expect(accounts_table).not_to include("$0.00")
      end

      it "marks which account feeds the dashboard" do
        checking.update!(kind: :checking)

        get :banking
        expect(response.body).to include(%(<em class="tag primary"))
      end

      # Four accounts do not need four cards, and a Save button per card is a
      # step the transactions table already proved unnecessary.
      it "lists the accounts as inline-editable rows, with no save buttons" do
        checking.update!(friendly_name: "Checking")

        get :banking
        expect(response.body).to include(%(data-text data-field="friendly_name"))
        expect(response.body).to include(%(data-select="true" data-field="kind"))
        expect(response.body).not_to include(%(<input type="submit" name="commit" value="Save"))
      end

      # The chosen name is what you read and what you edit; the institution's
      # own name is the fixed thing underneath it.
      it "puts the institution name under the chosen name" do
        checking.update!(friendly_name: "Checking")

        get :banking
        expect(response.body).to match(/data-field="friendly_name".*?>Checking<\/span>/m)
        expect(response.body).to include(%(<span class="sub">PREMIER PLUS CKG (2363)</span>))
      end

      it "says so when nothing feeds the dashboard figure" do
        checking.update!(kind: :loan)
        card.update!(kind: :loan)
        get :banking

        expect(response.body).to include("has nothing to read")
      end

      # The dashboard reads a sum that appears on no single row, so the page
      # has to show it or the number is only derivable by adding them up.
      it "shows the cumulative figure, with loans left out" do
        checking.update!(kind: :checking)
        BankAccount.create!(
          simplefin_id: "ACT-M", name: "MORTGAGE LOAN (7153)", last4: "7153",
          kind: :loan, balance_cents: -33_718_397
        )

        get :banking
        # 18,320.24 - 1,988.53
        expect(response.body).to include("Dashboard figure")
        expect(response.body).to include("$16,331.71")
      end

      # The published figure is the AVAILABLE total, not the posted one — a
      # debit the bank has authorized and not yet posted is money already gone.
      it "publishes the available total, not the posted balance" do
        checking.update!(kind: :checking, available_balance_cents: 1_692_699)

        get :banking
        # 16,926.99 - 1,988.53 is the headline; the posted total sits beside it
        expect(SimpleFin::DashboardCache.balance_cents).to eq(1_633_171)
        expect(response.body).to include("$14,938.46")
        expect(response.body).to include("$16,331.71 balance")
      end

      # The headline column reads down to its own total rather than stopping at
      # the rows, and it is netted against the cards the same way.
      it "totals the headline column" do
        checking.update!(kind: :checking, available_balance_cents: 1_800_000)

        get :banking
        # 18,000.00 - 1,988.53
        expect(response.body).to include("$16,011.47")
      end

      it "marks every account that counts toward the figure" do
        checking.update!(kind: :checking)
        loan = BankAccount.create!(
          simplefin_id: "ACT-M", name: "MORTGAGE LOAN (7153)", last4: "7153",
          kind: :loan, balance_cents: -33_718_397
        )

        get :banking
        marks = %r{<em class="tag primary" title="Counted in the dashboard figure"}
        expect(response.body.scan(marks).size).to eq(2)
        expect(SimpleFin::DashboardCache.included?(loan)).to be(false)
      end

      it "shows a transaction with the category from its linked event" do
        event = ActionEvent.create!(
          user: me, name: "Transaction", timestamp: 1.day.ago,
          data: { amount: 21.48, account: "(...7283)", category: "subscriptions" }
        )
        BankTransaction.create!(
          simplefin_id: "TRN-0001", bank_account: card, action_event: event,
          posted_at: 1.day.ago, amount_cents: -2148, payee: "Netflix"
        )

        get :banking
        expect(response.body).to include("Netflix", "subscriptions")
      end

      # A row with no alert behind it used to be told it could not hold a
      # category at all. Now it offers the same picker every other row does —
      # which is what makes the historical backfill categorizable.
      it "offers a category picker on a row no alert ever covered" do
        BankTransaction.create!(
          simplefin_id: "TRN-0002", bank_account: card,
          posted_at: 1.day.ago, amount_cents: -500, payee: "Mystery"
        )

        get :banking
        expect(response.body).to include("Mystery")
        expect(response.body).not_to include("No linked alert")
        expect(response.body).to include(%(data-field="category"))
      end

      it "counts what is still uncategorized and links straight to it" do
        BankTransaction.create!(
          simplefin_id: "TRN-0002", bank_account: card,
          posted_at: 1.day.ago, amount_cents: -500, payee: "Mystery"
        )

        get :banking
        expect(response.body).to include("1 uncategorized")
        expect(response.body).to include("q=category%3Anone")
      end

      # Read off the transactions now, not the events — the events only cover
      # the fraction of rows an alert email arrived for.
      it "surfaces categories outside the vocabulary" do
        BankTransaction.create!(
          simplefin_id: "TRN-0003", bank_account: card,
          posted_at: 1.day.ago, amount_cents: -100, payee: "Odd",
          category: "Extra Expense"
        )

        get :banking
        expect(response.body).to include("Extra Expense")
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

    # The dates belong to the query, so the pickers are a view onto it: what is
    # typed fills them in, and what is picked is written back.
    describe "the date pickers" do
      it "fills from an explicit range in the query" do
        get :banking, params: { q: "timestamp>=2026-07-01 timestamp<=2026-07-31" }

        expect(response.body).to include(%(data-date-from value="2026-07-01"))
        expect(response.body).to include(%(data-date-to value="2026-07-31"))
      end

      # A bare term names a whole unit, so it sets both ends.
      it "fills both ends from a single month term" do
        get :banking, params: { q: "timestamp:2026-07" }

        expect(response.body).to include(%(data-date-from value="2026-07-01"))
        expect(response.body).to include(%(data-date-to value="2026-07-31"))
      end

      # `>` skips the whole unit named, so the first day actually matched is the
      # 2nd — which is the date a picker has to show.
      it "reports the exclusive operators inclusively" do
        get :banking, params: { q: "timestamp>2026-07-01 timestamp<2026-08-01" }

        expect(response.body).to include(%(data-date-from value="2026-07-02"))
        expect(response.body).to include(%(data-date-to value="2026-07-31"))
      end

      # A negated term names dates to EXCLUDE. That is not a range and has no
      # place in a from/to picker.
      it "ignores a negated timestamp term" do
        get :banking, params: { q: "-timestamp:2026-07" }

        expect(response.body).to include(%(data-date-from value=""))
        expect(response.body).to include(%(data-date-to value=""))
      end

      it "does not fall over on a date it cannot read" do
        get :banking, params: { q: "timestamp>=notadate" }

        expect(response).to have_http_status(:ok)
      end

      # In the search row, not above it — the dates are part of the search. And
      # `basic`, which is what opts them out of the global input rule that
      # forces width:100% and gave each picker a line of its own.
      it "sits inside the search row rather than taking one of its own" do
        get :banking

        row = response.body[%r{<form[^>]*class="basic bank-search".*?</form>}m].to_s
        expect(row).to include("data-date-from")
        expect(row).to include("data-date-to")
        expect(row).to include(%(<input type="date" class="basic"))
      end
    end

    # The legend is the category picker, so it has to list what is NOT on the
    # chart as well as what is.
    describe "the legend" do
      before do
        linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix")
        linked_transaction(cents: -9900, category: "groceries", payee: "Sprouts", id: "TRN-B")
        linked_transaction(cents: -500, category: "eat out", payee: "Cafe", id: "TRN-C")
      end

      def legend
        response.body[%r{<div class="cc-legend bank-legend".*?</div>\s*</details>}m].to_s
      end

      it "lists every category the rest of the search allows" do
        get :banking

        expect(legend).to include("Subscriptions")
        expect(legend).to include("Groceries")
        expect(legend).to include("Eat Out")
      end

      # Pick one category and a chart-derived legend would have nothing left to
      # click. This one keeps offering the others.
      it "keeps offering the categories it is not currently showing" do
        get :banking, params: { q: "category:groceries" }

        expect(legend).to include("Subscriptions")
        expect(legend).to include("Eat Out")
        expect(legend).to include("picked")
      end

      it "ORs a second category in" do
        get :banking, params: { q: "category:groceries" }

        expect(legend).to include(CGI.escapeHTML(
                                    system_banking_path(q: "(category:groceries OR category:subscriptions)"),
                                  ))
      end

      # Half the category names are two words, and `category:eat out` parses as
      # `category:eat` plus a stray bare word that matches nothing.
      it "quotes a category whose name has a space in it" do
        get :banking

        expect(legend).to include(CGI.escapeHTML(system_banking_path(q: %(category:"eat out"))))
      end

      it "drops one category out of the group and leaves the other" do
        get :banking, params: { q: "(category:groceries OR category:subscriptions)" }

        expect(legend).to include(CGI.escapeHTML(system_banking_path(q: "category:subscriptions")))
      end

      # Totals hold still as you pick, because each one says what that category
      # is worth in the rest of the search — the number you are choosing between.
      # Nothing picked is not "nothing selected" — it is everything, so the
      # legend must not render itself as if it were all switched off.
      it "does not dim itself when nothing is picked" do
        get :banking
        expect(legend).to include(%(data-any-picked="false"))

        get :banking, params: { q: "category:groceries" }
        expect(legend).to include(%(data-any-picked="true"))
      end

      it "totals each category over the wider set, not over the picked one" do
        get :banking, params: { q: "category:groceries" }

        expect(legend).to include("$21.48")
        expect(legend).to include("$99.00")
      end
    end

    # The bucket is a way of looking at the results rather than a filter, so it
    # rides as its own param.
    # The bucket is a way of looking at the results rather than a filter, so it
    # rides as its own param.
    describe "the over-time chart" do
      before { linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix") }

      it "buckets by month unless told otherwise" do
        get :banking

        expect(response.body).to include(%(<option selected="selected" value="month">Month</option>))
      end

      # The select lives inside the chart and belongs to the search form by id.
      # Without the id on the form it submits nothing and the picker is inert.
      it "hangs the bucket picker off the search form" do
        get :banking

        expect(response.body).to include(%(id="bank-search-form"))
        expect(response.body).to include(%(form="bank-search-form"))
      end

      it "takes the bucket from the params" do
        get :banking, params: { bucket: "week" }

        expect(response.body).to include(%(<option selected="selected" value="week">Week</option>))
      end

      it "ignores a bucket it does not have" do
        get :banking, params: { bucket: "fortnight" }

        expect(response.body).to include(%(<option selected="selected" value="month">Month</option>))
      end

      # The chart is a view of what the SEARCH matched, which is the whole
      # reason it is on this page rather than being a saved chart.
      it "charts only the rows the search matched" do
        linked_transaction(cents: -9900, category: "groceries", payee: "Sprouts", id: "TRN-B")

        get :banking, params: { q: "payee:sprouts" }
        payload = JSON.parse(response.body[%r{data-bank-chart-payload>(.*?)</script>}m, 1])

        expect(payload["datasets"].pluck("label")).to eq(["Groceries"])
      end

      # A non-default bucket has to survive every link that rebuilds the page,
      # or clicking an account silently resets the view.
      it "carries a non-default bucket through the account filter links" do
        get :banking, params: { bucket: "week" }

        expect(response.body).to include("bucket=week")
      end
    end

    # Clicking an account adds it to the listing without discarding what was
    # already typed — and clicking the same one again takes it back out.
    describe "picking accounts" do
      it "offers each account a filter that keeps the rest of the search" do
        get :banking, params: { q: "payee:amazon" }

        expect(response.body).to include(
          %(data-filter-url="/system/banking?q=payee%3Aamazon+account%3A2363"),
        )
      end

      # Two bare account terms AND together and match nothing, so several
      # picked accounts have to become one ORed group. Built in table order,
      # not click order, so the same pair always reads the same way.
      it "ORs a second account in rather than ANDing or replacing it" do
        get :banking, params: { q: "account:7283" }

        expect(response.body).to include(
          %(data-filter-url="/system/banking?q=%28account%3A2363+OR+account%3A7283%29"),
        )
      end

      # And the OR group has to come back OUT whole — leaving the parentheses
      # and the OR behind would not parse.
      it "drops one account out of the group and leaves the other" do
        get :banking, params: { q: "(account:2363 OR account:7283) payee:amazon" }

        expect(response.body).to include(
          %(data-filter-url="/system/banking?q=payee%3Aamazon+account%3A7283"),
        )
        expect(response.body.scan(%(class="picked")).size).to eq(2)
      end

      it "clears the filter when the only account picked is clicked" do
        get :banking, params: { q: "account:2363 payee:amazon" }

        expect(response.body).to include(%(data-filter-url="/system/banking?q=payee%3Aamazon"))
        expect(response.body).to include(%(class="picked"))
      end

      it "takes the negation with it rather than orphaning the operator" do
        get :banking, params: { q: "-account:7283 payee:amazon" }

        expect(response.body).to include(
          %(data-filter-url="/system/banking?q=payee%3Aamazon+account%3A2363"),
        )
      end

      # Last four is the only key that cannot also match a second account, so
      # an account without one gets no filter rather than one that quietly
      # widens to two.
      it "gives an account with no last four no filter at all" do
        BankAccount.create!(
          simplefin_id: "ACT-X", name: "Mystery", kind: :savings, balance_cents: 100,
        )

        get :banking
        expect(response.body).to include(%(data-filter-url=""))
      end
    end

    # Most visits are not about the bars, and open they pushed the transactions
    # themselves off the first screen.
    it "keeps the spending chart in a drawer that starts closed" do
      linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix")

      get :banking
      expect(response.body).to include(%(<details class="bank-drawer bank-chart">))
      expect(response.body).not_to include(%(<details class="bank-drawer bank-chart" open))
    end

    # A rare, deliberate action. As a permanent row of controls above the table
    # it read as a second search bar and cost the page a band of space on every
    # visit.
    describe "the bulk category form" do
      before { linked_transaction(cents: -2148, category: "subscriptions", payee: "Netflix") }

      it "lives in a modal rather than a bar above the table" do
        get :banking

        expect(response.body).to include(%(data-modal="#bank-bulk"))
        expect(response.body).to include(%(id="bank-bulk"))
        expect(response.body).to include("modal-wrapper hidden")
        expect(response.body).not_to include("Set category on selected")
      end

      # The checkboxes stay in the table and reach the form by id, so the form
      # sitting inside a closed modal changes nothing about what submits.
      it "still reaches the row checkboxes through form association" do
        get :banking

        expect(response.body).to include(%(form="bank-bulk-form"))
        expect(response.body).to include(%(class="basic bank-bulk"))
      end
    end

    # A reference, not an explanation. What matters is that the values it lists
    # come FROM the code that accepts them, so it cannot describe a vocabulary
    # the search no longer has.
    describe "the search syntax reference" do
      it "lists every category the search accepts, and `none`" do
        get :banking

        TransactionCategory::ALL.each { |category| expect(response.body).to include(category.to_s) }
        expect(response.body).to include("none")
      end

      it "lists the words `direction` actually accepts" do
        get :banking

        (BankTransaction::WITHDRAWAL_WORDS + BankTransaction::DEPOSIT_WORDS).each { |word|
          expect(response.body).to include(word)
        }
      end

      it "names every searchable field with an example" do
        get :banking

        %w[
          payee
          memo
          description
          category
          account
          amount
          timestamp
          posted_at
          transacted_at
          direction
          pending
          linked
          transfer
          id
          simplefin_id
].each { |field|
  expect(response.body).to include(field)
}
      end

      # A real search term, but SimpleFIN never sends one — every row is nil, so
      # documenting it would send you looking for something that cannot match.
      it "says nothing about mcc" do
        get :banking

        expect(response.body).not_to include("mcc")
      end

      # A reminder you go and get, not something to read past every visit.
      it "starts collapsed" do
        get :banking

        expect(response.body).to include(%(<details class="bank-drawer bank-syntax">))
        expect(response.body).not_to include(%(<details class="bank-drawer bank-syntax" open))
      end
    end

    # Two rows that read the same on screen are what you most need to tell
    # apart, and the ids are the way to go and find either record.
    describe "the identity tooltip" do
      it "names the records behind the row, in the form you would type" do
        row = linked_transaction(cents: -970, category: "fun", payee: "Arcade")
        row.action_event.update!(data: row.action_event.data.merge("email_id" => 51_450))

        get :banking

        expect(response.body).to include(
          %(title="BankTransaction##{row.id} ActionEvent##{row.action_event_id} Email#51450"),
        )
      end

      # A 36-character UUID identifies the row already being looked at.
      it "does not print the SimpleFIN id" do
        linked_transaction(cents: -970, category: "fun", payee: "Arcade")

        get :banking

        expect(response.body).not_to include("SimpleFIN TRN-A")
      end
    end

    describe "the metadata drawer" do
      it "shows what is known about the purchase, grouped by source" do
        row = linked_transaction(cents: -970, category: "fun", payee: "Arcade")
        row.update!(metadata: {
          "amazon" => { "order_id" => "112-6608200-0828238", "asins" => %w[B0C1XLC962 B07VWX9DMJ] },
        })

        get :banking

        expect(response.body).to include("112-6608200-0828238")
        # Arrays read as a list rather than as Ruby's inspect output.
        expect(response.body).to include("B0C1XLC962, B07VWX9DMJ")
        expect(response.body).to include("order id", "Amazon")
      end

      # Rendered with the row and hidden, so opening it cannot fail.
      it "starts closed" do
        row = linked_transaction(cents: -970, category: "fun", payee: "Arcade")
        row.update!(metadata: { "amazon" => { "order_id" => "112-1" } })

        get :banking

        expect(response.body).to include(%(<tr class="bank-meta-row hidden" data-meta-row>))
      end

      # A button that opens an empty drawer is worse than no button.
      it "offers no button on a row with no metadata" do
        linked_transaction(cents: -970, category: "fun", payee: "Arcade")

        get :banking

        # Matched on the markup, not the bare attribute name: the page's own
        # JS mentions `[data-meta-toggle]` and would satisfy a looser check.
        expect(response.body).not_to include(%(<button type="button" class="tag meta"))
        expect(response.body).not_to include(%(<tr class="bank-meta-row))
      end
    end

    it "renders cents to two places, never truncated" do
      linked_transaction(cents: -970, category: "fun", payee: "Arcade")

      get :banking
      expect(response.body).to include("-$9.70")
      expect(response.body).not_to include("-$9.7<")
    end

    it "delimits thousands" do
      linked_transaction(cents: -1_234_567, category: "home", payee: "Roofer")

      get :banking
      expect(response.body).to include("-$12,345.67")
    end

    it "shows the local time alongside the date" do
      linked_transaction(cents: -500, category: "fun", payee: "Arcade")

      get :banking
      # 21:15 UTC is 3:15 PM Mountain.
      expect(response.body).to include("Aug 10, 2026")
      expect(response.body).to include("3:15 PM")
    end

    it "renders account kinds titleized rather than as enum values" do
      checking.update!(kind: :checking)

      get :banking
      expect(response.body).to include("Checking")
    end

    it "renders categories titleized" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway")

      get :banking
      expect(response.body).to include("Eat Out")
    end

    it "narrows the list with a search" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway", id: "TRN-A")
      linked_transaction(
        cents: -999, category: "groceries", payee: "Costco",
        id: "TRN-B", at: Time.utc(2026, 8, 9, 18, 0)
      )

      get :banking, params: { q: "payee:subway" }
      expect(response.body).to include("Subway")
      expect(response.body).not_to include("Costco")
    end

    # The tokenizer is lenient and rarely raises, so this drives the rescue
    # directly. What matters is that a query which DOES blow up surfaces the
    # message and shows nothing — falling back to every row would read as
    # "your filter matched everything".
    it "reports a failed search instead of returning everything" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway")
      allow(BankTransaction).to receive(:query).and_raise(StandardError, "bad token")

      get :banking, params: { q: "payee:whatever" }
      expect(response.body).to include("Could not parse that search", "bad token")
      expect(response.body).not_to include("Subway")
    end

    it "totals the filtered set" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway")

      get :banking
      expect(response.body).to include("Spent")
    end

    it "charts spending by category" do
      linked_transaction(cents: -2148, category: "eat out", payee: "Subway")

      get :banking
      expect(response.body).to include("Spending by category")
      # The category's established color, reused so it matches CustomChart 4.
      expect(response.body).to include("#D95926")
    end

    it "paginates rather than dumping everything" do
      get :banking
      expect(response.body).to include("bank-pagination")
    end

    it "stacks the date and time as separate spans" do
      linked_transaction(cents: -500, category: "fun", payee: "Arcade")

      get :banking
      expect(response.body).to include(%(<span class="date">Aug 10, 2026</span>))
      expect(response.body).to include(%(<span class="time">3:15 PM</span>))
    end

    # A text input here inherits the global 18px/2px-border/full-width rule and
    # renders as a large box; a contenteditable span reads as plain text.
    it "edits the memo in place rather than with a form input" do
      linked_transaction(cents: -500, category: "fun", payee: "Arcade")

      get :banking
      expect(response.body).to include(%(data-text data-field="memo"))
      expect(response.body).to include("contenteditable")
      expect(response.body).not_to include(%(<input type="text" data-memo))
    end

    # Account moved under the payee and its own column went away, so the row
    # has one fewer cell and the responsive rule had to move with it.
    it "stacks the account under the payee instead of in its own column" do
      linked_transaction(cents: -500, category: "fun", payee: "Arcade")

      get :banking
      expect(response.body).to include(%(<span class="acct">AMZ Prime (7283)</span>))
      # No Account column between Payee and Memo. Matched on the pair, not on
      # "<th>Account</th>" being absent from the page — the accounts table
      # above has a header by that name and always will.
      expect(response.body).to match(%r{<th>Payee</th>\s*<th>Memo</th>})
    end

    # Both halves of a pair are the same money. Listed twice they read as a
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

      it "pairs the two halves" do
        expect(out.reload.transfer_counterpart).to eq(incoming)
        expect(out).to be_transfer_source
      end

      # Both ends, not just the destination. Asserted as one string so a route
      # that renders the institution's own name on either side fails here —
      # "AMZ Prime (7283) → Mortgage" is exactly the mismatch this catches.
      it "shows the route in friendly names, on the leaving side" do
        get :banking

        expect(response.body).to include(%(Prime<span class="arrow">→</span>Mortgage))
        expect(response.body).not_to include("AMZ Prime (7283)<span")
        expect(response.body).not_to include(%(<em class="tag xfer"))
      end

      it "hides the arriving half" do
        get :banking

        expect(response.body).to include("Payment Sent")
        expect(response.body).not_to include("Payment Received")
      end

      it "counts the pair once" do
        get :banking
        expect(response.body).to include(%(<span class="bank-totals-label">Results</span>1</div>))
      end

      # Hiding a row must not make it unfindable — the only row left showing
      # the mortgage payment is the one on the card.
      it "finds the pair by the account it went to" do
        get :banking, params: { q: "account:mortgage" }

        expect(response.body).to include("Payment Sent")
        expect(response.body).to include(%(<span class="bank-totals-label">Results</span>1</div>))
      end

      # No counterpart to name, so the chip is still the only thing to show.
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

    # About a third of rows arrive as a date with no clock time, which reaches
    # us as midnight UTC and would print as "6:00 AM" — a precise answer to a
    # question the bank never answered.
    describe "the When column" do
      it "shows the time when the bank gave one" do
        BankTransaction.create!(
          simplefin_id: "TIMED", bank_account: card, payee: "Arcade",
          amount_cents: -500, posted_at: Time.utc(2026, 8, 10, 22, 31),
          transacted_at: Time.utc(2026, 8, 10, 22, 31)
        )

        get :banking
        expect(response.body).to include(%(<span class="time">4:31 PM</span>))
      end

      it "shows the date alone when it did not" do
        BankTransaction.create!(
          simplefin_id: "DATEONLY", bank_account: card, payee: "Arcade",
          amount_cents: -500, posted_at: Time.utc(2026, 8, 10),
          transacted_at: Time.utc(2026, 8, 10)
        )

        get :banking
        # Asserted on the cell, not the page. A bare `include("Aug 10, 2026")`
        # passed against the backfill note while the cell said something else
        # entirely, which is how the off-by-one survived a green suite.
        expect(response.body).to include(%(<span class="date">Aug 10, 2026</span>))
        expect(response.body).not_to include(%(<span class="time">))
      end

      # The bug this whole normalization exists for: the bank said Aug 10 and
      # the table said Aug 9, because a date-only row arrives at midnight UTC
      # and Mountain reads that as 6pm the day before.
      it "does not slip a date-only row back a day" do
        BankTransaction.create!(
          simplefin_id: "DATEONLY", bank_account: card, payee: "Arcade",
          amount_cents: -500, posted_at: Time.utc(2026, 8, 10),
          transacted_at: Time.utc(2026, 8, 10)
        )

        get :banking
        expect(response.body).not_to include(%(<span class="date">Aug 9, 2026</span>))
      end
    end

    describe "the backfill progress bar" do
      # Asserted on the markup, not the class name — the stylesheet ships on
      # every render and would match either way.
      it "says nothing before anything has synced" do
        get :banking
        expect(response.body).not_to include(%(<div class="bank-progress">))
      end

      it "draws a partial bar and how far back it has reached" do
        linked_transaction(cents: -500, category: "fun", payee: "Arcade")
        DataStorage[SimpleFin::Backfill::STORAGE_KEY] = {
          cursor: Time.utc(2024, 2, 16).iso8601, empty_runs: 0, done: false
        }

        get :banking
        expect(response.body).to match(/bank-progress-fill" *\n? *style="width: \d+%;/)
        expect(response.body).to include("Feb 16, 2024")
        expect(response.body).to include("to go")
      end

      it "fills the bar and says so when there is nothing older left" do
        linked_transaction(cents: -500, category: "fun", payee: "Arcade")
        DataStorage[SimpleFin::Backfill::STORAGE_KEY] = {
          cursor: Time.utc(2019, 5, 1).iso8601, empty_runs: 2, done: true
        }

        get :banking
        expect(response.body).to include("bank-progress-fill done")
        expect(response.body).to include("width: 100%")
        expect(response.body).to include("Complete — nothing older to fetch")
        expect(response.body).to include("100%")
      end

      # An implementation detail of when to stop, not something a bar needs to
      # justify itself with.
      it "does not explain its own stopping rule" do
        linked_transaction(cents: -500, category: "fun", payee: "Arcade")
        DataStorage[SimpleFin::Backfill::STORAGE_KEY] = {
          cursor: Time.utc(2024, 2, 16).iso8601, empty_runs: 0, done: false
        }

        get :banking
        expect(response.body).not_to include("come back empty")
      end
    end

    it "colors a negative amount" do
      linked_transaction(cents: -500, category: "fun", payee: "Arcade")

      get :banking
      expect(response.body).to include(%(class="right neg"))
      expect(response.body).to include(".bank-table td.neg")
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

    it "sets one row's category and answers with its color" do
      patch :update_transaction, params: { id: linked.id, category: "subscriptions" }

      expect(linked.reload.category).to eq("subscriptions")
      expect(response.parsed_body["color"]).to eq(TransactionCategory.color("subscriptions"))
    end

    it "refuses a category outside the vocabulary" do
      patch :update_transaction, params: { id: linked.id, category: "Extra Expense" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/not one of the 22/)
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

    it "categorizes the selected rows" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id], category: "subscriptions"
      }

      expect(linked.reload.category).to eq("subscriptions")
    end

    it "writes through to the ActionEvent, not a second copy" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id], category: "subscriptions"
      }

      expect(event.reload.data["category"]).to eq("subscriptions")
    end

    # Nothing gets skipped any more — an unlinked row holds its own category,
    # so a bulk pick reaches every row in the selection.
    it "categorizes linked and unlinked rows alike" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id, unlinked.id], category: "subscriptions"
      }

      expect(flash[:notice]).to include("Categorised 2")
      expect(flash[:notice]).not_to include("skipped")
      expect(unlinked.reload.category).to eq("subscriptions")
    end

    it "refuses a category outside the vocabulary" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id], category: "Extra Expense"
      }

      expect(flash[:alert]).to eq("Unknown category.")
      expect(linked.reload.category).to eq("other")
    end

    it "applies across a whole search when asked" do
      linked
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
    end

    it "leaves rows outside the search alone" do
      linked
      untouched_event = ActionEvent.create!(
        user: me, name: "Transaction", timestamp: 1.day.ago,
        data: { amount: 5.0, account: "(...7283)", category: "groceries" }
      )
      BankTransaction.create!(
        simplefin_id: "TRN-D", bank_account: card, action_event: untouched_event,
        posted_at: 1.day.ago, amount_cents: -500, payee: "Costco"
      )

      patch :bulk_update_transactions, params: {
        q: "payee:netflix", apply_to_search: "1", category: "subscriptions"
      }

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

    it "sets the kind" do
      patch :update_bank_account, params: { id: checking.id, kind: :checking }

      expect(checking.reload).to be_checking
    end

    # The dashboard reads a cache key, not the table, so designating checking
    # has to republish or the home cell stays stale until the next sync.
    it "republishes the dashboard balance when the kind changes" do
      expect(SimpleFin::DashboardCache).to receive(:refresh!)

      patch :update_bank_account, params: { id: checking.id, kind: :checking }
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
