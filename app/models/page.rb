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
  include Orderable
  include Folderable

  belongs_to :folder, optional: true, touch: true
  belongs_to :user
  has_many :page_tags
  has_many :tags, through: :page_tags

  before_save -> { self.parameterized_name = name.parameterize }

  after_commit :broadcast_timestamp

  validates :parameterized_name, uniqueness: { scope: :user_id }

  def timestamp=(new_timestamp)
    self.updated_at = Time.at(new_timestamp.to_i)
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

  def broadcast_timestamp
    return if @skip_broadcast

    PageChannel.broadcast_to(user, { changes: [to_packet] })
  end
end
