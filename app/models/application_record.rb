class ApplicationRecord < ActiveRecord::Base
  attr_accessor :new_attributes
  self.abstract_class = true

  def self.ilike(hash, join=:OR)
    where(build_query(hash, :ILIKE, join), *hash.values)
  end

  def self.not_ilike(hash, join=:AND)
    where(build_query(hash, "NOT ILIKE", join), *hash.values)
  end

  def self.build_query(hash, point, join_with=:AND)
    hash.map { |k, v| "#{table_name}.#{k} #{point} ?" }.join(" #{join_with} ")
  end

  def self.search_scope
    # Redefine this in the model if a `joins` or other default scope is needed
    all
  end

  def self.search_terms(*set_terms)
    # alias => column
    @@search_terms ||= begin
      terms = {}
      set_terms.each do |set_term|
        case set_term
        when Hash then terms.merge!(set_term)
        else terms[set_term] = set_term
        end
      end
      terms
    end
  end

  def self.search_indexed(word)
    search_terms.values.index_with(word)
  end

  def self.stripped_sql
    all.to_sql.gsub("SELECT \"#{table_name}\".* FROM \"#{table_name}\" WHERE ", "")
  end

  scope :search, ->(q) { ilike(search_indexed("%#{q}%"), :OR) }
  scope :unsearch, ->(q) { not_ilike(search_indexed("%#{q}%"), :AND) }
  scope :query, ->(q) {
    built = all
    data = q.is_a?(Hash) ? q : SearchParser.call(
      q,
      or: "OR:",
      not: "!",
      contains: ":",
      not_contains: "!:",
      not_exact: "!::",
      exact: "::",
      similar: "~",
      aliases: {
        ":": "="
      }
    )
    #   ~   - similar? (95% text match?)

    data.dig(:terms)&.each { |word| built = built.search(word) }
    data.dig(:props, :not)&.each { |word| built = built.unsearch(word) }

    data.dig(:props, :contains, :terms)&.each { |word| built = built.search(word) }
    data.dig(:props, :exact, :terms)&.each { |word| built = built.ilike(search_indexed(word)) }

    data.dig(:props, :not_contains, :terms)&.each { |word| built = built.unsearch(word) }
    data.dig(:props, :not_exact, :terms)&.each { |word| built = built.not_ilike(search_indexed(word)) }

    search_terms.each do |alt_name, col_name|
      data.dig(:props, :contains, :props, alt_name)&.each { |word| built = built.ilike(col_name => "%#{word}%") }
      data.dig(:props, :not_contains, :props, alt_name)&.each { |word| built = built.not_ilike(col_name => "%#{word}%") }
      data.dig(:props, :exact, :props, alt_name)&.each { |word| built = built.ilike(col_name => word) }
      data.dig(:props, :not_exact, :props, alt_name)&.each { |word| built = built.not_ilike(col_name => word) }
    end

    data.dig(:props, :or, :terms)&.each do |or_groups|
      sql_chunks = or_groups.map { |or_group| unscoped.query(or_group).stripped_sql }
      built = built.where("(#{sql_chunks.join(" OR ")})")
    end
    built
  }

  def new(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def assign_attributes(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def create(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def update(attrs={})
    @new_attributes = attrs
    super(attrs)
  end
end
