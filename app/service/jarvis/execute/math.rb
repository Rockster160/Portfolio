class Jarvis::Execute::Math < Jarvis::Execute::Executor
  def cast
    cast_num(eval_block(args))
  end

  def compare
    task_left, task_sign, task_right = evalargs
    return unless task_sign.in?(["==", "!=", "<", "<=", ">", ">="])

    cast_num(task_left).send(task_sign, cast_num(task_right))
  end

  def operation
    task_left, task_op, task_right = evalargs
    return unless task_op.in?(["+", "-", "*", "/", "%"])

    cast_num(task_left).send(task_op, cast_num(task_right).to_f)
  end

  def single_op
    task_op, task_num = evalargs
    task_num = cast_num(task_num)
    case task_op.to_sym
    when :abs    then task_num.abs
    when :sqrt   then ::Math.sqrt(task_num)
    when :square then task_num**2
    when :cubed  then task_num**3
    when :log10  then ::Math.log(task_num, 10)
    when :"e^"   then ::Math::E ** task_num
    end
  end

  def advanced_ops
    task_left, task_op, task_right = args
    task_left, task_right = [task_left, task_right].map { |t| cast_num(eval_block(t)) }
    case task_op.to_sym
    when :"logic.pow"    then task_left ** task_right
    when :"logic.n_root" then task_left ** (1/task_right.to_f)
    when :"logic.log"    then ::Math.log(task_left, task_right)
    end
  end

  def advanced_value
    task_val = args.first
    case task_op.to_sym
    when :"pi"  then ::Math::PI
    when :"e"   then ::Math::E
    when :"inf" then ::Float::INFINITY
    end
  end

  def check
    task_num, task_check = args
    task_num = cast_num(task_num)
    case task_check.to_sym
    when :even      then task_num % 2 == 0
    when :odd       then task_num % 2 != 0
    when :prime     then prime_num?(task_num)
    when :whole     then task_num.to_i == task_num
    when :positive  then task_num > 0
    when :negative  then task_num < 0
    end
  end

  def random
    min, max, dec = args.map { |t| cast_num(eval_block(t)) }
    ((rand * (max - min)) + min).round(dec)
  end

  def round
    num, dec = args.map { |t| cast_num(eval_block(t)) }
    num.round(dec)
  end

  def floor
    num = cast_num(eval_block(args))
    num.floor
  end

  def ceil
    num = cast_num(eval_block(args))
    num.ceil
  end

  private

  def prime_num?(num)
    return false if num.to_i != num
    return true if num == 2
    return false if num <= 1 || num.even?
    i = 3
    top = ::Math.sqrt(num).floor
    loop do
      return false if (num % i).zero?
      i += 2
      break if i > top
    end
    true
  end

  def cast_num(val)
    ::Jarvis::Execute::Raw.num(val)
  end
end
