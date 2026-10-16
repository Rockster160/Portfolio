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
    Buddy::Themes.all.to_h { |theme, chrome|
      [theme, {
        name:       chrome[:name],
        color:      chrome[:color],
        avatar:     asset_path(chrome[:avatar]),
        touch_icon: asset_path(chrome[:touch_icon]),
        favicon:    asset_path(chrome[:favicon]),
        faces:      buddy_face_paths(theme),
        aliases:    buddy_face_aliases(theme),
      }]
    }.to_json
  end

  # A pet's face set as `{ expression => fingerprinted_url }`, read straight off
  # disk. The hero paints the character from this (buddy/hero.js sets the one
  # for the current expression as the face layer's background), and switching
  # into a thread warms the lot before the hero asks for any. Keyed by
  # expression so neither the client nor the stylesheet keeps a second list of
  # which faces a pet has — the folder is the only source, which is what lets a
  # companion be its images plus its sentiment map and nothing else.
  def buddy_face_paths(theme)
    faces = Rails.root.glob("app/assets/images/buddy/#{theme}/face_*.{png,svg}").sort.to_h { |path|
      [File.basename(path, ".*").delete_prefix("face_"), image_path("buddy/#{theme}/#{File.basename(path)}")]
    }
    faces
  end

  # `{ expression => face it has art for }` for every expression name this pet
  # was never drawn with - `pounce`, `thinking`, another pet's mood - pointing at
  # its nearest drawing on the mood axes (Buddy::Faces.resolve). Sent beside the
  # art rather than as more URLs, so the page carries each image once.
  def buddy_face_aliases(theme)
    Buddy::Faces.resolved_names(theme).filter_map { |name, drawn|
      [name.to_s, drawn.to_s] if name != drawn
    }.to_h
  end

  # The URL for one expression: its own art, else the nearest drawing this pet
  # has (Buddy::Faces.resolve), else neutral for a name no pet has ever had.
  # Used for the hero's first paint, before the client takes over.
  def buddy_face_url(theme, expression)
    faces = buddy_face_paths(theme)
    faces[expression.to_s] || faces[Buddy::Faces.resolve(theme, expression).to_s] || faces["neutral"]
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
