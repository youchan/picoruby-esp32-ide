# picoruby-esp32-ide が自動生成する部分(mrbgems/以下のgemを追加する)
conf.gem gemdir: "/projects/hello_world_project/mrbgems/picoruby_hello_world"

# ここから下は build_config.rb の内容
# このプロジェクト固有のビルド設定。
#
# mrbgems/以下にあるgemは、何も書かなくても自動的にビルドへ含まれる
# (ビルド時にIDEがprojects/hello_world_project/mrbgems/*を検出して
# conf.gem gemdir: の行を自動的に追加する)。
#
# デフォルトで入っているgemを外したい場合はここに書く。例:
#   conf.gems.reject! { |g| g.name == "picoruby-vim" }

