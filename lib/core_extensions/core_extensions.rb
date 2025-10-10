module CoreExtensions
  refine Hash do
    def deep_set(path, new_value)
      return self unless path.any?

      new_hash = new_value
      path.reverse.each do |path_key|
        new_hash = { path_key => new_hash }
      end
      deep_merge!(new_hash) { |_key, this_val, other_val| this_val + other_val }
      self
    end

    def clean!
      delete_if { |_k, v|
        if v.is_a?(Hash)
          v.clean!.blank?
        else
          v.blank?
        end
      }
    end

    def all_paths
      found_paths = []

      each do |hash_key, hash_values|
        path = [hash_key]

        if hash_values.is_a?(Hash)
          hash_values.all_paths.each do |new_path|
            found_paths << (path + new_path)
          end
        elsif hash_values.is_a?(Array)
          hash_values.each do |new_path|
            if new_path.is_a?(Hash)
              new_path.all_paths.each do |new_array_path|
                found_paths << (path + new_array_path)
              end
            else
              found_paths << (path + [new_path])
            end
          end
        else
          found_paths << (path + [hash_values])
        end
      end

      found_paths
    end
  end
end
