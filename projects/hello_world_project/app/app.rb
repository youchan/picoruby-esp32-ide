# サンプルアプリ: mrbgems/picoruby_hello_world が定義するHelloWorldクラスを呼び出す。
#
# このプロジェクトのapp/以下は、ビルド時にR2P2-ESP32のストレージイメージ
# (storage/home/)へまるごとコピーされ、実機の起動スクリプト
# (components/picoruby-esp32/mrblib/main_task.rb)が起動のたびに /home/app.rb を
# 自動的にloadするR2P2本来の仕組みに乗る形になる(R2P2-ESP32側の改造は不要)。
#
# mrbgems/picoruby_hello_world は同じプロジェクトの中にあるので、
# 何もしなくてもビルドに自動的に含まれる。gem自体のC言語側の"Hello world!"表示は
# ビルド時の初期化処理(mrb_picoruby_hello_world_gem_init / mrbc_hello_world_init)で
# 自動的に行われる。ここではRuby側のHelloWorldクラスを呼び出す部分だけを書く。
require 'hello_world'

puts HelloWorld.new.greet
