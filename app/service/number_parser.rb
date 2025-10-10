module NumberParser
  module_function

  def parse(str)
    str.gsub(/(\ba )?\b(#{reg_or(all_nums)})([ -]?(#{reg_or(all_nums, :and, :a)}))*\b/) { |found|
      # Clean up
      found.gsub!(/\ba (#{reg_or(big_nums)})/, 'one \1') # Replace "a" with "one"
      found.gsub!(/(#{reg_or(big_nums)}) and (#{reg_or(small_nums)})/, '\1 \2') # Remove "and" between big->small
      found.gsub!(/(#{reg_or(all_nums)}) ?- ?(#{reg_or(all_nums)})/, '\1 \2') # Remove "-" between any
      # Split different chunks of numbers
      found.gsub!(/(#{reg_or(ones, teens)}) (#{reg_or(small_nums)})/, '\1 | \2')
      found.gsub!(/(#{reg_or(tens)}) (#{reg_or(teens, tens)})/, '\1 | \2')
      found.gsub!(/(#{reg_or(tens)}) (hundred)/, '\1 | \2')
      found.gsub!(/(#{reg_or(all_nums)}) (\1)/, '\1 | \2')
      found.gsub!(/(#{reg_or(all_nums)}) and (#{reg_or(all_nums)})/, '\1 | and | \2')
      found.gsub!(/(#{reg_or(all_nums)}) and\b/, '\1 | and')
      found.gsub!(/\band (#{reg_or(all_nums)})/, 'and | \1')
      big_nums.keys.each_with_index do |num_name, idx|
        next if num_name == :hundred # Nothing under hundred to check

        # Replace any big nums followed by a smaller (million thousand is bad, but thousand million is fine)
        found.gsub!(/(#{num_name}) (#{reg_or(big_nums.keys[(idx + 1)..])})/, '\1 | \2')
      end

      # Split the separate words and parse each one
      found.split(" | ").map { |num|
        if num.match?(/(#{reg_or(all_nums)})/)
          parseNum(num)
        else
          num
        end
      }.join(" ")
    }
  end

  def big_nums
    # eighteen hundred, but not ninety hundred
    {
      trillion: 1_000_000_000_000,
      billion:  1_000_000_000,
      million:  1_000_000,
      thousand: 1000,
      hundred:  100,
    }
  end

  def small_nums
    {
      **tens,
      **teens,
      **ones,
    }
  end

  def tens
    {
      ninety:  90,
      eighty:  80,
      seventy: 70,
      sixty:   60,
      fifty:   50,
      forty:   40,
      thirty:  30,
      twenty:  20,
    }
  end

  def teens
    {
      nineteen:  19,
      eighteen:  18,
      seventeen: 17,
      sixteen:   16,
      fifteen:   15,
      fourteen:  14,
      thirteen:  13,
      twelve:    12,
      eleven:    11,
      ten:       10,
    }
  end

  def ones
    {
      nine:  9,
      eight: 8,
      seven: 7,
      six:   6,
      five:  5,
      four:  4,
      three: 3,
      two:   2,
      one:   1,
      zero:  0,
    }
  end

  def all_nums
    {
      **big_nums,
      **tens,
      **teens,
      **ones,
    }
  end

  def reg_or(*num_data)
    num_data.flatten.map { |d| d.is_a?(Hash) ? d.keys : d }.flatten.join("|")
  end

  def parseNum(words)
    mem = 0
    ans = 0
    words.split(/ +/).each { |word|
      num = all_nums[word.to_sym]
      next if num.nil?
      # Mem just stores the previous number in case we need to do multiply logic to it without
      #   affecting the rest of the `ans`.
      # If we hit a zero, it means the mem doesn't need to do anything and we have nothing to add.
      # In this case, just reset mem and move on.
      next mem = num if mem.zero?

      # If the num is a large num/power of 10 (million, thousand, etc...) then we multiply with num
      # "two hundred"
      # mem = 2
      # num = 100
      # 2 * 100 = 200
      if num > 100 && big_nums.value?(num)
        # Add the multiplied value to our final num, then reset our mem
        ans += (mem * num)
        next mem = 0
      end

      # If num is 100, multiple num like the big nums above, but don't reset mem
      # Otherwise add (40 + 6)
      num == 100 ? mem *= num : mem += num
    }
    ans + mem
  end
end
