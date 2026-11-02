# == Schema Information
#
# Table name: short_links
#
#  id         :bigint           not null, primary key
#  key        :text             not null
#  url        :text             not null
#  visits     :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class ShortLink < ApplicationRecord
  KEY_CHARS = ::Task::SHORT_KEY_CHARS

  belongs_to :user

  before_validation :normalize_url
  before_validation :set_key, on: :create

  validates :key, presence: true, uniqueness: true
  validates :url, presence: true
  validate :url_must_be_web

  scope :recent, -> { order(created_at: :desc) }

  def self.from_key(key)
    find_by!(key: key.to_s.upcase)
  end

  # "example.com/page" is taken to mean https
  def self.normalize(url)
    url = url.to_s.strip
    url.present? && !url.match?(/\A[a-z][a-z0-9+.-]*:/i) ? "https://#{url}" : url
  end

  def short_url
    "rdjn.me/l/#{key}"
  end

  private

  def normalize_url
    self.url = self.class.normalize(url)
  end

  def set_key
    self.key ||= loop {
      candidate = Array.new(4) { KEY_CHARS.sample }.join
      break candidate unless ::ShortLink.exists?(key: candidate)
    }
  end

  # Only web links, so a short link can never open a javascript: or data: URL
  def url_must_be_web
    uri = URI.parse(url)
    errors.add(:url, "must be a web link") unless uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    errors.add(:url, "is not a valid link")
  end
end
