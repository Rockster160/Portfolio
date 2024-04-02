class Calculator
  @@fib ||= {}

  def self.fibonacci(n)
    return n if n <= 1
    return @@fib[n] if @@fib[n]

    @@fib[n] = fibonacci(n - 1) + fibonacci(n - 2)
  end
end
