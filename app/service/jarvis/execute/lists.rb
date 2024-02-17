class Jarvis::Execute::Lists < Jarvis::Execute::Executor
  # TODO: Add categories
  # TODO: Add notes

  def add
    list, item = evalargs

    !!list_by(name: list).add(item)
  end

  def edit
    list, old_item_name, new_item_name = evalargs

    !!list_by(name: list).list_items.by_formatted_name(old_item_name).update(name: new_item_name)
  end

  def remove
    list, item = evalargs

    !!list_by(name: list).remove(item)
  end

  def get
    list = evalargs

    list_by(name: list)&.serialize
  end

  private

  def list_by(params)
    # If searching by anything else, need to refactor ilike
    user.lists.ilike(params).take
  end
end
