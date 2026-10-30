# == Schema Information
#
# Table name: recording_skips
#
#  id         :bigint           not null, primary key
#  key        :string           not null
#  label      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
# A source the recorder is not to record from.
#
# IT DENIES RATHER THAN ALLOWS, deliberately. A list of the apps worth
# recording is a list that silently misses an entire interview the first time a
# call happens somewhere new, and an interview that was never recorded cannot
# be recovered - where an hour of something irrelevant costs a glance and one
# press. So everything is recorded and this is how a source stops.
#
# THE KEY IS THE SITE BEFORE THE APP. Denying the browser would take the
# interviews with it: a call on a meeting site and a call on a chat site are
# the same application, and the only thing that tells them apart is the host.
# `JobTranscript#source_key` picks in the same order for the same reason.
#
# IT LIVES HERE RATHER THAN ON THE LAPTOP so it can be managed from the page
# where the recording he does not want is already sitting. The recorder reads
# it on every upload, which is the one moment it is certainly talking to the
# board.
class RecordingSkip < ApplicationRecord
  belongs_to :user

  validates :key, presence: true, uniqueness: { scope: :user_id }

  scope :ordered, -> { order(:key) }

  def self.keys_for(user)
    where(user: user).ordered.pluck(:key)
  end

  def self.skipped?(user, key)
    return false if key.blank?

    exists?(user: user, key: key)
  end

  # Pressed on a recording rather than typed into a settings page, so the key
  # comes off the recording itself and the label is whatever it is readable as.
  def self.from!(transcript)
    key = transcript.source_key
    return nil if key.blank?

    find_or_create_by!(user: transcript.owner, key: key) { |skip|
      skip.label = transcript.source_label
    }
  end

  def label_or_key
    label.presence || key
  end
end
