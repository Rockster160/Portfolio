class Jil::Methods::List < Jil::Methods::Base
  def cast(value)
    case value
    when ::List then { id: value.id }
    else @jil.cast(value, :Hash)
    end
  end

  def find(list_name)
    List.by_name_for_user(list_name, @jil.user)
  end

  def name(list)
    load_list(list).name
  end

  def add(list, item_name)
    load_list(list).add(item_name)
  end

  def remove(list, item_name)
    load_list(list).remove(item_name)
  end

  def items(list)
    list_data(list)[:list_items]
  end

  def has_item?(list, item_name)
    item = load_list(list).list_items.by_data(name: item_name)
    return false if item.nil?

    !item.deleted?
  end

  private

  def list_data(jil_list)
    load_list(jil_list).jil_serialize
  end

  def load_list(jil_list)
    @jil.user.lists.find(cast(jil_list)[:id])
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
