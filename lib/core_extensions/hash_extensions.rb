module CoreExtensions
  refine Hash do

    def clean!
      delete_if do |k, v|
        if v.is_a?(Hash)
          v.clean!.blank?
        else
          v.blank?
        end
      end
    end

    def all_paths
      found_paths = []

      self.each do |hash_key, hash_values|
        path = [hash_key]

        if hash_values.is_a?(Hash)
          hash_values.all_paths.each do |new_path|
            found_paths << path + new_path
          end
        elsif hash_values.is_a?(Array)
          hash_values.each do |new_path|
            if new_path.is_a?(Hash)
              new_path.all_paths.each do |new_array_path|
                found_paths << path + new_array_path
              end
            else
              found_paths << path + [new_path]
            end
          end
        else
          found_paths << path + [hash_values]
        end
      end

      found_paths
    end

  end
end
