class Jil::Methods::List < Jil::Methods::Base
  def cast(value)
    case value
    when ::List then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::List.new, @jil.cast(value, :Hash))
    end
  end

  def find(list_name)
    List.by_name_for_user(list_name, @jil.user)
    # TODO: Rescue/handle no list found
  end

  def list_add(list_name, item_name)
    List.by_name_for_user(list_name, @jil.user).tap { |list| list.add(item_name) }
    # TODO: Rescue/handle no list found
  end

  def list_remove(list_name, item_name)
    List.by_name_for_user(list_name, @jil.user).tap { |list| list.remove(item_name) }
    # TODO: Rescue/handle no list found
  end

  def list_toggle(list_name, item_name)
    List.by_name_for_user(list_name, @jil.user).tap { |list| list.toggle(item_name) }
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

  def toggle(list, item_name)
    load_list(list).toggle(item_name)
  end

  def items(list)
    list_data(list)[:items]
  end

  def has_item?(list, item_name)
    item = load_list(list).list_items.by_formatted_name(item_name) # Will not find deleted items
    return false if item.nil?

    !item.deleted?
  end

  private

  def list_data(jil_list)
    load_list(jil_list).serialize
  end

  def load_list(jil_list)
    return jil_list if jil_list.is_a?(::List)

    @jil.user.lists.find(cast(jil_list)[:id])
  end
end

# [List]
#   #find(String)
#   #list_add(String:List String:Item)
#   #list_remove(String:List String:Item)
#   #list_toggle(String:List String:Item)
#   #search(String)::Array
#   #create(String)
#   .name::String
#   .update(String?:"Name")::Boolean
#   .destroy::Boolean
#   .add(String)::Boolean
#   .remove(String)::Boolean
#   .toggle(String)::Boolean
#   .items::Array
#   .has_item?(String)::Boolean
