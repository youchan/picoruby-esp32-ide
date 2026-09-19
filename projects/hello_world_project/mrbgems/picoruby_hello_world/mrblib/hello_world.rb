# Rubyで定義するHelloWorldクラス。C側(src/)の初期化処理とは別に、
# mrbgemの仕組みで自動的にロードされる(gem_init側で明示的にひもづける必要はない)。
class HelloWorld
  def initialize(name = 'World')
    @name = name
  end

  # 挨拶文の組み立て自体はc_greet(src/mruby/hello_world.c・src/mrubyc/hello_world.c
  # で定義されているネイティブメソッド)に委譲している。
  def greet
    c_greet(@name)
  end
end
