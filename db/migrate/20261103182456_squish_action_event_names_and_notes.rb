class SquishActionEventNamesAndNotes < ActiveRecord::Migration[7.1]
  # Events now save squished; this brings the ones saved before that in line,
  # so an exact search can find them again. The old spacing isn't kept.
  def up
    %i[name notes].each { |column|
      squished = "btrim(regexp_replace(#{column}, '[[:space:]]+', ' ', 'g'))"
      execute("UPDATE action_events SET #{column} = #{squished} WHERE #{column} <> #{squished}")
    }
  end

  def down; end
end
