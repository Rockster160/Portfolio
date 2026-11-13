# A page that installs as its own home-screen app wearing an icon its owner
# picked: an emoji, glyph or household upload on a flat colour, drawn by the
# phone into one 512px PNG (`app_icon.js`) and kept here as `icon_png`.
# `icon` and `icon_color` are what was picked, so the picker can show it again.
#
# A browser fetches a manifest and an icon with no cookies, so a signed token
# stands in for the session, and a record id alone opens nothing.
module HomeScreenIcon
  extend ActiveSupport::Concern

  DEFAULT_COLOR = "#000712".freeze
  DEFAULT_ICONS = [
    { src: "/favicon/android-chrome-192x192.png", sizes: "192x192", type: "image/png" },
    { src: "/favicon/android-chrome-512x512.png", sizes: "512x512", type: "image/png" },
  ].freeze
  # An emoji or glyph on a flat colour is a few KB; a household photo icon a
  # little more.
  MAX_ICON_BYTES = 256.kilobytes
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  ICON_COLOR = /\A#\h{6}\z/

  included do
    normalizes :icon, :icon_color, with: ->(value) { value.presence }

    validates :icon, length: { maximum: 200 }
    validates :icon_color, format: { with: ICON_COLOR }, allow_nil: true
    validate :icon_png_is_png
  end

  class_methods do
    def install_purpose
      :"#{model_name.singular}_install"
    end

    def from_install_token(token)
      find_signed(token.to_s, purpose: install_purpose)
    end
  end

  def install_token
    signed_id(purpose: self.class.install_purpose)
  end

  def icon?
    icon_png.present?
  end

  def home_screen_color
    icon_color.presence || DEFAULT_COLOR
  end

  # Takes the PNG as the data URL the canvas hands over, or blank to clear it.
  def icon_data_url=(value)
    self.icon_png = (
      if value.blank?
        nil
      else
        Base64.decode64(value.to_s.delete_prefix("data:image/png;base64,"))
      end
    )
  end

  # The PNG is served at its own URL; raw bytes in a JSON body only break it.
  def serializable_hash(options=nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + [:icon_png]
    super
  end

  # The install manifest: opens on `path`, named after the record, wearing
  # the icon at `icon_src`, or the site's icons when there is none.
  def install_manifest(id:, path:, icon_src:, description:)
    icons = (
      if icon_src
        [192, 512].map { |size|
          { src: icon_src, sizes: "#{size}x#{size}", type: "image/png", purpose: :any }
        }
      else
        DEFAULT_ICONS
      end
    )

    {
      short_name:       name.truncate(12),
      name:             name,
      icons:            icons,
      id:               id,
      start_url:        "#{path}?source=pwa",
      scope:            path,
      background_color: home_screen_color,
      display:          :standalone,
      theme_color:      home_screen_color,
      description:      description,
    }
  end

  private

  def icon_png_is_png
    return if icon_png.nil?

    bytes = icon_png.b
    errors.add(:icon_png, "is not a PNG") unless bytes.start_with?(PNG_SIGNATURE)
    errors.add(:icon_png, "is too large") if bytes.bytesize > MAX_ICON_BYTES
  end
end
