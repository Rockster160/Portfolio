# A widget's contents, written by a Jil task (`Widget.set`) and drawn by the
# phone app. The shape is the app's PanelData: title, rows, buttons, chart, an
# image or SVG, and what a press does. Stored as given, so a new field reaches
# the app without a server change.
# == Schema Information
#
# Table name: app_panels
#
#  id         :bigint           not null, primary key
#  content    :jsonb            not null
#  key        :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class AppPanel < ApplicationRecord
  belongs_to :user

  validates :key, presence: true, uniqueness: { scope: :user_id }

  after_commit -> { AppPush.reload_widgets_later([user]) }, on: [:create, :update]

  def self.normalize_key(key)
    key.to_s.strip.parameterize(separator: "_").presence
  end

  def svg
    content.to_h["svg"].presence
  end

  # Widgets can't draw SVG, so the markup is handed over as a PNG url. The
  # digest in the url changes with the markup, which is what lets the phone
  # cache the image for as long as it likes.
  def serialize(base_url:)
    data = content.to_h.merge("key" => key, "updated_at" => updated_at&.iso8601)
    if svg
      digest = SvgRaster.digest(svg)
      path = "/api/ios/widgets/panels/#{CGI.escape(key)}/svg.png?v=#{digest}"
      data["svg_image_url"] = "#{base_url}#{path}"
    end
    data
  end
end
