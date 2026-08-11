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
        expect(response.body).to include("$18320.24")
        expect(response.body).to include("-$1988.53")
      end

      it "warns while an account is still unclassified" do
        get :banking
        expect(response.body).to include("still unclassified")
      end

      it "hides the available balance on a card, where it is a placeholder" do
        checking.update!(kind: :checking)

        get :banking
        expect(response.body).to include("$18320.24 available")
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
