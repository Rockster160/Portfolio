require "rails_helper"

RSpec.describe SimpleFin::EventMatcher do
  # The email alert lands first and carries the category; SimpleFIN reports the
  # same charge up to a day later. These pin down that a link only happens when
  # it is unambiguous.
  describe "matching" do
    let(:user) { User.me }
    let(:account) {
      BankAccount.create!(
        simplefin_id: "ACT-0001",
        name:         "Chase Sapphire Preferred (8257)",
        last4:        "8257",
        kind:         :credit,
      )
    }

    def event(amount:, at:, account_label: "Chase Sapphire Preferred Visa (...8257)", category: "eat out")
      ActionEvent.create!(
        user:      user,
        name:      "Transaction",
        timestamp: at,
        data:      {
          amount:   amount,
          account:  account_label,
          category: category,
          merchant: "TST* HOUSTON S HOT C",
        },
      )
    end

    def transaction(amount_cents:, at:, simplefin_id: "TRN-0001", on: account)
      BankTransaction.create!(
        simplefin_id:  simplefin_id,
        bank_account:  on,
        posted_at:     at,
        transacted_at: at,
        amount_cents:  amount_cents,
        description:   "TST* HOUSTON S HOT C",
      )
    end

    it "links a charge to the alert that described it" do
      matching = event(amount: 29.72, at: 2.days.ago)
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      result = described_class.call

      expect(row.reload.action_event).to eq(matching)
      expect(result.linked).to eq(1)
    end

    it "carries the category through without copying it" do
      event(amount: 29.72, at: 2.days.ago, category: "groceries")
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      described_class.call
      expect(row.reload.category).to eq("groceries")
    end

    it "matches across the account label spellings the events actually use" do
      matching = event(amount: 29.72, at: 2.days.ago, account_label: "(...8257)")
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      described_class.call
      expect(row.reload.action_event).to eq(matching)
    end

    # `ambiguous` counts the ones that needed settling now, not the ones given
    # up on — nothing is given up on, because the alternative is a duplicate.
    it "takes the closest alert when two could explain a charge" do
      event(amount: 29.72, at: 2.days.ago)
      closest = event(amount: 29.72, at: 1.day.ago)
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      result = described_class.call

      expect(row.reload.action_event).to eq(closest)
      expect(result.ambiguous).to eq(1)
      expect(result.linked).to eq(1)
    end

    it "does not match a different amount" do
      event(amount: 29.72, at: 2.days.ago)
      row = transaction(amount_cents: -2900, at: 1.day.ago)

      described_class.call
      expect(row.reload.action_event).to be_nil
    end

    it "does not match a different account" do
      event(amount: 29.72, at: 2.days.ago, account_label: "Prime Visa (...7283)")
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      described_class.call
      expect(row.reload.action_event).to be_nil
    end

    it "does not match outside the window" do
      event(amount: 29.72, at: 20.days.ago)
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      result = described_class.call

      expect(row.reload.action_event).to be_nil
      expect(result.unmatched).to eq(1)
    end

    it "never gives one alert to two charges" do
      event(amount: 29.72, at: 2.days.ago)
      first = transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0001")
      second = transaction(amount_cents: -2972, at: 1.day.ago, simplefin_id: "TRN-0002")

      described_class.call

      linked = [first.reload.action_event_id, second.reload.action_event_id]
      expect(linked.compact.size).to eq(1)
    end

    it "does not re-link an already-claimed alert on a later run" do
      matching = event(amount: 29.72, at: 2.days.ago)
      transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0001")
      described_class.call

      later = transaction(amount_cents: -2972, at: 1.day.ago, simplefin_id: "TRN-0002")
      described_class.call

      expect(later.reload.action_event).to be_nil
      expect(BankTransaction.linked.pluck(:action_event_id)).to eq([matching.id])
    end

    it "skips an account with no trailing digits rather than matching on amount alone" do
      unnumbered = BankAccount.create!(simplefin_id: "ACT-0002", name: "MORTGAGE LOAN", last4: nil)
      event(amount: 29.72, at: 2.days.ago)
      row = transaction(amount_cents: -2972, at: 1.day.ago, on: unnumbered)

      result = described_class.call

      expect(row.reload.action_event).to be_nil
      expect(result.unmatched).to eq(1)
    end

    it "ignores ActionEvents that are not transactions" do
      ActionEvent.create!(
        user: user, name: "Whisper", timestamp: 2.days.ago, data: { amount: 29.72 },
      )
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      described_class.call
      expect(row.reload.action_event).to be_nil
    end

    it "only considers transactions it was handed" do
      event(amount: 29.72, at: 2.days.ago)
      row = transaction(amount_cents: -2972, at: 1.day.ago)

      described_class.call(BankTransaction.where(simplefin_id: "nope"))
      expect(row.reload.action_event).to be_nil
    end

    # The historical backfill produces years of rows that predate the alerts and
    # can never match. Re-examining them on every sync is a scan that grows with
    # the backfill rather than with the work.
    describe ".matchable" do
      it "skips a row from before the first alert" do
        event(amount: 29.72, at: 2.days.ago)
        old = transaction(amount_cents: -2972, at: 3.years.ago, simplefin_id: "TRN-OLD")
        recent = transaction(amount_cents: -1000, at: 1.day.ago, simplefin_id: "TRN-NEW")

        expect(described_class.matchable).to include(recent)
        expect(described_class.matchable).not_to include(old)
      end

      # A charge is matched on `transacted_at`, which can precede the alert it
      # belongs to. The bound has to leave room for that or the filter would cut
      # off the very rows at the start of the history.
      it "keeps a row whose charge sits just before the first alert" do
        first = event(amount: 29.72, at: 2.days.ago)
        edge = transaction(
          amount_cents: -2972, at: first.timestamp - 2.days, simplefin_id: "TRN-EDGE",
        )

        expect(described_class.matchable).to include(edge)

        described_class.call
        expect(edge.reload.action_event).to eq(first)
      end

      # Nothing to bound against yet — better every row than none.
      it "falls back to every unlinked row when there are no alerts at all" do
        row = transaction(amount_cents: -2972, at: 3.years.ago)

        expect(described_class.matchable).to include(row)
      end

      it "leaves a linked row out either way" do
        first = event(amount: 29.72, at: 2.days.ago)
        row = transaction(amount_cents: -2972, at: 1.day.ago)
        row.update!(action_event: first)

        expect(described_class.matchable).not_to include(row)
      end
    end
  end

  # The inverted order: the bank row exists first and the ActionEvent arrives
  # afterwards. Happens when a charge syncs before its alert is categorized, when
  # an event is created or edited by hand, and on any backfill.
  describe "linking an event" do
    let(:user) { User.me }
    let(:account) {
      BankAccount.create!(
        simplefin_id: "ACT-0001", name: "Chase Sapphire Preferred (8257)",
        last4: "8257", kind: :credit
      )
    }

    def transaction(amount_cents:, at:, simplefin_id: "TRN-0001", on: account)
      BankTransaction.create!(
        simplefin_id: simplefin_id, bank_account: on, posted_at: at,
        transacted_at: at, amount_cents: amount_cents, description: "TST* HOUSTON"
      )
    end

    def build_event(amount:, at:, label: "Chase Sapphire Preferred Visa (...8257)", name: "Transaction")
      ActionEvent.new(
        user: user, name: name, timestamp: at,
        data: { amount: amount, account: label, category: "eat out" }
      )
    end

    it "links a bank row that was already waiting" do
      row = transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!

      expect(described_class.link_event(event)).to eq(row)
      expect(row.reload.action_event).to eq(event)
    end

    it "fires automatically through ActionEventNotifier" do
      row = transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!

      ActionEventNotifier.notify(user, event, :added)

      expect(row.reload.action_event).to eq(event)
    end

    it "makes the category readable from the bank row straight away" do
      row = transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!
      described_class.link_event(event)

      expect(row.reload.category).to eq("eat out")
    end

    it "ignores an event that is not a transaction" do
      transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago, name: "Whisper")
      event.save!

      expect(described_class.link_event(event)).to be_nil
    end

    it "does not claim a row that already has an event" do
      row = transaction(amount_cents: -2972, at: 1.day.ago)
      first = build_event(amount: 29.72, at: 2.days.ago)
      first.save!
      described_class.link_event(first)

      second = build_event(amount: 29.72, at: 2.days.ago)
      second.save!

      expect(described_class.link_event(second)).to be_nil
      expect(row.reload.action_event).to eq(first)
    end

    it "is idempotent for an event already linked" do
      transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!
      described_class.link_event(event)

      expect(described_class.link_event(event)).to be_nil
      expect(BankTransaction.linked.count).to eq(1)
    end

    # This used to refuse, back when refusing just left the bank row unlinked.
    # Now that every event gets a row, refusing MAKES a duplicate of a purchase
    # already in the table — so the closest in time takes it instead. 26 pairs of
    # exactly this shape had to be merged afterwards.
    it "takes the closest row when two could equally be it" do
      far = transaction(amount_cents: -2972, at: 5.hours.ago, simplefin_id: "TRN-0001")
      near = transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0002")
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!

      expect(described_class.link_event(event)).to eq(near)
      expect(far.reload.action_event).to be_nil
    end

    # The real case: two same-sized charges on one card inside the window, each
    # with its own alert. Both must pair off, and neither may spawn a third row.
    it "pairs off two same-sized charges without inventing a row" do
      early = transaction(amount_cents: -1611, at: 4.days.ago, simplefin_id: "TRN-EARLY")
      late = transaction(amount_cents: -1611, at: 1.day.ago, simplefin_id: "TRN-LATE")

      first = build_event(amount: 16.11, at: 4.days.ago)
      first.save!
      second = build_event(amount: 16.11, at: 1.day.ago)
      second.save!

      SimpleFin::EventTransaction.sync(first)
      SimpleFin::EventTransaction.sync(second)

      expect(early.reload.action_event).to eq(first)
      expect(late.reload.action_event).to eq(second)
      expect(BankTransaction.count).to eq(2)
    end

    it "does not match a different account" do
      transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago, label: "Prime Visa (...7283)")
      event.save!

      expect(described_class.link_event(event)).to be_nil
    end

    it "does not match outside the window" do
      transaction(amount_cents: -2972, at: 30.days.ago)
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!

      expect(described_class.link_event(event)).to be_nil
    end

    # 433 alerts come from a format that names no account. Refusing to match
    # them at all is what left every one of them — most of the checking-account
    # spending — with no bank row and no category.
    describe "an event with no account label" do
      it "matches on amount and timing alone when only one row can be meant" do
        row = transaction(amount_cents: -2972, at: 1.day.ago)
        event = build_event(amount: 29.72, at: 2.days.ago, label: "")
        event.save!

        expect(described_class.link_event(event)).to eq(row)
      end

      # With no account to narrow on, more of these come back with several
      # candidates — settled the same way, on time.
      it "takes the closest of two rows of the same size" do
        transaction(amount_cents: -2972, at: 5.hours.ago, simplefin_id: "TRN-X")
        near = transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-Y")
        event = build_event(amount: 29.72, at: 2.days.ago, label: "")
        event.save!

        expect(described_class.link_event(event)).to eq(near)
      end

      # Signed, not magnitude: without an account to separate them, a refund
      # would otherwise match the charge it reverses.
      it "does not match a refund to the charge it reverses" do
        transaction(amount_cents: 2972, at: 1.day.ago)
        event = build_event(amount: 29.72, at: 2.days.ago, label: "")
        event.save!

        expect(described_class.link_event(event)).to be_nil
      end
    end

    # The bank row is the authoritative record; the annotation is not.
    it "survives the event being deleted, dropping only the link" do
      row = transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago)
      event.save!
      described_class.link_event(event)

      expect { event.destroy! }.not_to raise_error
      expect(row.reload).to be_persisted
      expect(row.action_event_id).to be_nil
    end
  end
end
