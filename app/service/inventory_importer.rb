class InventoryImporter
  attr_reader :user, :format, :parent_key

  def initialize(user, format: "csv", parent_key: nil)
    @user = user
    @format = format
    @parent_key = parent_key
  end

  def import(file_or_data)
    return { success: false, error: "No data provided" } if file_or_data.blank?

    data = if file_or_data.respond_to?(:read)
      file_or_data.read
    else
      file_or_data
    end

    case format.to_s.downcase
    when "json"
      import_json(data)
    else
      import_csv(data)
    end
  rescue StandardError => e
    { success: false, error: e.message }
  end

  private

  def import_csv(data)
    require "csv"

    boxes = []
    key_mapping = {} # old_param_key -> new_param_key

    ActiveRecord::Base.transaction do
      csv = CSV.parse(data, headers: true)

      csv.each do |row|
        old_key = row["param_key"]
        name = row["name"]
        next if name.blank?

        # Determine parent - could be from CSV or from import params
        old_parent_key = row["parent_key"]
        new_parent_key = if old_parent_key.present?
          key_mapping[old_parent_key] || user.boxes.find_by(param_key: old_parent_key)&.param_key
        else
          parent_key # Use the import's parent_key if no parent specified
        end

        box = user.boxes.create!(
          name: name,
          notes: row["notes"],
          description: row["description"],
          parent_key: new_parent_key,
          do_not_broadcast: true
        )

        key_mapping[old_key] = box.param_key if old_key.present?
        boxes << box
      end

      # Broadcast all at once after import
      boxes.each(&:broadcast!)
    end

    { success: true, count: boxes.size, boxes: boxes }
  end

  def import_json(data)
    parsed = JSON.parse(data)
    items = parsed.is_a?(Array) ? parsed : [parsed]

    boxes = []
    key_mapping = {}

    ActiveRecord::Base.transaction do
      import_nested = ->(items_array, parent_param_key) {
        items_array.each do |item|
          old_key = item["param_key"]
          name = item["name"]
          next if name.blank?

          box = user.boxes.create!(
            name: name,
            notes: item["notes"],
            description: item["description"],
            parent_key: parent_param_key,
            do_not_broadcast: true
          )

          key_mapping[old_key] = box.param_key if old_key.present?
          boxes << box

          # Recursively import children
          if item["children"].present?
            import_nested.call(item["children"], box.param_key)
          end
        end
      }

      import_nested.call(items, parent_key)

      # Broadcast all at once after import
      boxes.each(&:broadcast!)
    end

    { success: true, count: boxes.size, boxes: boxes }
  end
end
