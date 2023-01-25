class ApplicationRecord < ActiveRecord::Base
  attr_accessor :new_attributes
  self.abstract_class = true

  def self.ilike(hash)
    where(build_query(hash, :ILIKE, :OR), *hash.values)
  end

  def self.not_ilike(hash)
    where(build_query(hash, "NOT ILIKE", :AND), *hash.values)
  end

  def self.build_query(hash, point, join_with="AND")
    hash.map { |k, v| "#{table_name}.#{k} #{point} ?" }.join(" #{join_with} ")
  end

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
