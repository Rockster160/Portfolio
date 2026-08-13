module SimpleFin
  # Keeps a BankTransaction in step with the Chase-alert ActionEvent that
  # describes the same purchase, creating one when nothing else has.
  #
  # This is what makes bank_transactions the single table worth querying. It
  # used to hold only what SimpleFIN reported, which meant a purchase was
  # invisible there until the bank got round to clearing it — up to a day — and
  # anything on a closed card, or from an alert format that names no account,
  # was invisible forever. Category lived on the event for the same reason, so
  # the historical backfill's rows could never hold one at all.
  #
  # Now the alert lands a row immediately and the bank merges into it later.
  # Which side owns which field is the whole design:
  #
  #   the bank owns the FACTS   amount, payee, description, posted/pending,
  #                             account — it is the institution's own record
  #                             and it corrects itself as a charge settles
  #   the alert owns the JUDGEMENT   category, and the notes typed into the
  #                             categorization prompt
  #
  # So a merged row takes its numbers from SimpleFIN and its meaning from the
  # event, and neither overwrites the other.
  class EventTransaction
    EVENT_NAME = ::SimpleFin::EventMatcher::EVENT_NAME

    class << self
      # The one entry point, called from ActionEventNotifier for every add and
      # change. Idempotent, and a no-op for anything that is not a Transaction
      # event. Returns the transaction, or nil.
      def sync(event)
        return nil if event.blank? || event.name.to_s != EVENT_NAME

        existing = ::BankTransaction.find_by(action_event_id: event.id)
        return update!(existing, event) if existing.present?

        matched = ::SimpleFin::EventMatcher.link_event(event)
        return update!(matched, event) if matched.present?

        create!(event)
      end

      # The alert-sourced row that this incoming SimpleFIN transaction is the
      # bank's own record of — the merge that stops one purchase being listed
      # twice, once from the alert and once from the bank.
      #
      # Amounts are compared SIGNED, not on magnitude. A refund is the same
      # magnitude as the charge it reverses and lands within days of it, so
      # matching on magnitude is how a $45 refund gets merged into the $45
      # purchase and both disappear into one row.
      #
      # An exact account match wins outright; a row that names no account is
      # only considered when nothing else fits. Where several fit, the closest
      # in time takes it — refusing would leave the bank's copy to be inserted
      # alongside the alert's, which is a phantom transaction in every total.
      # See EventMatcher.nearest for why proximity is trustworthy here.
      def claim(bank_account:, amount_cents:, occurred_at:)
        return nil if amount_cents.nil? || occurred_at.blank?

        window = ::SimpleFin::EventMatcher::WINDOW
        scope = ::BankTransaction.event_sourced.where(
          amount_cents: amount_cents,
          occurred_at:  (occurred_at - window)..(occurred_at + window),
        )

        exact = closest(scope.where(bank_account_id: bank_account&.id), occurred_at)
        exact || closest(scope.where(bank_account_id: nil), occurred_at)
      end

      # An event that goes away takes its row with it — but only if the row is
      # nothing BUT the event. Once SimpleFIN has reported the same purchase
      # the row is the bank's record and outlives the annotation, which is what
      # the FK's ON DELETE SET NULL already says.
      def forget(event)
        return nil if event.blank? || event.name.to_s != EVENT_NAME

        ::BankTransaction.event_sourced.where(action_event_id: event.id).destroy_all
      end

      # Events store the amount unsigned-by-convention and INVERTED relative to
      # the bank: an alert reads "you spent 14.65" as +14.65, while the account
      # it left records -14.65. Verified against all 306 currently-linked pairs
      # — 305 agree on the flip, and the one that does not is a refund the
      # alert recorded as a purchase.
      def amount_cents_for(event)
        raw = event.data&.dig("amount")
        return nil if raw.blank?

        -(BigDecimal(raw.to_s) * 100).round
      rescue ::ArgumentError
        nil
      end

      # Stored as written rather than cast to the vocabulary. Everything in the
      # data today is one of the 22, and if something ever writes one that is
      # not, keeping it is what lets `unknown_in_use` show it — casting would
      # quietly erase the evidence.
      def category_for(event)
        event.data&.dig("category").presence&.to_s&.downcase
      end

      # Nil rather than a guess. 433 events come from an alert format that
      # names no account, and two more name cards that were closed before
      # SimpleFIN was connected — for those the honest answer is that the row
      # does not know, not that it is probably checking.
      def account_for(event)
        last4 = ::BankAccount.last4_from(event.data&.dig("account"))
        return nil if last4.blank?

        ::BankAccount.find_by(last4: last4)
      end

      private

      # `id` breaks an exact tie so the choice cannot vary between runs.
      def closest(scope, occurred_at)
        scope.to_a.min_by { |row| [(row.occurred_at - occurred_at).abs, row.id] }
      end

      def create!(event)
        cents = amount_cents_for(event)
        return nil if cents.nil? || event.timestamp.blank?

        build!(event, cents).tap { |row| ::SimpleFin::AmazonEnrichment.apply(row) }
      end

      def build!(event, cents)
        ::BankTransaction.create!(
          action_event:  event,
          bank_account:  account_for(event),
          amount_cents:  cents,
          # The alert fires when the purchase is made, so this is the
          # transacted side. `posted_at` stays nil until the bank says when it
          # cleared — a date invented here would be wrong by up to four days.
          transacted_at: event.timestamp,
          payee:         event.data&.dig("merchant").presence,
          category:      category_for(event),
        )
      end

      # Only what the event owns. A merged row's amount and payee belong to the
      # bank, and re-deriving them here would undo the corrections SimpleFIN
      # makes as a charge settles.
      #
      # `compact` so an event that has stopped saying something does not erase
      # what is already stored: clearing the category field on an alert is not
      # a request to uncategorize the transaction it produced.
      def update!(transaction, event)
        return nil if transaction.blank?

        attrs = { category: category_for(event) }
        attrs.merge!(event_facts(event)) if transaction.simplefin_id.blank?
        transaction.update!(attrs.compact)
        transaction
      end

      def event_facts(event)
        {
          amount_cents:  amount_cents_for(event),
          transacted_at: event.timestamp,
          payee:         event.data&.dig("merchant").presence,
          bank_account:  account_for(event),
        }
      end
    end
  end
end
