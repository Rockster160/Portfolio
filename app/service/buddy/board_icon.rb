module Buddy
  # How a board cell classifies a glyph string, so the client paints it the same
  # way a chore's icon is painted (see ChoreSerializer#icon_kind and the board's
  # iconNode): an uploaded image or SVG, a Tabler `ti-…` name, or an emoji. Blank
  # is `:empty`, which the cell draws as the first letter of the name.
  #
  # One home for the rule, shared by every board item that carries an optional
  # icon (BuddyRoutine triggers, BoardTaskButton).
  module BoardIcon
    module_function

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
