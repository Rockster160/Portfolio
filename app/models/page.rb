# == Schema Information
#
# Table name: pages
#
#  id                 :bigint           not null, primary key
#  content            :text
#  name               :string
#  parameterized_name :text
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  folder_id          :bigint
#  user_id            :bigint           not null
#
class Page < ApplicationRecord
  attr_accessor :skip_broadcast

  include Folderable, Orderable

  belongs_to :folder, optional: true, touch: true
  belongs_to :user
  has_many :page_tags
  has_many :tags, through: :page_tags

  before_save :assign_parameterized_name

  after_commit :broadcast_timestamp

  validates :parameterized_name, uniqueness: { scope: :user_id }

  def timestamp=(new_timestamp)
    self.updated_at = Time.zone.at(new_timestamp.to_i)
  end

  def folder_name=(new_folder_name)
    folder = user.folders.ilike(parameterized_name: new_folder_name.parameterize).take!
    self.folder_id = folder.id
  end

  def to_full_packet
    to_packet.merge(content: content)
  end

  def to_packet
    {
      id:        id,
      timestamp: updated_at.to_i,
      name:      parameterized_name,
      folder:    folder&.parameterized_name,
    }
  end

  private

  def assign_parameterized_name
    base_name = name.parameterize
    unique_name = base_name
    counter = 0
    while Page.where(user_id: user_id, parameterized_name: unique_name).where.not(id: id).any?
      unique_name = "#{base_name}-#{id}#{"-#{counter}" if counter.positive?}"
      counter += 1
    end

    self.parameterized_name = unique_name
  end

  def broadcast_timestamp
    return if @skip_broadcast

    PageChannel.broadcast_to(user, { changes: [to_packet] })
  end
end
