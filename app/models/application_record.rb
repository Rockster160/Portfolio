class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  attr_accessor :new_attributes

  include Jsonable, Jilable

  # A date term nothing could be made of. Raised rather than handed back as the
  # raw string it came in as — see `parse_date`.
  class UnreadableDate < ::StandardError; end

  # What a term becomes when it cannot be turned into a comparison.
  #
  # FAIL CLOSED, never open. The alternative — dropping the term — is how a
  # search silently WIDENS: `timestamp>` with a blank value used to match every
  # row, so a Jil task summing a day of calories summed all of history, and the
  # nightly Whisper cleanup would have deleted every Whisper event rather than
  # the ones older than a week. Nothing about the output said so.
  #
  # Zero rows reads as "that cannot be right" to a person. A full list reads as
  # a page that worked. Where the two have to differ, be wrong in the direction
  # that gets noticed.
  #
  # Composes the way it should: `-timestamp:junk` is NOT (FALSE), which is
  # everything — excluding an unreadable date excludes nothing.
  NO_MATCH_SQL = "FALSE".freeze

  # Why a term did not do what it looked like it would. Collected while a query
  # is built and read straight afterwards by whoever asked, so a search box can
  # say "I could not read that date" rather than showing an empty page and
  # leaving you to guess.
  #
  # Fiber-isolated rather than a class variable: these are class-level scopes
  # on a threaded server, and two requests searching at once must not read each
  # other's complaints.
  def self.search_notes
    ::ActiveSupport::IsolatedExecutionState[:search_notes] ||= []
  end

  def self.reset_search_notes
    ::ActiveSupport::IsolatedExecutionState[:search_notes] = []
  end

  def self.note_search_problem(message)
    search_notes << message unless search_notes.include?(message)
    NO_MATCH_SQL
  end

  # TODO: Support `started_at: :start` to tweak the helper methods to be `start!` instead of `started!`
  def self.timestamp_bool(*cols)
    cols.map(&:to_sym).each do |col|
      bool = col.to_s.gsub(/_at\z/, "").to_sym

      define_method("#{bool}?") { send("#{col}?") }
      define_method("#{bool}!") { update!(col => ::Time.current) }
      define_method("#{bool}=") { |v| send("#{col}=", v ? ::Time.current : nil) }

      scope bool, -> { where.not(col => nil) }
      scope "not_#{bool}", -> { where(col => nil) }
    end
  end

  def self.ilike(hash, join=:OR)
    where(build_query(hash, :ILIKE, join), *hash.values)
  end

  def self.not_ilike(hash, join=:AND)
    # where(build_query(hash, "NOT ILIKE", join), *hash.values)
    where(
      # Dumb PG removes empty values when querying for a NOT for some reason
      hash.map { |k, _v| "(\"#{k.to_s.gsub(".", "\".\"")}\"::TEXT NOT ILIKE ? OR \"#{k.to_s.gsub(".", "\".\"")}\" IS NULL)" }.join(" #{join} "),
      *hash.values,
    )
  end

  def self.build_query(hash, point, join_with=:AND)
    hash.map { |k, _v| "\"#{k.to_s.gsub(".", "\".\"")}\"::TEXT #{point} ?" }.join(" #{join_with} ")
  end

  def self.search_scope
    # Redefine this in the model if a `joins` or other default scope is needed
    unscoped
  end

  def self.search_terms(*set_terms)
    # alias => column
    @search_terms ||= (
      terms = {}
      set_terms.each do |set_term|
        case set_term
        when Hash then terms.merge!(set_term)
        else terms[set_term] = set_term
        end
      end
      terms
    )
  end

  def self.search_indexed(word)
    search_terms.values.filter_map { |column|
      next column if column.to_s.include?(".")

      column_data = columns.find { |c| c.name == column.to_s }
      next column if column_data&.type.in?(%i[string text])
    }.index_with(word)
  end

  def self.stripped_sql
    all.to_sql.gsub(/(?: AND )?SELECT "#{table_name}"\.\* FROM "#{table_name}"(?: WHERE )?/, "")
      .gsub(/ ?LEFT OUTER JOIN "\w+" ON "\w+"."id" = "#{table_name}"."\w+" WHERE/, "")
  end

  def self.raw_sql(q, *data)
    sql = search_scope.where(q, *data)
    # Executed to prove the SQL runs, because what gets used is the WHERE
    # clause as a STRING and by then there is no one left to complain to.
    #
    # In a savepoint, because a failed statement aborts the whole surrounding
    # transaction: every query after it — including ones with nothing to do
    # with the search — then fails with "current transaction is aborted"
    # instead, and the page falls over somewhere unrelated to the typo that
    # caused it. Rolling back to a savepoint leaves the caller's transaction
    # intact so the rescue below is worth something.
    transaction(requires_new: true) { sql.any? }
    sql.stripped_sql
  rescue ActiveRecord::StatementInvalid => e
    # The same answer in every environment, deliberately. It used to raise
    # outside production and swallow inside it, which meant the specs proved
    # something production did not do — the one behaviour nobody could see was
    # the only one that ran.
    ::Rails.logger.error("[#{name}.raw_sql] #{e.message.lines.first.to_s.strip} -- #{q}")
    note_search_problem("could not apply #{q.to_s.split(/\s+/).first}")
  end

  def self.node_sql(node, parent_node=nil)
    field = (parent_node&.field || node.field)&.to_sym
    return if field.nil?
    return search_scope.search(field).stripped_sql unless search_terms.key?(field)

    # A bare word parses as a field with NO operator and no conditions. When
    # that word happens to also be a search-term name it slipped past the
    # check above and hit `.to_sym` on a nil operator below, taking the whole
    # search down with a NoMethodError — searching ActionEvents for "notes",
    # or bank transactions for "transfer", raised rather than searching.
    #
    # A word on its own is free text whatever it is named, so fall through to
    # the same search any other bare word gets.
    operator = (parent_node&.operator || node.operator)&.to_sym
    return search_scope.search(field).stripped_sql if operator.nil?

    column = search_terms[field]
    column_data = nil
    scope_method = nil

    if column.to_s.exclude?(".") && column_names.exclude?(column.to_s)
      scope_method = column
      column = nil
    elsif column.to_s.include?(".")
      table, table_column = column.to_s.split(".")
      column_data = table.classify.constantize.columns.find { |c| c.name == table_column }
    else
      column_data = columns.find { |c| c.name == column.to_s }
    end
    column = "#{table_name}.#{column}" if column.is_a?(Symbol)

    text_operators = %i[: :: !: !::] # ~ !~
    numeric_operators = %i[= != < > <= >=]
    # json_operators = %i[=> ->]
    # Eventually this should detect that it's a json column and use the jsonb operators
    Array.wrap(node.conditions).map { |value|
      if value.is_a?(Tokenizing::Node)
        next json_node_sql(column, value) if column_data&.type == :jsonb

        next search_scope.query_by_node(value, node).stripped_sql
      end

      next unless operator.in?(text_operators + numeric_operators)

      # rubocop:disable Lint/RedundantSplatExpansion
      if scope_method.present?
        search_scope.send(scope_method, *value).stripped_sql
      elsif column_data.type.in?(%i[string text])
        case operator
        when *%i[:] then raw_sql("#{column} ILIKE ?", "%#{value}%")
        when *%i[:: =] then raw_sql("#{column} ILIKE ?", value)
        when *%i[!:] then raw_sql("#{column} NOT ILIKE ?", "%#{value}%")
        when *%i[!:: !=] then raw_sql("#{column} NOT ILIKE ?", value)
        end
      elsif column_data.type.in?(%i[datetime date])
        date_node_sql(column, operator, value)
      elsif column_data.type.in?(%i[integer float decimal])
        numeric = column_data.type == :integer ? value.to_i : value.to_f
        case operator
        when *%i[= : ::] then raw_sql("#{column} = ?", numeric)
        when *%i[!= !: !::] then raw_sql("#{column} != ?", numeric)
        when *%i[<] then raw_sql("#{column} < ?", numeric)
        when *%i[>] then raw_sql("#{column} > ?", numeric)
        when *%i[<=] then raw_sql("#{column} <= ?", numeric)
        when *%i[>=] then raw_sql("#{column} >= ?", numeric)
        end
      end
    }.compact_blank.then { |values|
      # Nothing survived: an operator this column cannot use, a value nothing
      # could be made of, or — the one that bit — a term with an operator and
      # NO VALUE AT ALL. `timestamp>` tokenizes to no conditions, and dropping
      # it turned "since this morning" into "since the beginning of time"
      # without a word. It says no instead.
      next no_match_for(field, node) if values.empty?
      next values.first unless values.many?

      case node.operator
      when :AND then "((#{values.join(") AND (")}))"
      when :OR then "((#{values.join(") OR (")}))"
      when :NOT then "NOT ((#{values.join(") AND (")}))"
      end
    }
  end
  # rubocop:enable Lint/RedundantSplatExpansion

  # A date names a unit and each operator resolves to one end of it, so this is
  # six near-identical calls rather than one. Split out from `node_sql` for the
  # rescue: `parse_date` raises on a value it cannot read, and the whole term
  # becomes a no-match rather than invalid SQL or — worse — nothing at all.
  # rubocop:disable Lint/RedundantSplatExpansion -- reads as one list per branch
  def self.date_node_sql(column, operator, value)
    case operator
    when *%i[= : ::] then raw_sql("(#{column} >= ? AND #{column} <= ?)", *parse_date(value, range: true).minmax)
    when *%i[!= !: !::] then raw_sql("(#{column} < ? OR #{column} > ?)", *parse_date(value, range: true).minmax)
    when *%i[<] then raw_sql("#{column} < ?", parse_date(value, operator: operator))
    when *%i[>] then raw_sql("#{column} > ?", parse_date(value, operator: operator))
    when *%i[<=] then raw_sql("#{column} <= ?", parse_date(value, operator: operator))
    when *%i[>=] then raw_sql("#{column} >= ?", parse_date(value, operator: operator))
    end
  rescue UnreadableDate => e
    note_search_problem("could not read the date #{e.message}")
  end
  # rubocop:enable Lint/RedundantSplatExpansion

  # Says which term went nowhere, so the complaint names something the person
  # can actually see in the box they typed it into.
  def self.no_match_for(field, node)
    term = [field, node.operator].compact.join
    note_search_problem("#{term} matched nothing it could be read as")
  end

  JSON_NUMERIC_RX = '^-?[0-9]+(\.[0-9]+)?$'.freeze

  # Generic jsonb key search. List a jsonb column in `search_terms` and every
  # key inside it becomes queryable as `column:key<op>value` — `data:transfer!::true`,
  # `data:merchant:VENMO`, `data:amount>100` — for any model, no per-key scope.
  #
  # Keys are compared as text (`->>`) since a jsonb key carries no declared type;
  # numeric operators guard the cast with a numeric-shaped check so a stray
  # string in one row can't blow up the whole query.
  #
  # Negative operators are NULL-safe: a row missing the key entirely reads as
  # "not that value" rather than dropping out. That matters on sparse jsonb,
  # where most rows predate whatever key you're filtering on. (A leading `-`/`NOT`
  # is plain boolean negation of the match and stays NULL-sensitive.)
  def self.json_node_sql(column, node)
    key = node.field.to_s
    return if key.blank?

    path = "#{column}->>?"

    Array.wrap(node.conditions).filter_map { |value|
      next if value.is_a?(Tokenizing::Node)

      case node.operator&.to_sym
      when :":" then raw_sql("#{path} ILIKE ?", key, "%#{value}%")
      when :"::", :"=" then raw_sql("#{path} ILIKE ?", key, value)
      when :"!:" then raw_sql("(#{path} IS NULL OR #{path} NOT ILIKE ?)", key, key, "%#{value}%")
      when :"!::", :"!=" then raw_sql("(#{path} IS NULL OR #{path} NOT ILIKE ?)", key, key, value)
      when :<, :>, :<=, :>=
        # The shape check is bound, not inlined — a `?` inside a SQL literal
        # would be miscounted as a bind placeholder.
        raw_sql(
          "(#{path} ~ ? AND (#{path})::numeric #{node.operator} ?)",
          key, JSON_NUMERIC_RX, key, value.to_f
        )
      end
    }.then { |values|
      # Same rule as `node_sql`: a jsonb term that produced no comparison — an
      # operator with no value, or one this path does not handle — must narrow
      # to nothing rather than quietly disappear.
      next note_search_problem("#{key} matched nothing it could be read as") if values.empty?
      next values.first unless values.many?

      "((#{values.join(") OR (")}))"
    }
  end

  scope :assign, ->(data) {
    relation = all
    # prev = relation.instance_variable_get(:@assigned_data) || {}
    relation.instance_variable_set(:@assigned_data, data)
    relation
  }
  def self.assigned(key)
    (all.instance_variable_get(:@assigned_data) || {})[key]
  end

  scope :search, ->(q) {
    raise "No `search_terms` defined for #{name}" if search_terms.blank?
    next none if search_terms.blank?

    search_scope.ilike(search_indexed("%#{q}%"), :OR)
  }
  scope :unsearch, ->(q) {
    raise "No `search_terms` defined for #{name}" if search_terms.blank?
    next none if search_terms.blank?

    not_ilike(search_indexed("%#{q}%"), :AND)
  }
  scope :query_by_node, ->(node, parent_node=nil) {
    # TODO: # Allow passing `offset:50` and `limit:50` to the query
    sql = (
      if node.field.nil?
        conditions = (
          if parent_node
            [node_sql(node, parent_node)]
          else
            Array.wrap(node.conditions).map { |condition|
              if condition.is_a?(Tokenizing::Node)
                search_scope.query_by_node(condition).stripped_sql
              else
                search_scope.search(condition).stripped_sql
              end
            }.compact_blank
          end
        )

        next if conditions.blank?

        case node.operator&.to_sym
        when :AND then "(#{conditions.join(" AND ")})"
        when :OR then "(#{conditions.join(" OR ")})"
        when :NOT then "NOT (#{conditions.join(" AND ")})"
        end
      else
        node_sql(node)
      end
    ).to_s

    # Reduce parens:
    tz = Tokenizer.new(sql)
    str = tz.tokenized_text
    sql = tz.untokenize { |val|
      /\A\((\w+)\)\z/.tap { |rx| val = val.gsub(rx, '\1') while val.match?(rx) }
      val
    }
    next if sql.blank?

    where(sql)
  }
  scope :query, ->(q) {
    # One search, one set of complaints. Reset here rather than in the caller:
    # this is where a search begins, and every path into the pipeline —
    # controller, Jil, Buddy — comes through it.
    reset_search_notes
    next search_scope.all if q.to_s.strip.blank?

    breaker = ::Tokenizing::Node.parse(q)
    sql = search_scope.query_by_node(breaker).stripped_sql

    # Something was typed and none of it became a filter — a lone `AND`, an
    # unclosed `(`, a bare `NOT`. Returning every row is the one answer that
    # cannot be right: it is a page that looks like it worked.
    sql = note_search_problem("could not read that search") if sql.blank?

    # NOTE! This removes current scope! This will lose user filtering!!!
    search_scope.where(sql)
    # Will this work to fix the above?
    # where(search_scope.query_by_node(breaker).stripped_sql)
  }
  scope :before, ->(time) { # Not used by `query` scope
    User.timezone {
      t = ::DateTime.parse(time) rescue (next none)

      key = column_names.include?("timestamp") ? :timestamp : :created_at
      where(key => ..t)
    }
  }
  scope :after, ->(time) { # Not used by `query` scope
    User.timezone {
      t = ::DateTime.parse(time) rescue (next none)

      key = column_names.include?("timestamp") ? :timestamp : :created_at
      where(key => t..)
    }
  }

  class << self
    alias json_serialize serialize
  end

  def self.serialize(opts={})
    all.map { |item| item.serialize(opts) }
  end

  def serialize(opts={})
    as_json(
      opts.reverse_merge(except: [:created_at, :updated_at]),
    ).merge(@execution_attrs || {}).with_indifferent_access
  end

  def new(attrs={})
    @new_attributes = attrs
    super
  end

  def assign_attributes(attrs={})
    @new_attributes = attrs
    super
  end

  def create(attrs={})
    @new_attributes = attrs
    super
  end

  def update(attrs={})
    @new_attributes = attrs
    super
  end

  def error_messages
    errors&.full_messages || []
  end

  def to_h
    as_json
  end

  def self.parse_date(value, operator: nil, range: false)
    ::User.timezone {
      begin
        now = Time.current
        year, mth, day, hr, mn, sec = vals = value.split(/\D/).map(&:to_i)
        # A value with no digits at all ("notadate") splits to nothing, and
        # every line below reads `year` — so this used to leave the method with
        # a NoMethodError on nil rather than with the "could not read it"
        # answer the two rescues below already know how to give.
        raise ArgumentError, "no date in #{value.inspect}" if vals.empty?

        if year <= 12
          mth, day, hr, mn, sec = year, mth, day, hr, mn
          year = now.year
          vals = [year, mth, day, hr, mn, sec].compact
        end

        full_year = (year ||= now.year) < 1000 ? year + 2000 : year
        # Ruby will happily build the year 99999999999; Postgres will not, and
        # the failure lands as invalid SQL four layers away from the digits
        # that caused it. Rejected here, where the value is still legible.
        raise ::ArgumentError, "year out of range in #{value.inspect}" unless full_year.between?(1000, 9999)

        date_str = [
          full_year,
          (mth ||= now.month),
          (day ||= now.day),
        ].join("-")

        time_str = [
          (hr ||= now.hour).then { |h| value.match?(/pm/i) && h < 12 ? h + 12 : h },
          (mn ||= now.min),
          (sec ||= now.sec),
        ].map { |t| t.to_s.rjust(2, "0") }.join(":")

        date = Time.zone.parse("#{date_str} #{time_str}")
        units = [:year, :month, :day, :hour, :minute, :second]
        return (range ? date.all_day : date) if vals.length > units.length

        unit = units[vals.length - 1]
        # A date names a UNIT, not an instant — `2026-08` is a whole month — so
        # each operator has to resolve to whichever end of that unit makes the
        # comparison mean what it says. The two inclusive operators reach for the
        # far edge, the two exclusive ones for the near edge:
        #
        #   >= 2026-08-18  from 00:00:00, so the 18th is IN
        #   >  2026-08-18  from 23:59:59, so the 18th is skipped
        #   <= 2026-08-18  to 23:59:59, so the 18th is IN
        #   <  2026-08-18  to 00:00:00, so the 18th is skipped
        #
        # `<=` used to fall through to the same beginning-of-unit as `<`, which
        # made the two identical and `<=` useless on a date:
        # `timestamp>=2026-08-17 timestamp<=2026-08-18` returned only the 17th,
        # so no inclusive range could be expressed at all.
        if range
          date.send("beginning_of_#{unit}")..date.send("end_of_#{unit}")
        elsif operator.in?(%i[> <=])
          date.send("end_of_#{unit}")
        else
          date.send("beginning_of_#{unit}")
        end
      rescue ArgumentError, Date::Error
        # `DateTime.parse` still gets its turn — it reads the shapes the digit
        # split cannot, like "August 19, 2026".
        begin
          DateTime.parse(value).then { |dt| range ? dt.all_day : dt }
        rescue ArgumentError, Date::Error, TypeError
          # It used to hand back the raw string here, which is the root of the
          # whole mess: `timestamp:notadate` then reached `.minmax` on a String
          # and took the page down with a NoMethodError, while
          # `timestamp>=notadate` reached Postgres as a timestamp and took the
          # surrounding transaction with it. A value that is not a date is not
          # a date, and saying so is the only answer that composes.
          raise UnreadableDate, value.inspect
        end
      end
    }
  end
end
