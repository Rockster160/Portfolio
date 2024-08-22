class Jil::Methods::List < Jil::Methods::Base
  def cast(value)
    case value
    when ::List then serialize(value)
    else @jil.cast(value, :Hash)
    end
  end

  def find(list_name)
    List.by_name_for_user(list_name, @jil.user)
  end

  def name(list)
    cast(list)[:name]
  end

  def add(list, item_name)
    @jil.user.lists.find(cast(list)[:id]).add(item_name)
  end

  def remove(list, item_name)
    @jil.user.lists.find(cast(list)[:id]).remove(item_name)
  end

  def items(list)
    cast(list)[:list_items]
  end

  def has_item?(list, item_name)
    item = @jil.user.lists.find(cast(list)[:id]).list_items.by_data(name: item_name)
    return false if item.nil?

    !item.deleted?
  end

  private

  def serialize(list)
    list.as_json(
      only: [
        :id,
        :name,
        :description,
        :important,
        :parameterized_name,
        :show_deleted,
      ],
      include: {
        list_items: {
          only: [
            :id,
            :name,
            :category,
            :important,
            :permanent,
            :sort_order,
            :deleted_at,
          ],
        }
      }
    ).with_indifferent_access
  end
end

# [List]
#   #find(String)
#   #search(String)::Array
#   #create(String)
#   .name::String
#   .update(String?:"Name")::Boolean
#   .destroy::Boolean
#   .add(String)::Boolean
#   .remove(String)::Boolean
#   .items::Array
#   .has_item?(String)::Boolean
