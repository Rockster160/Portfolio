require "rails_helper"

RSpec.describe Jil::Methods::Chore, type: :service do
  let(:user) { create(:user) }
  let!(:vitamins) { create(:chore, created_by_user: user, name: "Vitamins", reward_pebbles: 1) }
  let!(:floss) { create(:chore, created_by_user: user, name: "Floss",  reward_pebbles: 1) }

  # Minimal Jil double — `@jil.user` is the only contract this module
  # leans on, so a struct stands in for the full executor.
  let(:jil_stub) { instance_double("Jil::Executor", user: user, ctx: nil) }
  subject(:methods) { described_class.new(jil_stub) }

  it "find('Vit') returns the matching chore" do
    expect(methods.find("Vit")).to eq(vitamins)
  end

  it "complete creates a completion and returns it" do
    expect { methods.complete("Vitamins") }.to change(ChoreCompletion, :count).by(1)
    completion = ChoreCompletion.order(:id).last
    expect(completion.chore_id).to eq(vitamins.id)
    expect(completion.user_id).to eq(user.id)
  end

  it "complete with a timestamp records the supplied time" do
    when_at = Time.zone.local(2026, 4, 1, 7, 30, 0)
    methods.complete("Floss", when_at.iso8601)
    completion = ChoreCompletion.order(:id).last
    expect(completion.completed_at.to_i).to eq(when_at.to_i)
  end

  it "uncomplete destroys today's most recent completion" do
    ChoreCompleter.new(vitamins, user).call
    expect { methods.uncomplete("Vitamins") }.to change(ChoreCompletion, :count).by(-1)
  end

  it "balance + today_earnings reflect completions" do
    ChoreCompleter.new(vitamins, user).call
    expect(methods.balance).to eq(1)
    expect(methods.today_earnings).to eq(1)
  end

  describe "#withdraw" do
    before { 5.times { ChoreCompleter.new(vitamins, user).call } }

    it "creates a withdrawal and returns it" do
      record = methods.withdraw(3, "snack")
      expect(record).to be_a(ChoreWithdrawal)
      expect(record.amount_pebbles).to eq(3)
      expect(record.note).to eq("snack")
      expect(user.reload.chore_balance).to eq(2) # 5 earned - 3 withdrawn
    end

    it "returns nil for non-positive amounts" do
      expect(methods.withdraw(0)).to be_nil
      expect(methods.withdraw(-1)).to be_nil
    end
  end

  describe "#transfer" do
    let(:recipient) { create(:user) }
    before do
      share_chore_household!(user, recipient)
      20.times { ChoreCompleter.new(vitamins, user).call }
    end

    it "transfers pebbles to a household user resolved by username" do
      record = methods.transfer(7, recipient.username, "thx")
      expect(record).to be_a(ChoreTransfer)
      expect(record.to_user_id).to eq(recipient.id)
      expect(record.amount_pebbles).to eq(7)
      expect(user.reload.chore_balance).to eq(13)
      expect(recipient.reload.chore_balance).to eq(7)
    end

    it "accepts a numeric recipient id" do
      record = methods.transfer(2, recipient.id)
      expect(record&.to_user_id).to eq(recipient.id)
    end

    it "returns nil for a non-household recipient" do
      stranger = create(:user)
      expect(methods.transfer(5, stranger.username)).to be_nil
    end

    it "returns nil for an unknown user" do
      expect(methods.transfer(5, "nobody-by-that-name")).to be_nil
    end
  end

  describe "#history" do
    let(:recipient) { create(:user) }
    before { share_chore_household!(user, recipient) }

    it "returns the user's completions + withdrawals + transfers, newest first" do
      # Earn enough for both the withdrawal and the transfer.
      5.times { ChoreCompleter.new(vitamins, user).call }
      create(:chore_withdrawal, user: user, amount_pebbles: 2, note: "w")
      create(:chore_transfer, from_user: user, to_user: recipient, amount_pebbles: 1, note: "t")
      rows = methods.history(nil, nil, :desc)
      kinds = rows.map { |r| r[:kind] }
      expect(kinds).to include("completion", "withdrawal", "transfer")
      transfer = rows.find { |r| r[:kind] == "transfer" }
      expect(transfer[:direction]).to eq("outgoing")
      expect(transfer[:counterparty_username]).to eq(recipient.username)
    end

    it "honours the limit and clamps it to 100" do
      30.times { create(:chore_withdrawal, user: user, amount_pebbles: 1) }
      expect(methods.history(nil, 10, :desc).size).to eq(10)
      expect(methods.history(nil, 10_000, :desc).size).to be <= 100
    end

    it "filters via tokenized query — `amount>N` works across all three feeds" do
      # Earn enough that the withdrawal + transfer validations clear.
      30.times { ChoreCompleter.new(vitamins, user).call }
      create(:chore_withdrawal, user: user, amount_pebbles: 1, note: "small")
      create(:chore_withdrawal, user: user, amount_pebbles: 9, note: "big")
      big_chore = create(:chore, created_by_user: user, name: "Big", reward_pebbles: 10)
      create(:chore_completion, chore: big_chore, user: user, paid_pebbles: 10, base_pebbles: 10)
      create(:chore_transfer, from_user: user, to_user: recipient, amount_pebbles: 7, note: "t")

      kept = methods.history("amount>5", nil, :desc)
      amounts = kept.map { |e| e[:amount_pebbles] || e[:paid_pebbles] }.compact.uniq.sort
      expect(amounts).to eq([7, 9, 10])
    end

    it "honours order :asc" do
      first = create(:chore_withdrawal, user: user, amount_pebbles: 1, created_at: 3.days.ago)
      last  = create(:chore_withdrawal, user: user, amount_pebbles: 2, created_at: 1.day.ago)
      asc = methods.history(nil, nil, :asc).map { |r| r[:id] }
      expect(asc.index(first.id)).to be < asc.index(last.id)
    end
  end

  describe "#complete_for" do
    let(:other) { create(:user, username: "Alchemibluum") }
    before { share_chore_household!(user, other) }

    it "credits the chosen user with the completion" do
      expect { methods.complete_for(vitamins, other.username) }.to change { other.chore_completions.count }.by(1)
      completion = ChoreCompletion.order(:id).last
      expect(completion.user_id).to eq(other.id)
      expect(completion.chore_id).to eq(vitamins.id)
    end

    it "uses the supplied timestamp" do
      when_at = Time.zone.local(2026, 4, 1, 7, 30, 0)
      methods.complete_for(vitamins, other.username, when_at.iso8601)
      completion = ChoreCompletion.order(:id).last
      expect(completion.completed_at.to_i).to eq(when_at.to_i)
    end

    it "returns nil for an unknown user" do
      expect(methods.complete_for(vitamins, "no-such-user")).to be_nil
    end

    it "returns nil for an unknown chore" do
      expect(methods.complete_for("nope", other.username)).to be_nil
    end
  end

  describe "#add" do
    before do
      allow(jil_stub).to receive(:cast) { |val, type|
        case type
        when :Hash    then val.is_a?(Hash) ? val : {}
        when :Boolean then ::ActiveModel::Type::Boolean.new.cast(val)
        when :Numeric then val.to_i
        else val
        end
      }
    end

    it "creates a chore from a minimal hash" do
      record = methods.add({ name: "Buy Milk" })
      expect(record).to be_a(Chore)
      expect(record.persisted?).to be true
      expect(record.name).to eq("Buy Milk")
      expect(record.created_by_user_id).to eq(user.id)
      expect(record.sharing_mode).to eq("personal")
    end

    it "returns nil and does not create when name is blank" do
      expect { methods.add({ name: "" }) }.not_to change(Chore, :count)
      expect(methods.add({ name: "  " })).to be_nil
    end

    it "honours sharing_mode :household" do
      record = methods.add({ name: "Trash", sharing_mode: "household", one_off: true })
      expect(record).to be_persisted
      expect(record.sharing_mode).to eq("household")
      expect(record.one_off).to be true
    end

    it "resolves assigned_to by username + leaves sharing_mode :personal" do
      other = create(:user, username: "Alchemibluum")
      record = methods.add({ name: "Vitamins", assigned_to: other.username })
      expect(record).to be_persisted
      expect(record.sharing_mode).to eq("personal")
      expect(record.assigned_to_user_id).to eq(other.id)
    end

    it "resolves assigned_to by id" do
      other = create(:user)
      record = methods.add({ name: "Vitamins", assigned_to: other.id })
      expect(record).to be_persisted
      expect(record.assigned_to_user_id).to eq(other.id)
    end

    it "sets starts_on from an iso8601 timestamp" do
      record = methods.add({ name: "Yardwork", starts_on: "2026-07-04T09:00:00-06:00" })
      expect(record.starts_on).to eq(Date.new(2026, 7, 4))
    end
  end

  describe "#update" do
    before do
      allow(jil_stub).to receive(:cast) { |val, type|
        case type
        when :Hash    then val.is_a?(Hash) ? val : {}
        when :Boolean then ::ActiveModel::Type::Boolean.new.cast(val)
        when :Numeric then val.to_i
        else val
        end
      }
    end

    it "updates show_on_today_view from a ChoreData hash" do
      record = methods.update("Vitamins", { show_on_today_view: "always" })
      expect(record.id).to eq(vitamins.id)
      expect(record.show_on_today_view).to eq("always")
    end

    it "round-trips :always → :never" do
      methods.update("Vitamins", { show_on_today_view: "always" })
      methods.update("Vitamins", { show_on_today_view: "never" })
      expect(vitamins.reload.show_on_today_view).to eq("never")
    end

    it "drops an unknown show_on_today_view value rather than raising" do
      record = methods.update("Vitamins", { show_on_today_view: "bogus" })
      expect(record.show_on_today_view).to eq(vitamins.show_on_today_view)
    end

    it "legacy ChoreData.show_on_daily_view emits the new attribute key" do
      # Backward-compat for prod Jil tasks pre-rename. `ChoreData.show_on_daily_view(...)`
      # in Jil code dispatches to the alias and must return a hash keyed by the new
      # `show_on_today_view` attr so the chore update path picks it up.
      expect(methods.show_on_daily_view("always")).to eq({ show_on_today_view: "always" })
    end

    it "updates name + starts_on together" do
      record = methods.update("Vitamins", { name: "Multivitamins", starts_on: "2026-07-04" })
      expect(record.name).to eq("Multivitamins")
      expect(record.starts_on).to eq(Date.new(2026, 7, 4))
    end

    it "returns the chore unchanged for an empty attrs hash" do
      record = methods.update("Vitamins", {})
      expect(record.id).to eq(vitamins.id)
      expect(vitamins.reload.name).to eq("Vitamins")
    end

    it "returns nil for an unknown chore" do
      expect(methods.update("nope-no-chore", { show_on_today_view: "always" })).to be_nil
    end
  end
end
