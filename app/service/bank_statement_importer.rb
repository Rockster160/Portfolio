require "csv"

# Folds a downloaded statement CSV into BankAccount + BankTransaction rows, for
# an institution SimpleFIN cannot reach.
#
# The design constraint is that re-exporting is the NORMAL way to use this. A
# bank's export UI gives you a date range, not "everything since last time", so
# every upload after the first overlaps the one before it. Dedupe therefore has
# to be a property of the importer rather than something the person is expected
# to get right by picking careful date ranges.
#
# The key is the file's own per-transaction id, stored in `upstream_id`
# namespaced by source. Deliberately NOT `simplefin_id`: four things branch on
# that being nil to mean "the Bridge has not reported this yet", and a CSV row
# is confirmed by the institution while staying permanently invisible to the
# Bridge. See the migration.
#
# Column mapping is passed IN, not detected. `.inspect_file` reads a file and
# proposes one, the upload screen shows the proposal for correction, and what
# comes back is what gets used — so a bank nobody has seen before works on the
# first try instead of needing a constant added here first.
class BankStatementImporter
  # `rows` is everything the file carried; `created` and `updated` split what
  # happened to them. A second upload of the same file reports rows and zero
  # created, which is the signal that dedupe worked.
  #
  # `accounts` is a name => count breakdown, so a file that spreads across
  # several accounts says where the rows went rather than only how many there
  # were.
  Result = Struct.new(
    :source, :rows, :created, :updated, :skipped, :errors, :accounts,
    keyword_init: true
  ) do
    def errors? = errors.present?
    def ok? = errors.blank?
  end

  class MissingMapping < ::StandardError; end

  # What a row can carry. Only the first three are required — without an id
  # there is nothing to dedupe on, and without a date and amount there is no
  # transaction.
  FIELDS = [
    :identifier, :date, :amount, :description, :payee, :category, :balance, :account
  ].freeze
  REQUIRED = [:identifier, :date, :amount].freeze

  # Human labels for the mapping screen, which is the only place these appear.
  FIELD_LABELS = {
    identifier:  "Transaction id",
    date:        "Date",
    amount:      "Amount",
    description: "Description",
    payee:       "Payee",
    category:    "Category",
    balance:     "Balance",
    account:     "Account",
  }.freeze

  # How `.guess` proposes a mapping. Ordered within each field — first pattern
  # that matches an unclaimed header wins — and the FIELDS order decides which
  # field gets first refusal on a header that several could want.
  #
  # The anchored patterns come first for a reason: MACU ships both "Posting
  # Date" and "Effective Date", and both "Description" and "Extended
  # Description". A bare /date/ or /description/ would take whichever happened
  # to be leftmost.
  HEADER_PATTERNS = {
    identifier:  [
      /\Atransaction\s*id\z/i,
      /transaction\s*id/i,
      /\A(?:trans\s*)?id\z/i,
      /reference\s*(?:number|no)?/i,
],
    date:        [
      /posting\s*date/i,
      /post(?:ed)?\s*date/i,
      /transaction\s*date/i,
      /\Adate\z/i,
      /date/i,
],
    amount:      [/\Aamount\z/i, /amount/i, /\Adebit\z/i],
    balance:     [/\Arunning\s*balance\z/i, /balance/i],
    category:    [/category/i],
    account:     [/account\s*(?:name|number|nickname)/i, /\Aaccount\z/i],
    description: [
      /extended\s*description/i,
      /\Adescription\z/i,
      /description/i,
      /details/i,
      /\Amemo\z/i,
],
    # `\Adescription\z` last, and it earns its place: a file carrying BOTH
    # "Description" and "Extended Description" — MACU does — has already given
    # the extended one to `description`, and the plain one is the institution's
    # own CLEANED merchant name ("Costco", "Airbnb", "1password") while the
    # extended one is raw wire text. A file with only one description column
    # loses it to `description` first and gets no payee, which is correct.
    payee:       [/payee/i, /merchant/i, /\Aname\z/i, /\Adescription\z/i],
  }.freeze

  # Which field gets first refusal when two want the same header. Specific
  # before general: `category` claims "Transaction Category" before
  # `description` can take it for containing a word it likes.
  CLAIM_ORDER = [
    :identifier, :date, :amount, :balance, :category, :account, :description, :payee
  ].freeze

  # Seeds the category column on the mapping screen. A SUGGESTION ONLY — what
  # the person leaves in the boxes is what actually runs, so a wrong guess here
  # costs a dropdown change rather than a wrong category on 200 rows.
  #
  # The ones deliberately absent map to nothing, and that is the point: a blank
  # box means "let the merchant rules decide", which is right for every label
  # that describes the DIRECTION of the money rather than what it was for.
  # MACU files a mortgage under both "Loan Payments" and "Online Services", so
  # neither can be trusted, while JPMORGAN CHASE in the payee is unambiguous.
  CATEGORY_GUESSES = {
    "atm"                         => :other,
    "automotive expenses"         => :car,
    "bills & utilities"           => :utilities,
    "credit card payments"        => :"card payment",
    "dining"                      => :"eat out",
    "education"                   => nil,
    "entertainment"               => :fun,
    "food & drink"                => :"eat out",
    "gas"                         => :car,
    "gasoline/fuel"               => :car,
    "groceries"                   => :groceries,
    "health & wellness"           => :health,
    "home maintenance & services" => :home,
    "home supplies"               => :home,
    "insurance"                   => :insurance,
    "medical"                     => :medical,
    "mortgages"                   => :mortgage,
    "paychecks/salary"            => :"pay check",
    "personal care"               => :medical,
    "pets/pet care"               => :pets,
    "restaurants & dining"        => :"eat out",
    "service charges & fees"      => :other,
    "shopping"                    => :shopping,
    "telephone services"          => :utilities,
    "travel & commute"            => :travel,
    "utilities"                   => :utilities,
  }.freeze

  # NOT %w[] — half these names contain a space, and %w splits on whitespace,
  # which turns "check number" into two entries and makes every signature miss.
  MACU_HEADERS = [
    "amount",
    "balance",
    "check number",
    "description",
    "effective date",
    "extended description",
    "memo",
    "posting date",
    "reference number",
    "transaction category",
    "transaction id",
    "transaction type",
    "type",
  ].sort.freeze

  # Recognized header signatures, so a re-upload of a file we have seen before
  # keeps the same dedupe namespace without the person having to remember what
  # they typed last time. Sorted and downcased, because column order is the
  # export UI's business and can change between versions.
  KNOWN_SOURCES = { MACU_HEADERS => "macu" }.freeze

  # The institution has already cleaned the merchant name on card and POS rows
  # ("Costco", "Airbnb", "1password"). ACH rows have not been cleaned and carry
  # the raw wire text, which is what these pull apart.
  # Several formats, because the date field is a free-for-all: US banks write
  # 8/20/2026, exports aimed at spreadsheets write 2026-08-20.
  DATE_FORMATS = ["%m/%d/%Y", "%m/%d/%y", "%Y-%m-%d", "%d/%m/%Y", "%b %d, %Y"].freeze

  ACH_COMPANY = /\bCO(?:MPANY)?:\s*(.+?)(?:\s{2,}|\s+(?:NAME|ENTRY|TYPE):|\z)/i
  # A value that still starts with the transaction verb was never cleaned, so
  # it is the raw string rather than a merchant.
  RAW_DESCRIPTION = /\A(?:ach\s+)?(?:withdrawal|deposit)\b/i
  # What the wire format wraps a merchant in, on both ends.
  LEADING_NOISE = /\A(?:withdrawal|deposit)\s+(?:debit|card|pos\s*#|ach|home)?\s*/i
  TRAILING_NOISE = /\s{2,}(?:date|card)\s+.*\z/i

  class << self
    def call(...) = new(...).call

    # Everything the upload screen needs to draw a mapping form: the file's own
    # column names, a proposed mapping, the distinct values in whichever column
    # looks like a category with a proposed target for each, and a row count so
    # the person can see the file was read before committing to it.
    def inspect_file(io, filename: nil)
      table = parse(io)
      headers = ::Array.wrap(table.headers).compact.map { |header| header.to_s.strip }
      mapping = guess(headers)

      {
        headers:    headers,
        mapping:    mapping,
        source:     source_for(headers, filename),
        categories: category_values(table, mapping[:category]),
        rows:       table.size,
      }
    end

    # Proposes a column for each field. A header is claimed once — two fields
    # pointing at the same column is almost always the guess being wrong rather
    # than the file being odd.
    def guess(headers)
      available = headers.dup
      CLAIM_ORDER.each_with_object({}) { |field, mapping|
        pattern = HEADER_PATTERNS[field].detect { |candidate|
          available.any? { |header| header.match?(candidate) }
        }
        next if pattern.nil?

        found = available.detect { |header| header.match?(pattern) }
        available.delete(found)
        mapping[field] = found
      }
    end

    # The distinct values in the category column, each with a suggested target.
    # Nil means "no suggestion" and reads on the form as "let merchant rules
    # decide", which is a real answer rather than a failure to have one.
    def category_values(table, column)
      return {} if column.blank?

      values = table.filter_map { |row| row[column].to_s.strip.presence }.uniq.sort
      values.index_with { |value|
        ::TransactionCategory.cast(value.downcase) || CATEGORY_GUESSES[value.downcase]
      }
    end

    # A stable dedupe namespace for this file's institution. Keyed on the
    # header signature rather than the filename: "ExportedTransactions.csv" is
    # what half of them are called, and column order is not stable enough to
    # key on directly.
    def source_for(headers, filename=nil)
      signature = headers.map { |header| header.to_s.downcase.strip }.sort
      known = KNOWN_SOURCES[signature]
      return known if known.present?

      slug = filename.to_s.split("/").last.to_s.sub(/\.\w+\z/, "").parameterize.presence
      slug || "import"
    end

    def parse(io)
      body = io.respond_to?(:read) ? io.read : io.to_s
      # Institutions ship these with a BOM often enough that a stripped one is
      # not worth a separate bug report — it makes the first header unmatchable
      # and every mapping guess miss.
      ::CSV.parse(body.sub("\xEF\xBB\xBF", ""), headers: true)
    end
  end

  # `io` is anything responding to #read — an uploaded file, or File.open in a
  # script.
  #
  # `mapping` is field => column name, as `.guess` proposes and the upload
  # screen confirms. `categories` is the file's own category value => one of
  # ours, where a MISSING or blank entry means "fall through to the merchant
  # rules" rather than "leave it uncategorized".
  #
  # `account` is the fallback: where a row goes when the file names no account,
  # or names one nothing matches.
  def initialize(io, account:, mapping:, categories: {}, source: nil, filename: nil)
    @io = io
    @fallback = account
    @mapping = normalize_mapping(mapping)
    @categories = normalize_categories(categories)
    @source = source.presence&.to_s
    @filename = filename
    @created = 0
    @updated = 0
    @skipped = 0
    @errors = []
    @accounts = ::Hash.new(0)
    @resolved = {}
  end

  def call
    table = self.class.parse(@io)
    headers = ::Array.wrap(table.headers).compact.map { |header| header.to_s.strip }
    @source ||= self.class.source_for(headers, @filename)
    # No mapping posted means the mapping form never drew — JS disabled, an
    # error in it, or a caller that has no opinion. Guess rather than refuse:
    # the guess is right on every file we have seen, and a feature that dies
    # silently when its JavaScript does is worse than one that occasionally
    # picks the wrong column and says which it picked.
    @mapping = self.class.guess(headers) if @mapping.blank?
    verify!(headers)

    # One transaction for the whole file. A statement half-applied is worse
    # than one not applied at all: the person has no way to tell which half,
    # and their next move is to upload it again.
    ::ActiveRecord::Base.transaction {
      table.each_with_index { |row, index| import_row(row, index) }
      apply_balance(table)
    }

    Result.new(
      source: @source, rows: table.size, created: @created, updated: @updated,
      skipped: @skipped, errors: @errors, accounts: @accounts.to_h
    )
  end

  private

  def normalize_mapping(mapping)
    mapping.to_h.symbolize_keys.slice(*FIELDS).transform_values { |column|
      column.to_s.strip.presence
    }.compact
  end

  # Blank means "no answer here", which is different from "leave it
  # uncategorized" — it hands the row to the merchant rules. Dropping the
  # blanks is what makes `key?` able to tell the two apart.
  def normalize_categories(categories)
    categories.to_h.filter_map { |value, target|
      canonical = ::TransactionCategory.cast(target)
      [value.to_s.strip, canonical] if canonical.present?
    }.to_h
  end

  def verify!(headers)
    missing = REQUIRED.reject { |field| @mapping[field].present? }
    if missing.present?
      raise(MissingMapping, "Choose a column for: #{missing.map { |f| FIELD_LABELS[f] }.join(", ")}.")
    end

    unknown = @mapping.values - headers
    return if unknown.empty?

    raise(MissingMapping, "This file has no column called #{unknown.uniq.join(", ")}.")
  end

  def value(row, field)
    column = @mapping[field]
    return nil if column.blank?

    row[column]
  end

  def import_row(row, index)
    identifier = value(row, :identifier).to_s.strip
    # Without an id there is nothing to dedupe on, and importing it anyway
    # means a duplicate on every future upload. Named in the result instead.
    if identifier.blank?
      @skipped += 1
      @errors << "Row #{index + 2} carries no #{@mapping[:identifier]}."
      return
    end

    occurred = parse_date(value(row, :date))
    cents = parse_cents(value(row, :amount))
    if occurred.nil? || cents.nil?
      @skipped += 1
      @errors << "Row #{index + 2} (#{identifier}) has no usable date or amount."
      return
    end

    write(row, "#{@source}:#{identifier}", occurred, cents)
  end

  def write(row, key, occurred, cents)
    transaction = ::BankTransaction.find_or_initialize_by(upstream_id: key)
    created = transaction.new_record?
    payee = payee_for(row)
    account = account_for(row)

    transaction.assign_attributes(
      bank_account:  account,
      # The statement reports a posting date and nothing finer. Both columns
      # get it so the row sorts and searches like every other, and
      # `occurred_time_known?` reads it as date-only, which it is.
      posted_at:     occurred,
      transacted_at: occurred,
      amount_cents:  cents,
      description:   description_for(row),
      payee:         payee,
      pending:       false,
    )
    # Only ever fills a blank. A re-upload must not overwrite a category set by
    # hand on the banking page — the mapping is what we started from, and the
    # person's correction is the reason it changed.
    transaction.category ||= categorize(row, payee)&.to_s
    transaction.metadata = transaction.metadata.to_h.merge("import" => provenance)
    transaction.save!

    @accounts[account&.display_name || "Unattributed"] += 1
    created ? @created += 1 : @updated += 1
  end

  def provenance
    { "source" => @source, "file" => @filename, "at" => ::Time.current.iso8601 }.compact
  end

  # Where the row goes. A file that names an account gets matched on last four
  # or on name; anything unmatched falls back to the account chosen at upload,
  # because a fallback that refuses to catch things is not one.
  def account_for(row)
    named = value(row, :account).to_s.strip
    return @fallback if named.blank?

    @resolved.fetch(named) { @resolved[named] = match_account(named) || @fallback }
  end

  def match_account(named)
    last4 = named[/(\d{4})\D*\z/, 1]
    scope = ::BankAccount.where(last4: last4) if last4.present?
    found = scope&.first
    return found if found.present?

    ::BankAccount.where("name ILIKE ? OR friendly_name ILIKE ?", named, named).first
  end

  # The person's own mapping wins, because they chose it looking at the values.
  # A value they left blank falls through to the merchant rules, which is the
  # right answer for every label that names the DIRECTION of the money rather
  # than its purpose — "Transfers" and "Deposits" say nothing a rule cannot say
  # better from the payee.
  def categorize(row, payee)
    label = value(row, :category).to_s.strip
    return @categories[label] if @categories.key?(label)

    ::TransactionCategory.for_merchant(payee)
  end

  # The fullest text the file carries, kept whole. `payee` is the tidied name;
  # this is what it was tidied from.
  def description_for(row)
    value(row, :description).to_s.strip.presence || value(row, :payee).to_s.strip.presence
  end

  # Reads the payee column when the file has one and the description otherwise,
  # then pulls a merchant out of whichever it got. Both go through the same
  # cleanup because a "payee" column is frequently the raw wire string too.
  def payee_for(row)
    named = value(row, :payee).to_s.strip
    described = value(row, :description).to_s.strip
    candidates = [named, described].compact_blank

    company = candidates.filter_map { |text| text[ACH_COMPANY, 1] }.first
    return tidy(company) if company.present?

    clean = candidates.detect { |text| !text.match?(RAW_DESCRIPTION) }
    return clean if clean.present?

    raw = candidates.first.to_s
    tidy(raw.sub(LEADING_NOISE, "").sub(TRAILING_NOISE, "")).presence || raw.presence
  end

  def tidy(text)
    text.to_s.squeeze(" ").strip
  end

  # The file's running balance, from whichever row is newest — which is not
  # necessarily the first or last line, since export order is the institution's
  # business.
  #
  # Only ever the FALLBACK account. A file spread across several accounts says
  # nothing about what any one of them ended at, so guessing from the last row
  # would write one account's balance onto whichever it happened to belong to.
  #
  # `kind` is left alone deliberately. A new account lands as `unknown` and is
  # excluded from the dashboard figure until it is classified by hand, so an
  # import can never silently move the headline number.
  def apply_balance(table)
    return if @mapping[:balance].blank? || @fallback.nil?
    return if @mapping[:account].present?

    newest = table.max_by { |row| parse_date(value(row, :date)) || ::Time.at(0).utc }
    cents = parse_cents(value(newest, :balance)) if newest
    date = parse_date(value(newest, :date)) if newest
    return if cents.nil? || date.nil?
    # An older export must not walk the balance backwards over a newer one.
    return if @fallback.balance_date.present? && @fallback.balance_date > date

    @fallback.update!(balance_cents: cents, balance_date: date, last_synced_at: ::Time.current)
  end

  # Local midnight, matching what BankTransaction#derive_occurred_at does to a
  # date-only row from any other feed — so an imported row sorts beside a Chase
  # one from the same day instead of six hours off it.
  #
  def parse_date(text)
    body = text.to_s.strip
    return nil if body.blank?

    ::User.timezone {
      DATE_FORMATS.each { |format|
        parsed = begin
          ::Time.zone.strptime(body, format)
        rescue ::ArgumentError
          nil
        end
        return parsed if parsed
      }
      nil
    }
  end

  # BigDecimal, never to_f. These files write five decimal places
  # ("-27.71000") and a float round-trip on a mortgage-sized figure is how it
  # ends up off by a cent.
  #
  # Parentheses are how a good many exports write a negative.
  def parse_cents(text)
    body = text.to_s.strip.delete(",$ ")
    return nil if body.blank?

    negative = body.delete_prefix!("(") && body.delete_suffix!(")")
    cents = (BigDecimal(body) * 100).round
    negative ? -cents.abs : cents
  rescue ::ArgumentError
    nil
  end
end
