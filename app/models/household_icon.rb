# == Schema Information
#
# Table name: household_icons
#
#  id                  :bigint           not null, primary key
#  image_data          :text             not null
#  keywords            :text             default(""), not null
#  name                :text             not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  chore_household_id  :bigint           not null
#  uploaded_by_user_id :bigint           not null
#
class HouseholdIcon < ApplicationRecord
  MAX_IMAGE_BYTES = 300_000        # raw byte length of the data-URL string
  MAX_NAME_LENGTH = 60
  MAX_KEYWORDS_LENGTH = 400

  belongs_to :chore_household
  belongs_to :uploaded_by_user, class_name: "User"

  before_validation :normalize_fields

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validates :name, uniqueness: { scope: :chore_household_id, case_sensitive: false }
  validates :keywords, length: { maximum: MAX_KEYWORDS_LENGTH }
  validates :image_data, presence: true
  validates :image_data, length: { maximum: MAX_IMAGE_BYTES }
  validate :image_data_must_be_data_url

  scope :ordered, -> { order(Arel.sql("LOWER(name) ASC")) }

  # Case- and separator-insensitive lookup within the user's household.
  # Returns nil when user has no household or no icon matches.
  # Used by the [hicon <name>] markdown parser.
  def self.lookup(user, name)
    return nil if user.nil? || name.blank?

    household = user.chore_household
    return nil if household.nil?

    key = normalize_name(name)
    household.icons.detect { |i| normalize_name(i.name) == key }
  end

  def self.normalize_name(name)
    name.to_s.downcase.gsub(/[\s_-]+/, " ").strip
  end

  # Comma-separated user-supplied list. Indexed alongside the auto-split
  # name words on the client.
  def keyword_list
    keywords.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)
  end

  # Shape consumed by the JS IconPool — same `{ c, n, k }` envelope as
  # emoji / ti rows. Kind is tagged on the client side.
  def as_pool_row
    name_words = name.to_s.downcase.split(/[\s_-]+/).reject(&:empty?)
    {
      id:          id,
      c:           image_data,
      n:           name,
      k:           (keyword_list + name_words).map(&:downcase).uniq,
      uploaded_by: uploaded_by_user_id,
    }
  end

  private

  def normalize_fields
    self.name = name.to_s.strip
    self.keywords = keywords.to_s.strip
  end

  def image_data_must_be_data_url
    return if image_data.to_s.start_with?("data:image/")

    errors.add(:image_data, "must be a data:image/* URL")
  end
end
