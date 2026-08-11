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

      it "hides the available balance on a card, where it is a placeholder" do
        checking.update!(kind: :checking)

        get :banking
        expect(response.body).to include("$18,320.24 available")
        expect(response.body).not_to include("$0.0 available")
      end

      it "marks which account feeds the dashboard" do
        checking.update!(kind: :checking)

        get :banking
        expect(response.body).to include("dashboard balance")
      end

      it "says so when nothing is designated checking" do
        checking.update!(kind: :savings)
        get :banking

        expect(response.body).to include("has nothing to read")
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

      it "flags an unlinked transaction rather than showing a blank category" do
        BankTransaction.create!(
          simplefin_id: "TRN-0002", bank_account: card,
          posted_at: 1.day.ago, amount_cents: -500, payee: "Mystery"
        )

        get :banking
        expect(response.body).to include("unlinked")
      end

      it "surfaces categories outside the vocabulary" do
        ActionEvent.create!(
          user: me, name: "Transaction", timestamp: 1.day.ago,
          data: { amount: 1, category: "Extra Expense" }
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
        posted_at: at, transacted_at: at, amount_cents: cents, payee: payee
      )
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
      expect(response.body).to include(%(class="memo-text"))
      expect(response.body).to include("contenteditable")
      expect(response.body).not_to include(%(<input type="text" data-memo))
    end

    # Account moved under the payee and its own column went away, so the row
    # has one fewer cell and the responsive rule had to move with it.
    it "stacks the account under the payee instead of in its own column" do
      linked_transaction(cents: -500, category: "fun", payee: "Arcade")

      get :banking
      expect(response.body).to include(%(<span class="acct">AMZ Prime (7283)</span>))
      expect(response.body).not_to include("<th>Account</th>")
    end

    it "marks a transfer as a tag, distinct from the account text" do
      other = BankAccount.create!(
        simplefin_id: "ACT-9", name: "MORTGAGE LOAN (7153)", last4: "7153"
      )
      out = BankTransaction.create!(
        simplefin_id: "TRN-OUT", bank_account: card,
        posted_at: 1.day.ago, transacted_at: 1.day.ago, amount_cents: -139_325
      )
      BankTransaction.create!(
        simplefin_id: "TRN-IN", bank_account: other,
        posted_at: 1.day.ago, transacted_at: 1.day.ago, amount_cents: 139_325
      )
      SimpleFin::TransferDetector.call
      expect(out.reload).to be_transfer

      get :banking
      expect(response.body).to include(%(<em class="tag xfer"))
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
        posted_at: 1.day.ago, amount_cents: -2148, payee: "Netflix"
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

    it "explains that an unlinked row has nowhere to hold a category" do
      patch :update_transaction, params: { id: unlinked.id, category: "groceries" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/No linked event/)
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
        posted_at: 1.day.ago, amount_cents: -2148, payee: "Netflix"
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

    # `txn.category = x` would evaluate to x regardless of the method's return,
    # so the skip count would silently read zero.
    it "counts rows it could not categorize" do
      patch :bulk_update_transactions, params: {
        transaction_ids: [linked.id, unlinked.id], category: "subscriptions"
      }

      expect(flash[:notice]).to include("Categorised 1")
      expect(flash[:notice]).to include("1 skipped")
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
      patch :update_bank_account, params: {
        id: checking.id, bank_account: { friendly_name: "Main Checking" }
      }

      expect(checking.reload.friendly_name).to eq("Main Checking")
    end

    it "sets the kind" do
      patch :update_bank_account, params: {
        id: checking.id, bank_account: { kind: :checking }
      }

      expect(checking.reload).to be_checking
    end

    # The dashboard reads a cache key, not the table, so designating checking
    # has to republish or the home cell stays stale until the next sync.
    it "republishes the dashboard balance when the kind changes" do
      expect(SimpleFin::DashboardCache).to receive(:refresh!)

      patch :update_bank_account, params: {
        id: checking.id, bank_account: { kind: :checking }
      }
    end

    it "rejects a kind outside the enum" do
      expect {
        patch :update_bank_account, params: {
          id: checking.id, bank_account: { kind: "wire-transfers" }
        }
      }.to raise_error(ArgumentError)
    end

    it "is not reachable by a standard user" do
      sign_in standard

      patch :update_bank_account, params: {
        id: checking.id, bank_account: { friendly_name: "Nope" }
      }

      expect(response).to have_http_status(:not_found)
      expect(checking.reload.friendly_name).to be_nil
    end
  end
end
