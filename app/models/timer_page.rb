# == Schema Information
#
# Table name: timer_pages
#
#  id          :bigint           not null, primary key
#  layout_mode :integer          default("auto"), not null
#  meta        :jsonb            not null
#  name        :text             default(""), not null
#  sections    :jsonb            not null
#  slug        :text             not null
#  sort_order  :integer          default(0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#
class TimerPage < ApplicationRecord
  LAYOUT_MODES = { auto: 0, manual: 1, list_rings: 2, list_rows: 3 }.freeze
  enum :layout_mode, LAYOUT_MODES

  belongs_to :user
  has_many :timers, dependent: :nullify
  has_many :share_tokens, class_name: "TimerShareToken", dependent: :destroy
  has_many :page_buttons, -> { order(:sort_order, :id) }, class_name: "TimerPageButton", dependent: :destroy

  validates :slug, presence: true, uniqueness: { scope: :user_id }

  scope :ordered, -> { order(:sort_order, :id) }

  # Shallow-merge into `meta` so callers can patch a subset without
  # nuking unrelated keys. Keys are stringified by jsonb anyway; we
  # leave that conversion to PG rather than pre-massaging.
  def merge_meta!(patch)
    return self if patch.blank?

    update!(meta: (meta || {}).merge(patch.stringify_keys))
  end
end
