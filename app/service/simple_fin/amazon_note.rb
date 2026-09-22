module SimpleFin
  # An Amazon charge's note and the name on the delivery board are the SAME
  # name, kept in step in both directions.
  #
  # AmazonEnrichment already matches a charge to a row on the board and writes
  # the order number onto it. What it wrote was a one-time copy, though: the
  # board's name at the instant the charge landed got frozen into the memo and
  # into the categorization prompt's Notes box, and renaming the row afterwards
  # — which is the entire point of the board being editable — left both saying
  # whatever the shipping email had guessed. The 21 Sep charge read
  # "item: Health Care" for a row that had been called "Pill Box" for a day,
  # and so did the prompt sitting unanswered above it.
  #
  # So the link is live now, three ways round:
  #
  #   board renamed   -> every charge holding that order number takes the name
  #   note typed      -> the row on the board is renamed to match
  #   prompt opened   -> its Notes box is filled from the board AT THAT MOMENT,
  #                      not from whatever was true when the alert arrived
  #
  # There is one name and the last writer owns it. That is what makes the two
  # directions safe to have at once: a memo edit renames the board, so the only
  # way the two can disagree is a board rename, and a board rename is then the
  # most recent thing anybody said.
  #
  # It rides the trigger bus rather than model callbacks for the reason
  # RecordLinks::Propagator does: AmazonOrder is a cache-backed PORO with no
  # callbacks to hang anything off, and every writer — both email parsers, the
  # dashboard channel, Buddy — already goes through AmazonOrder.save and out
  # through DeliveryEvents.
  #
  # Nothing here may raise into the write that triggered it. A charge, a prompt
  # answer and a delivery row are all worth more than the label on them.
  class AmazonNote
    # The categorization prompt, and the box on it that holds the note. Both
    # are set by Jil task 422 ("Transaction Categorize Prompt").
    PROMPT_SOURCE = "transaction_categorize".freeze
    NOTE_QUESTION = "Notes".freeze

    class << self
      # One string comparison for every trigger that isn't ours. The ownership
      # check is behind it rather than in front: the board lives under MeCache,
      # which is the OWNER's cache and nobody else's, and there is no per-user
      # delivery list to fall back to — so a feature granted by mistake must
      # not point somebody else's charges at his packages.
      def dispatch(user, trigger, payload)
        scope = trigger.to_s
        return unless %w[prompt delivery].include?(scope)
        return unless ::Buddy::Deliveries.available?(user)

        scope == "prompt" ? on_prompt(payload) : on_delivery(payload)
      rescue ::StandardError => e
        ::Rails.logger.warn("[SimpleFin::AmazonNote] #{trigger} failed: #{e.class}: #{e.message}")
        nil
      end

      # The row on the board this charge paid for, or nil.
      #
      # Matching is AmazonEnrichment's job and this does not repeat it: an
      # unlinked charge is handed to `apply`, which matches on amount and date
      # and refuses a row another charge has already claimed, then writes the
      # order number down so every later read is a lookup rather than a guess.
      def order_for(transaction)
        return nil if transaction.blank?

        # AmazonOrder memoizes the list into a class variable and this runs
        # inside long-lived Sidekiq processes, which would otherwise answer
        # from whatever the board looked like when the worker booted.
        ::AmazonOrder.reload
        linked(transaction) || (::SimpleFin::AmazonEnrichment.apply(transaction) && linked(transaction))
      end

      # What the board CALLS this row.
      #
      # `name` starts life as a copy of `listed_name` — AmazonEmailParser does
      # `o.name ||= o.listed_name` — so a `name` that has diverged from it is
      # one somebody typed, on the dashboard or through Buddy, and it beats
      # anything Amazon said. Failing that the product title, shortened,
      # because a title is at least the thing; `listed_name` ("item: Health
      # Care") is the department it was filed under.
      def for_order(order)
        return nil if order.nil?

        named = order.name.to_s.strip
        return named if named.present? && named != order.listed_name.to_s.strip

        # Still whatever Amazon said, then — a title written for search rather
        # than for reading. Shortened, which is what AmazonProductName is for,
        # and safe to do here precisely because nobody typed it: a name
        # somebody typed is returned above, untouched, so what comes back out
        # of the board is never a trimmed copy of what they put in.
        raw = order.full_name.presence || order.listed_name.presence || named.presence
        ::AmazonProductName.tidy(raw).presence
      end

      def note_for(transaction)
        for_order(order_for(transaction))
      end

      # Name -> board. Returns true when the board actually moved.
      def rename!(transaction, text)
        name = text.to_s.squish
        return false if name.blank?

        order = order_for(transaction)
        return false if order.nil?
        return false if order.name.to_s.strip == name

        order.name = name
        # Fires DeliveryEvents, which comes back round to `on_delivery` and
        # carries the new name down onto this charge's memo — and onto the
        # other charges of a split shipment, which is why that half is not done
        # here. It terminates because that half writes only on a difference.
        ::AmazonOrder.save
        ::AmazonOrder.broadcast
        # The same thing the dashboard's own rename does, so the next order of
        # this SKU reuses the name instead of asking GPT for one. Guarded on
        # the id really being an ASIN: a row whose SKU isn't known yet uses its
        # ORDER id as the item id, and those must stay out of the catalog.
        ::AmazonItemCatalog.set(order.item_id, name: name) if ::AmazonItemCatalog.asin?(order.item_id)
        true
      rescue ::StandardError => e
        # Called straight from the banking page's memo edit, where the memo is
        # already saved by the time this runs. A board that can't be written is
        # not a reason to answer that edit with an error.
        ::Rails.logger.warn("[SimpleFin::AmazonNote] rename failed: #{e.class}: #{e.message}")
        false
      end

      # Board -> name. The number of charges that took it.
      def push!(order)
        note = for_order(order)
        return 0 if note.blank? || order.order_id.blank?

        charges(order).count { |transaction|
          next false if transaction.memo.to_s.strip == note

          transaction.update!(memo: note)
          true
        }
      end

      # The charge that paid for this delivery. A split shipment puts several
      # rows under one order number, each with its own charge, so once the item
      # id has been recorded it is what tells them apart; before that the order
      # number is all there is.
      def charges(order)
        scope = ::BankTransaction.where("metadata -> 'amazon' ->> 'order_id' = ?", order.order_id.to_s)
        return scope if ::AmazonOrder.by_order(order.order_id).one?

        scope.where("metadata -> 'amazon' ->> 'item_id' = ?", order.item_id.to_s)
      end

      private

      def linked(transaction)
        amazon = transaction.metadata.to_h["amazon"]
        return nil if amazon.blank? || amazon["order_id"].blank?

        ::AmazonOrder.find(amazon["order_id"], amazon["item_id"].presence) ||
          ::AmazonOrder.by_order(amazon["order_id"]).first
      end

      def on_prompt(prompt)
        return unless prompt.respond_to?(:params)
        return unless prompt.params.to_h["source"].to_s == PROMPT_SOURCE

        return fill_note!(prompt) if attr_of(prompt, :state).to_s == "load"

        answered!(prompt) if attr_of(prompt, :status).to_s == "complete"
      end

      # The Notes box, filled from the board as the prompt is OPENED. The page
      # and Buddy::PromptForm both fire `prompt:state:load` and then re-read,
      # which is the whole mechanism — task 422 writes a skeleton and the load
      # listeners say what is actually in it. Idempotent, as every load
      # listener has to be: re-firing sets the same default again.
      # rubocop:disable Naming/PredicateMethod -- it writes; `?` would imply a query
      def fill_note!(prompt)
        note = note_for(charge_for(prompt))
        return false if note.blank?

        options = Array(prompt.options).deep_dup
        question = options.find { |opt| opt.is_a?(::Hash) && opt["question"].to_s == NOTE_QUESTION }
        return false if question.nil? || question["default"].to_s == note

        question["default"] = note
        prompt.update!(options: options)
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def answered!(prompt)
        note = prompt.response.to_h[NOTE_QUESTION].to_s.squish
        return false if note.blank?

        transaction = charge_for(prompt)
        return false if transaction.blank?

        # An Amazon charge carries the name in its own `memo` column, and
        # `display_memo` prefers that over the event's notes — so answering the
        # prompt has to move it, or the answer sits invisible behind the name
        # the board had last week. Only for a charge that IS linked: on
        # anything else the memo stays empty on purpose and the note shows
        # through from the event, which is what `memo_from_event?` renders.
        if transaction.metadata.to_h["amazon"].present? && transaction.memo.to_s.strip != note
          transaction.update!(memo: note)
        end

        rename!(transaction, note)
      end

      def on_delivery(payload)
        order_id = attr_of(payload, :order_id)
        return if order_id.blank?

        ::AmazonOrder.reload
        order = ::AmazonOrder.find(order_id, attr_of(payload, :item_id).presence)
        return if order.nil?

        push!(order)
      end

      def charge_for(prompt)
        event_id = prompt.params.to_h["action_event_id"]
        return nil if event_id.blank?

        ::BankTransaction.find_by(action_event_id: event_id)
      end

      # A trigger payload is either a flat hash (`delivery`) or the record
      # itself carrying its execution attrs (`prompt`, where `state` / `status`
      # ride along via Jilable#with_jil_attrs rather than in a hash beside it).
      def attr_of(payload, key)
        return payload[key] || payload[key.to_s] if payload.is_a?(::Hash)

        payload.try(:[], key)
      end
    end
  end
end
