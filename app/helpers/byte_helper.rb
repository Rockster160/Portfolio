module ByteHelper
  # Every pet's identity, resolved through the asset pipeline, for the client to
  # repaint from on a conversation switch.
  #
  # Rendered once as a blob rather than riding each conversation's wire payload,
  # because the client needs themes it has no open thread for: the drawer shows
  # a pet per row, and switching into a thread warms that pet's face images. It
  # stays generated from Buddy::Themes, so adding a companion is still one entry
  # there and nothing to remember here.
  def buddy_themes_json
    Buddy::Themes::ALL.to_h { |theme, chrome|
      [theme, {
        name:       chrome[:name],
        color:      chrome[:color],
        avatar:     asset_path(chrome[:avatar]),
        touch_icon: asset_path(chrome[:touch_icon]),
        favicon:    asset_path(chrome[:favicon]),
        faces:      buddy_face_paths(theme),
      }]
    }.to_json
  end

  # Fingerprinted paths for a pet's face set, so switching into a thread can
  # warm them before the hero asks for one. Inlined rather than fetched: it's
  # about forty paths across every pet, which is cheaper than another endpoint.
  def buddy_face_paths(theme)
    Rails.root.glob("app/assets/images/buddy/#{theme}/face_*.{png,svg}").sort.map { |path|
      image_path("buddy/#{theme}/#{File.basename(path)}")
    }
  end

  # Compact form of an absolute filesystem path — swaps `/Users/zoro`
  # (or whatever the current runtime user's home is) for `~`. Used by the
  # pwd bar so the drawer / header stays tight even for deep paths.
  def short_home(path)
    return "" if path.blank?

    home = ENV["HOME"].to_s
    return path if home.empty?
    path.start_with?(home) ? path.sub(home, "~") : path
  end
end
