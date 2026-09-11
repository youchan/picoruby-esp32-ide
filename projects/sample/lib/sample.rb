# サンプル: フィボナッチ数列を計算するクラス
class Fibonacci
  def initialize(limit)
    @limit = limit
  end

  def sequence # project選択機能の確認
    (0...@limit).map { |n| calculate(n) }
  end

  private

  def calculate(n)
    return n if n <= 1

    a, b = 0, 1
    (n - 1).times do
      a, b = b, a + b
    end
    b
  end
end

if __FILE__ == $PROGRAM_NAME
  fib = Fibonacci.new(10)
  puts fib.sequence.join(", ")
end
