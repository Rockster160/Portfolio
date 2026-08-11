module SimpleFin
  # Pairs up money moved between two accounts that are both yours.
  #
  # Every such movement is reported twice — once leaving the source, once
  # arriving at the destination. Counted naively that is a phantom spend and a
  # phantom deposit of the same size. A credit-card payoff is the clearest
  # case: the money was already spent on the card, so counting the payment as
  # spending too charges you twice for one purchase.
  #
  # A pair needs ALL of:
  #   * two DIFFERENT accounts, both in bank_accounts (i.e. both yours)
  #   * exactly opposite amounts to the cent
  #   * within WINDOW of each other
  #   * neither side already paired
  #
  # And it must be UNAMBIGUOUS. If a leaving row could equally be explained by
  # two arriving rows, nothing is paired — mislabelling a real expense as a
  # transfer erases it from spending entirely, which is a worse and quieter
  # error than leaving a transfer counted.
  class TransferDetector
    # Card payoffs and mortgage payments post on the source and destination a
    # day or two apart; weekends stretch it.
    WINDOW = 4.days

    Result = Struct.new(:paired, :ambiguous, keyword_init: true)

    def self.call(scope=::BankTransaction.unpaired) = new(scope).call

    def initialize(scope)
      @scope = scope
      @paired = 0
      @ambiguous = 0
    end

    def call
      rows = @scope.includes(:bank_account).to_a
      return Result.new(paired: 0, ambiguous: 0) if rows.empty?

      # Only the outgoing side drives the search, so each pair is considered
      # once rather than from both ends.
      outgoing = rows.select { |row| row.amount_cents.negative? }
      incoming = rows.select { |row| row.amount_cents.positive? }
      by_amount = incoming.group_by(&:amount_cents)

      claimed = ::Set.new
      outgoing.each { |row| pair(row, by_amount, claimed) }

      Result.new(paired: @paired, ambiguous: @ambiguous)
    end

    private

    def pair(row, by_amount, claimed)
      return if claimed.include?(row.id)

      candidates = by_amount[row.amount_cents.abs].to_a
      candidates = candidates.reject { |other| claimed.include?(other.id) }
      candidates = candidates.select { |other| plausible?(row, other) }

      case candidates.size
      when 0 then nil
      when 1
        other = candidates.first
        ::BankTransaction.transaction {
          row.update!(transfer_counterpart: other)
          other.update!(transfer_counterpart: row)
        }
        claimed << row.id << other.id
        @paired += 1
      else @ambiguous += 1
      end
    end

    def plausible?(row, other)
      return false if other.bank_account_id == row.bank_account_id
      return false if row.transfer_counterpart_id.present? || other.transfer_counterpart_id.present?

      within_window?(row, other)
    end

    def within_window?(row, other)
      left = row.occurred_at
      right = other.occurred_at
      return false if left.blank? || right.blank?

      (left - right).abs <= WINDOW
    end
  end
end
