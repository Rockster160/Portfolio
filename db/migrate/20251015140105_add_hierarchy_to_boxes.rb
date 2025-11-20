class AddHierarchyToBoxes < ActiveRecord::Migration[7.1]
  def up
    add_column :boxes, :hierarchy, :text

    reversible do |dir|
      dir.up do
        execute <<-SQL
          CREATE OR REPLACE FUNCTION update_hierarchy()
          RETURNS TRIGGER AS $$
          BEGIN
            NEW.hierarchy = (SELECT string_agg(value->>'name', ' > ') FROM jsonb_array_elements(NEW.hierarchy_data) value);
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER trigger_update_hierarchy
          BEFORE INSERT OR UPDATE ON boxes
          FOR EACH ROW EXECUTE FUNCTION update_hierarchy();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trigger_update_hierarchy ON boxes;"
        execute "DROP FUNCTION IF EXISTS update_hierarchy();"
      end
    end
  end
end

# ActiveRecord::Migration[7.1].remove_column :boxes, :hierarchy, :text
# ActiveRecord::Migration[7.1].execute "DROP TRIGGER IF EXISTS trigger_update_hierarchy ON boxes;"
# ActiveRecord::Migration[7.1].execute "DROP FUNCTION IF EXISTS update_hierarchy();"


# ActiveRecord::Base.connection.exec_update <<~SQL
#   UPDATE boxes
#   SET hierarchy = (
#     SELECT string_agg(value->>'name', ' > ')
#     FROM jsonb_array_elements(boxes.hierarchy_data) value
#   )
# SQL
