# == Schema Information
#
# Table name: jarvis_pages
#
#  id         :bigint           not null, primary key
#  blocks     :jsonb
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class JarvisPage < ApplicationRecord
  include IndifferentJsonb
  belongs_to :user

  indifferent_jsonb :blocks

  after_initialize { self.blocks ||= default_blocks }

  private

  def default_blocks
    [
      { type: :command }
    ]
  end
end
