module Buddy
  # How a board cell classifies a glyph string, so the client paints it the same
  # way a chore's icon is painted (see ChoreSerializer#icon_kind and the board's
  # iconNode): an uploaded image or SVG, a Tabler `ti-…` name, or an emoji. Blank
  # is `:empty`, which the cell draws as the first letter of the name. A
  # household upload (`hicon:<id>`) is sent as its image, as a chore's is.
  #
  # One home for the rule, shared by every board item that carries an optional
  # icon (BuddyRoutine triggers, BoardTaskButton).
  module BoardIcon
    module_function

    # The `icon`/`icon_kind` pair a board cell paints from.
    def fields(icon)
      ref = icon.to_s.strip
      if ref.start_with?(ChoreSerializer::HICON_PREFIX)
        image = HouseholdIcon.find_by(id: ref.delete_prefix(ChoreSerializer::HICON_PREFIX).to_i)&.image_data
        return { icon: image.presence, icon_kind: image.present? ? :image : :empty }
      end

      { icon: ref.presence, icon_kind: kind_for(ref) }
    end

    def kind_for(icon)
      v = icon.to_s.strip
      return :empty if v.empty?
      return :image if v.start_with?("data:image/", "http://", "https://")
      return :svg   if v.start_with?("<svg")
      return :ti_icon if v.start_with?("ti-")

      :emoji
    end
  end
end
