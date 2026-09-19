# プロジェクトの引き継ぎコンテキスト

このファイルはClaude Codeがこのリポジトリで作業する際に自動的に読み込む前提のメモです。
プロジェクトルート(`app.rb`と同じ階層)に置いてください。

## プロジェクト概要

Rubyプロジェクトの中で、Ruby(`.rb`)とC(`.c` `.h`)のソースコードをブラウザ上で
編集できるようにする最小構成のサンプルアプリ。

- サーバー: Sinatra (Ruby)。Railsは不要という前提で選定
- フロントエンド: ビルドステップなしのvanilla JS + Prism.js(CDN読み込み)
- 目的はあくまで「サンプル/たたき台」。本番投入前提の機能(認証、複数人編集の競合制御など)は未実装

## 技術選定の経緯(重要)

エディタ部分は当初 CodeMirror 6 → 最終的に「textarea + Prism.jsオーバーレイ」方式に
変更している。この経緯を知らずに再度CodeMirrorへ戻そうとすると同じ問題を踏むので記録しておく。

1. **CodeMirror 6 (esm.sh CDN経由のESM import)**
   `https://esm.sh/codemirror@6` 等から直接importする構成で開始したが、
   `Uncaught SyntaxError: The requested module 'https://esm.sh/codemirror@6' does not
   provide an export named 'basicSetup'` というエラーが発生。esm.sh側での
   パッケージ間バージョン解決のズレが原因。CDN上のESMは複数パッケージ構成のライブラリと
   相性が悪い場合がある、という教訓。

2. **CodeMirror 6 (npm + esbuildでローカルバンドル)**
   1の問題を受けてnpm管理+esbuildバンドルに変更し、正常動作を確認。
   ただしRubyプロジェクトにNode.js/npmのビルド環境を持ち込むことになり、
   「Railsも要らないくらいシンプルにしたい」という当初の方針とはやや矛盾していた。

3. **picoruby.org/terminal の実装調査**
   ユーザーからの質問で https://picoruby.org/terminal (PicoRuby公式のWebターミナル)の
   エディタ実装を調査。ソースは
   https://github.com/picoruby/picoruby.github.io/blob/main/pages/r2p2/terminal.html
   にあり、CodeMirrorやMonacoではなく **`<textarea>` + 行番号レイヤー + ハイライトレイヤーの
   透明重ね合わせ + Prism.js(字句解析) + PicoRuby.wasm(ロジックをRubyで記述)** という
   自作の軽量構成だと判明。ターミナル部分は `@xterm/xterm` (xterm.js) を使用。

4. **現在の実装: textarea + Prism.jsオーバーレイ方式**
   3を参考に、CodeMirrorとnpm/esbuildを完全に廃止し、Prism.js(cdnjs、バージョン固定の
   `<script>`タグ読み込み)による軽量構成に置き換えた。これにより:
   - npm/Node.js環境が不要になり、`bundle install && ruby app.rb` だけで動くように
   - 引き換えに、補完・複数カーソル・折りたたみ等の高度な編集機能は失った
   - シンタックスハイライトのみのシンプルなエディタという位置づけ

5. **キャレット/ハイライトのズレ修正**
   textarea+オーバーレイ方式に切り替えた直後、「表示文字列とキャレット行がズレる」不具合が
   発生。原因は `<textarea>` が内容あふれ時に**要素内部で独自にスクロールする**性質を持つため、
   `position: absolute` で単純に重ねると親のスクロールとtextarea自身のスクロールが
   ズレること。**CSS Grid (`display: grid` + 両要素に `grid-area: 1 / 1`)** で
   重ねる方式に変更し、スクロール可能な要素を親の `.editor-scroll-area` ひとつに
   集約することで解消した。この手法は react-simple-code-editor や CodeJar など
   同種のライブラリでも採用されている標準的な解決策。

## 現在のアーキテクチャ

```
.
├── app.rb                # Sinatraアプリ本体。ファイル一覧/読込/保存のJSON APIのみ
├── Gemfile                # sinatra, puma, rackup
├── views/index.erb        # エディタ画面のHTML。Prism.jsをcdnjs(バージョン固定)から読込
├── public/
│   ├── css/style.css      # textareaオーバーレイ(CSS Grid)・行番号・Prismトークン配色
│   └── js/editor.js       # エディタ本体ロジック。ビルド不要のvanilla JS(IIFE)
└── project/                # 編集対象のサンプルファイル群(.rb / .c / .h)
```

### API (`app.rb`)

- `GET /api/files` — `project/` 以下の `.rb` `.c` `.h` ファイル一覧(相対パス)を返す
- `GET /api/file?path=...` — 指定ファイルの内容を返す
- `POST /api/file` — `{path, content}` を受け取り、既存ファイルを上書き保存する
  (新規作成は不可。`ALLOWED_EXTENSIONS` にないファイルや `project/` 外は拒否)
- `safe_path` ヘルパーでパストラバーサル対策済み
- `GET /api/build` / `POST /api/build` — R2P2-ESP32 のビルド(`idf.py build`)
  - `POST`のbodyで `vm`(`"femtoruby"`|`"picoruby"`、`BUILD_VM_FLAGS`で
    `-DPICORB_VM=mrubyc`|`mruby`に変換)と `usb_console`(true/false)を選べる。
    公式の[R2P2-ESP32-installer](https://github.com/picoruby/R2P2-ESP32-installer)は
    CIで全組み合わせ(VM×usb_console×チップ)を事前ビルドしてGitHub Releaseで配布し、
    ブラウザ側でファイル名をパースして選ばせる方式だが、こちらは「今コンテナ内で
    1本だけビルドする」設計なので、オプションはビルド開始時にリクエストで渡す形にした
  - `usb_console` は `R2P2-ESP32/sdkconfigs/usb_console`
    (`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y`。外部USB-UART変換チップを持たない
    ボード向け)を `SDKCONFIG_DEFAULTS` にマージする。ESP-IDFは
    `SDKCONFIG_DEFAULTS` を **`sdkconfig` ファイルが存在しないときしか読まない**ため、
    設定を反映させるには `sdkconfig` を消してからビルドし直す必要がある
    (`rake deep_clean`/`idf.py fullclean` でも `sdkconfig` 自体は消えない。
    README.md「If you change SDKCONFIG_DEFAULTS, delete the sdkconfig file and
    rebuild from scratch」参照)
  - **踏んだ罠**: 最初「`usb_console: true`のときだけ`sdkconfig`を消す」という
    実装にしたら、一度trueにした後falseに戻しても`sdkconfig`にUSB Console設定が
    残ったままになるバグを作ってしまった(実機で試すまで気づかなかった類の話ではなく、
    このセッション内でAPIを叩いて`grep CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG sdkconfig`
    で確認して発覚した)。正しくは `sdkconfig_has_usb_console?` ヘルパーで
    **今の`sdkconfig`の実際の中身**を見て、リクエストされた値と食い違うときだけ
    `rm -f sdkconfig && SDKCONFIG_DEFAULTS=... idf.py build` する。一致していれば
    従来通りの高速な差分ビルドのまま(オプション未指定の通常ビルドが遅くならない)
  - VM(`-DPICORB_VM=`)の切り替えは`sdkconfig`と無関係(CMakeのキャッシュ変数)なので
    上記のクリーン処理は不要。ビルドログの早い段階に出る
    `-- PICORB_VM is set to: mrubyc` のような行は、キャッシュがまだ更新される前の
    表示に見えることがあるので、本当に反映されたかは
    `build/CMakeCache.txt` の `PICORB_VM:STRING=...` や、
    `components/picoruby-esp32/picoruby/build/` 配下に
    `esp32-{femtoruby,picoruby}` のディレクトリが増えているかで確認するのが確実
- `GET /api/platform` / `POST /api/platform` — プラットフォーム(ターゲットチップ)
  セットアップ(`rake setup_#{platform}`)。`platform` は
  `PLATFORM_TARGETS`(`esp32` `esp32c3` `esp32c6` `esp32h2` `esp32p4` `esp32s3`。
  `R2P2-ESP32/rakelib/setup.rake` 参照)にあるものだけ許可
  (コマンドインジェクション対策とrakeタスク名の妥当性確認を兼ねる)
  - `setup_esp32xxx` は `deep_clean` + `setup`(mrubyの再ビルド) +
    `idf.py set-target` という重い処理の直列実行なので、実行に数分かかる

この2つはどちらも同じ形の非同期ジョブ(GETでポーリング、POSTで開始、実行中の
POSTは409)なので、共通処理を `BackgroundJob` クラス(`app.rb`)に抽出してある。
`BUILD_JOB` / `PLATFORM_JOB` という2つのインスタンスがそれぞれの状態
(`idle`/`running`/`success`/`failed`、ログ)を持つ。ログは末尾
`BackgroundJob::LOG_TAIL_LIMIT`(8,000文字)のみをレスポンスに含め、
切り詰めた場合は `log_truncated: true` を付ける
(ブラウザ内のPicoRuby.wasmで全量(100KB超になりうる)をJSONパース/描画すると
数秒〜十秒近くかかり、「反応がない」ように見えてしまう問題への対処)。
`idf.py` / `rake` はESP-IDFの `export.sh` を読み込んだシェルでないと使えないため、
両ジョブとも実行コマンドは `r2p2_shell_command` ヘルパーで
`$IDF_PATH/export.sh` を明示的にsourceしてから組み立てている
(Dockerのentrypoint(`R2P2-ESP32/docker/Dockerfile`)は起動時に一度export済みだが、
`docker exec` 等で入った場合はexportされていないことがあり、それに頼らない実装にした)。

UI側(`app/funicular/ruby/components/editor_app.rb`)は実行中、
`JS.global.setTimeout(3000) { refresh_xxx_status }` で3秒おきに自動的にログを
取りに行く(runningでなくなったら止まる)。「ログを更新」ボタンはこれとは別に、
すぐ最新状態を見たいときの手動トリガーとして残してある。
ビルドパネル(`build_panel.rb`)とプラットフォームパネル(`platform_panel.rb`)は
表示ロジックがほぼ同じ(ステータスラベル・ログ切り詰め表示・自動ポーリング)だが、
まだ2つ書いているだけの重複度なので共通化はしていない。3つ目の非同期ジョブUIが
必要になったら抽象化を検討する。

**ここで踏んだ罠**: PicoRuby.wasmの `JS::Object#setTimeout` は Ruby標準の
`Kernel#sleep` 的な感覚で `JS.global.setTimeout(callback_proc, delay_ms)` のように
2引数で呼びたくなるが、実際のシグネチャは `setTimeout(delay_ms, &block)`
(picoruby本体 `mrbgems/picoruby-wasm/mrblib/js.rb` 参照)で、コールバックは
**ブロックとして**渡す必要がある。2引数で呼ぶと
`ArgumentError: wrong number of arguments (given 2, expected 1)` になり、
しかもこの例外はブラウザの `console.error` に `Callback <id>: ArgumentError: ...`
という形で出るだけで、Rubyコード上は握りつぶされて画面には何も出ない
(=「ボタンを押しても何も起きない」ように見える)。正しくは
`JS.global.setTimeout(3000) { ... }` のようにブロックで渡す。
同様のAPIを追加するときは `js.rb` のソース(`gh api
repos/picoruby/picoruby/contents/mrbgems/picoruby-wasm/mrblib/js.rb`)を
先に確認したほうが早い。

### エディタ (`public/js/editor.js` + `views/index.erb` + `style.css`)

- `<textarea id="editor">`: 文字色を透明にしキャレットのみ見せる
- `<pre id="highlight-layer"><code id="highlight-content"></code></pre>`: Prism.jsで
  ハイライトしたHTMLをここに描画。`.editor-scroll-area` 内で `#editor` と
  `grid-area: 1 / 1` により完全に重なる
- `#line-numbers`: 別カラム。`.editor-scroll-area` の `scroll` イベントで
  `scrollTop` を同期
- 拡張子→Prism言語のマッピングは `languageFor()` にハードコード(`rb`→ruby, `c`/`h`→c)
- Tabキーはスペース2つを挿入するだけ(自動インデント等は未実装)
- 保存のたびに `savedContent` と比較して未保存差分の有無を判定し、保存ボタンの
  活性/非活性を制御

## 既知の制約・today's TODO候補

READMEにも記載しているが、Claude Codeで次に着手する際の候補:

- **自動インデント未実装**: 改行時に直前行のインデント幅を引き継ぐ処理がない
  (picoruby側の `auto_indent.rb` が参考になる)
- **大きいファイルでの性能**: 入力のたびに全文を `Prism.highlight()` で再トークナイズしている。
  デバウンス処理を入れるか、変更行のみ再描画する差分更新に変えると改善する
- **新規ファイル作成/削除/リネームAPIがない**: 既存ファイルの上書き保存のみ対応
- **同時編集の競合制御がない**: 複数人が同時に同じファイルを開いた場合、後勝ちで上書きされる
- **対応拡張子が `.rb` `.c` `.h` のみ**: 増やす場合は `app.rb` の `ALLOWED_EXTENSIONS`、
  `views/index.erb` のPrismコンポーネント読み込み、`editor.js` の `languageFor` /
  `iconFor` の3箇所を対応させる必要がある
### 実機への書き込み(インストール)機能

ビルド(`idf.py build`)・プラットフォームセットアップ(`rake setup_xxx`)とは違い、
書き込みだけは**サーバ側で`rake flash`を実行する方式にしなかった**。理由は、
サーバがDockerコンテナ内で動く前提だと、コンテナにUSBシリアルデバイスを渡す
(`docker run --device /dev/ttyUSB0` 等)必要があり、`bin/dev`の変更やホスト環境の
デバイスパス依存が増えて複雑になるため。代わりに公式の
[R2P2-ESP32-installer](https://picoruby.org/R2P2-ESP32-installer/)と同じ、
**ブラウザのWeb Serial API経由([ESP Web Tools](https://esphome.github.io/esp-web-tools/)、
`esp-web-install-button`カスタム要素)でブラウザから直接USBに書き込む方式**を採用した。
これによりサーバは「ビルド成果物を配信するだけ」でよくなり、USBデバイスの取り回しを
気にする必要がなくなる(ただしChrome/Edge/OperaなどWeb Serial API対応ブラウザが必須)。

- `GET /api/firmware/manifest.json` — ESP Web Tools用のマニフェストを、直近のビルド
  成果物(`R2P2-ESP32/build/project_description.json` の `target` と
  `R2P2-ESP32/build/flash_args`)から動的に組み立てて返す。ビルド未実行なら404
  - `flash_args` は `idf.py build` が生成する、esptoolの`write_flash`にそのまま渡せる
    `<オフセット(16進)> <binへの相対パス>` の行の並び(1行目は`--flash_mode`等の
    オプション行なので読み飛ばす)。実際の中身の例:
    ```
    --flash_mode dio --flash_freq 40m --flash_size 4MB
    0x1000 bootloader/bootloader.bin
    0x10000 R2P2-ESP32.bin
    0x8000 partition_table/partition-table.bin
    0x210000 storage.bin
    ```
  - `target`(`esp32`等、`idf.py set-target`の引数と同じ)→ESP Web Toolsの`chipFamily`
    (`ESP32`等)への変換テーブルが `CHIP_FAMILY_MAP`。ESP Web Tools側の対応チップ一覧は
    `gh api repos/esphome/esp-web-tools/contents/src/const.ts` の `Build#chipFamily`
    で確認した(`PLATFORM_TARGETS` にある6種は全部サポートされている)
- `GET /api/firmware/:filename` — 上記マニフェストが指す`.bin`を配信する
  (拡張子とパストラバーサル対策あり)
- UI側(`install_panel.rb`)は状態を持たない。`<esp-web-install-button manifest="...">`
  を配置するだけで、実際の書き込み処理・進捗ダイアログはESP Web Tools側が全部担う。
  ボタンのコールバックは `manifest` を**HTML属性**として読む
  (`button.manifest || button.getAttribute("manifest")`、
  `esp-web-tools/src/connect.ts` 参照)ので、Funicularの`tag`で属性として渡せばよい
  - `index.html` で `<script type="module" src=".../esp-web-tools@10.4.0/dist/web/
    install-button.js">` をCDN読み込み。バージョン固定の方針は他ライブラリと同様
  - 実機なしでも「No port selected」ダイアログ(ESP Web Tools自身が出す、Linuxの
    dialoutグループ設定などのトラブルシューティング付き)が出ることをブラウザで確認済み

## 開発環境まわりの注意点

- Rubyの実行環境がこちらのサンドボックスに無かったため、`app.rb` 等は目視レビューのみで
  実機での起動確認はできていない(ユーザー側の `ruby app.rb` で都度確認してもらっている)
- Prism.jsのCDN URL (`cdnjs.cloudflare.com`) はサンドボックスのネットワーク制限で
  直接疎通確認できなかったため、`npm pack prismjs@1.30.0` でnpmレジストリ経由で
  ファイル名(`prism-core.min.js` 等)の実在のみ検証した
- esm.sh経由のESM CDN importは、今回のようなバージョン解決の不安定さが起きやすいので、
  今後もCDN経由でJSライブラリを追加する場合は、安定版の `<script>` タグ+バージョン固定URLを
  優先する方針でよい

### Dockerでの開発時マウント(`bin/dev`)

開発中に `app/` をbind mountしてホスト側の編集を即座に反映したい、という要望があった。
`app/` のコピー先を `/root` → `/root/app` に変更して `-v $(pwd)/app:/root/app` の
1行で済ませる案も試したが、`app.rb` の `PROJECTS_ROOT` / `R2P2_ESP32_ROOT` が
`File.expand_path("../projects", __dir__)` のように `__dir__`(=app.rbの場所)からの
相対パスで解決しているため、`app/` を1階層深くすると `../projects` の解決先が
`/projects` から `/root/projects` にズレて `Errno::ENOENT` になる問題が出た
(`R2P2_ESP32_ROOT` も同様)。Dockerfile側でsymlinkを張って辻褄を合わせる案も
検討したが、Dockerfileに手を入れるほどのことではないと判断し、**Dockerfileは
`COPY app/ .`(WORKDIR `/root`)のまま変更せず**、代わりに開発用の起動コマンドを
`bin/dev` というシェルスクリプトに切り出した。

```bash
./bin/dev
```

中身は `app/` 配下のサブディレクトリを個別に(Dockerfileの配置に合わせて)
`/root` 直下へマウントするだけの `docker run` ラッパー。Rakefileにして
`rake dev` のようなタスクにする案もあったが、Webアプリの起動ラッパー程度で
rake依存を持ち込む必要はない(R2P2-ESP32側の `Rakefile`/`rakelib/docker.rake` は
ESP-IDFのビルドタスク管理のためのもので、役割が異なる)と判断し見送った。

- `views/index.erb` ・ `public/css` ・ `funicular/ruby/*.rb` はリクエストのたびに
  読み直される(ERBレンダリング / `File.read`)ので、マウント元を編集してブラウザを
  リロードするだけで反映される
- `app.rb` 自体(ルーティング等)を変更した場合はSinatra起動時に読み込まれるため、
  コンテナの再起動が必要
- コンテナはroot権限で動くため、UI経由の保存(`POST /api/file`)でホスト側に
  書き込まれるファイルはroot所有になる点に注意
- `R2P2-ESP32/` はデフォルトではマウント対象外(イメージビルド時にセットアップ済みの
  ものをそのまま使う)。ソースも編集したい場合は `bin/dev` に
  `-v "$(pwd)/R2P2-ESP32:/R2P2-ESP32"` を追加する

## プロジェクト管理・mrbgemのビルド組み込み方針

複数のプロジェクト(1つのアプリと、それが使う自作mrbgem群)を`projects/`配下で
どう管理し、どうビルドに組み込むかを検討して決めた内容。**この設計は2回作り直して
いる**ので、経緯も含めて残しておく。

### 現在のプロジェクト構造

1プロジェクト = `projects/<project名>/`の中に`app/`・`mrbgems/`・`build_config.rb`を
まとめて持つディレクトリ、という単位にしてある。

```
projects/
  hello_world_project/
    app/                      # ビルド時にR2P2-ESP32のstorage/home/へまるごとコピーされる
      app.rb                  # main_task.rbが起動時に自動loadする(後述)
    mrbgems/                  # ここにあるものは全部自動でビルドに含まれる
      picoruby_hello_world/
        mrbgem.rake
        mrblib/...
        src/...
    build_config.rb           # デフォルトgemを外したい場合などに直接編集する普通のファイル
```

プロジェクトの選択は画面上部のメニューバーのドロップダウン(`MenuBar`の
`render_project_select`)から行う(以前はサイドバーに一覧を出す`ProjectList`
コンポーネントだったが、上部に移した)。マウントは`projects/`を1つだけbind mountする
方針は変わっていない(mrbgemを継続的に追加してもコンテナ再起動が要らないように)。
IDEはgit操作(clone/pull/push/commit)に一切ノータッチで、プロジェクトディレクトリが
独立したgitリポジトリかどうかもIDEは関知しない。

**ここに至るまでの変遷**: 最初は「`projects/`直下の各ディレクトリを1プロジェクトとし、
`mrbgem.rake`の有無で中身を見てapp/mrbgem種別を自動判定する」フラットな構成にして
いた(mrbgemが「あるappプロジェクトの一部」ではなく独立した存在という前提)。
この場合「どのmrbgemをどのappに含めるか」を選ぶ必要が生じ、Gemsダイアログ
(チェックボックスでmrbgemを選ぶUI)とその永続化(`.gems_prefs.json`、
opt-in→opt-out方式への変更を経た)を作り込んだ。しかし実際にサンプルを作ってみると、
「1つのappとそれが使うmrbgemは元々セットで管理したい」という要望が出てきて、
mrbgemをapp側のディレクトリの中に物理的に含める今の構造に変更した。これにより
「mrbgemを選ぶ」という概念自体が不要になり(ディレクトリの中に置く=そのプロジェクトで
使う、という構造そのものが選択を兼ねる)、Gemsダイアログ・`.gems_prefs.json`は
まるごと削除した。`build_config.rb`も「ダイアログが生成する専用ファイル」から
「プロジェクトの中にある普通の編集可能ファイル」に位置づけが変わっている。

### mrbgemのビルドへの組み込み

mrubyのビルド設定(`MRuby::CrossBuild.new do |conf| ... end`、`conf.gem`)は
`conf.gem gemdir: '<path>'`で任意のローカルディレクトリをgemとして追加でき、
`conf.gems.reject! { |g| ... }`で既に登録済みのデフォルトgemを除外できる
(`conf.gems.delete(name)`もあるが、該当gemが無いと`fail`で例外になるため、
存在しない場合に何もしない`reject!`のほうが今回の用途には安全)。

R2P2-ESP32本体の`components/picoruby-esp32/build_config/*.rb`は
xtensa/riscv × femtoruby/picoruby の組み合わせで4種類あり、ツールチェイン設定など
込み入った内容を持つ。これをプロジェクトごとに複製すると本家の変更に追従できなく
なる。かといって「project内のbuild_config.rbをMRUBY_CONFIGとして丸ごと差し替える」
方式も、`components/picoruby-esp32/CMakeLists.txt`が`MRUBY_CONFIG`のパスを
`${IDF_TARGET_ARCH}-esp-${vm}.rb`固定で毎回計算し直す実装になっていて外から
上書きできないため、そのままでは無理だった。

代わりに採用したのが、**本家4ファイルの`do |conf| ... end`ブロック末尾に1行だけ
フックを差し込む**方式(`Dockerfile`の`git submodule update`直後の`RUN`)。

```ruby
conf.instance_eval(File.read(ENV["PROJECT_BUILD_CONFIG"])) if ENV["PROJECT_BUILD_CONFIG"] && File.exist?(ENV["PROJECT_BUILD_CONFIG"])
```

`PROJECT_BUILD_CONFIG`は`idf.py build`を叩くシェルコマンドの環境変数として
`app.rb`(`POST /api/build`)が設定する(`cmake -E env A=1 B=2 rake`のような
形で最終的に`rake`まで渡っても、その前後で明示的に指定していない環境変数は
プロセスの環境変数として素通りするので、CMakeLists.txt自体は無改造で済む)。

このフックが読むファイルは、プロジェクトの`build_config.rb`そのものではなく、
**ビルド開始のたびに`generated_build_config_content`が生成する一時ファイル**
(`projects/<project>/.build_config.generated.rb`)。中身は
「`mrbgems/`以下の現在の一覧から自動生成した`conf.gem gemdir:`の並び」+
「プロジェクトの`build_config.rb`の内容をそのまま連結したもの」:

```ruby
# 自動生成部分
conf.gem gemdir: "/projects/hello_world_project/mrbgems/picoruby_hello_world"

# ここから下はbuild_config.rbの内容(ユーザーが直接編集する)
conf.gems.reject! { |g| g.name == "picoruby-vim" }
```

ユーザーが書いた`build_config.rb`自体は一切書き換えない(生成物は別ファイルにして
連結するだけ)ので、IDEのファイルエディタで見えている内容と実際にビルドされる内容が
食い違わない。gemdir(自作mrbgemの絶対パス)は常にコンテナ内の絶対パスで書く
(相対パス解決の基点があいまいなmruby側の挙動に依存しないため)。

**踏んだ罠**: 上記のDockerfileパッチで、シングルクォート文字列の中で`&&`を
`\&\&`とバックスラッシュエスケープして書いてしまい、`printf`がバックスラッシュを
剥がさずそのまま出力した結果、生成されたRubyコードに`\&\&`という不正なトークンが
混入してSyntaxErrorになった(実際にビルドを試したユーザーからの報告で発覚)。
シングルクォートの中では`&`はそもそもシェルにとって特別な文字ではない
(`&&`はダブルクォート無し/クォート無しの文脈でコマンド連結として解釈されるだけ)ので、
エスケープ自体が不要だった。シェル文字列に埋め込むコードにshell上の特殊文字が
含まれる場合、「クォートの種類によってエスケープが要るかどうかが変わる」ことを
都度確認する(今回のように`ruby -c`や実際のcloneに対してパッチを当てて検証していれば
リリース前に気付けた)。

### プロジェクトのapp/を実機の起動スクリプトにする

プロジェクトの`app/`以下は、ビルド時にR2P2-ESP32実機の起動スクリプトとして実行
されるようにした。これはR2P2-ESP32側の改造は一切不要で、既にある2つの仕組みを
組み合わせただけ:

1. `main/CMakeLists.txt`の`littlefs_create_partition_image(storage ../storage
   FLASH_IN_PROJECT)`が、`R2P2-ESP32/storage/`以下をそのまま`storage`パーティション
   (littlefs)のイメージ(`storage.bin`)にする。つまり`storage/home/app.rb`を置けば
   実機の`/home/app.rb`になる
2. 起動スクリプト`components/picoruby-esp32/mrblib/main_task.rb`が起動のたびに
   `File.exist?("/home/app.rb")`をチェックして自動で`load`する処理を最初から持っている
   (`/home/app.mrb`があればそちらを優先。picoruby-esp32本体の元々の仕様で、
   ユーザーアプリを実行する正式な入り口はここ)

なので`app.rb`(`POST /api/build`)は、ビルド開始直前に指定projectの`app/`以下を
`R2P2-ESP32/storage/home/`へまるごとコピーするだけ(`STORAGE_HOME_DIR`)。
前回別プロジェクトをビルドしたときの残骸が残らないよう、コピー前に`storage/home/`を
空にする。build_config.rbのとき(CMakeLists.txtがパスを決め打ちしていて上書き
できなかった)とは違い、ここはR2P2-ESP32側が最初から「storage/以下の現在の中身を
そのまま焼く」という素直な作りだったので、Dockerfileパッチのような迂回策は不要だった。

## storageパーティション作成に使うlittlefs-pythonをオフライン化する

`main/CMakeLists.txt`の`littlefs_create_partition_image`(依存する
`joltwallet/esp_littlefs`コンポーネント、`main/idf_component.yml`で
`joltwallet/littlefs: "~=1.20.0"`と指定)は、storageパーティションのイメージを
作る際に**初回ビルド時にvenvを作ってPyPIから`littlefs-python`をpip installする**。
これが実際のビルド実行時にネットワークの不調でタイムアウトして失敗する事象が
起きた(`pip._vendor.urllib3.exceptions.ReadTimeoutError`)。

最初は「Dockerイメージビルド時にpipキャッシュへ先に取り込んでおく」対処をしたが、
`"~=1.20.0"`というレンジ指定だと実際に解決されるパッチバージョンが変わりうる
(1.20.0〜1.20.4の間で`image-building-requirements.txt`の中身
= 要求される`littlefs-python`のバージョンが`0.13.3`/`0.15.0`の2パターンあることを
実際に確認した)ため、「たぶん合っているキャッシュ」止まりだった。

そこで一歩進めて、**バージョン解決自体を無くす**方針に変更した:

1. Dockerfileで`main/idf_component.yml`の`joltwallet/littlefs`を`"~=1.20.0"`から
   `"1.20.4"`(Docker build時点で実在を確認できた最新パッチ版。
   https://components.espressif.com/components/joltwallet/littlefs で確認)に
   `sed`で固定する。これで`image-building-requirements.txt`の中身
   (=`littlefs-python==0.15.0`)が一意に確定する
2. そのバージョンのwheelを`pip3 download littlefs-python==0.15.0 -d /opt/pip-wheels`
   でDockerイメージビルド時に取得して焼き込む
3. `ENV PIP_NO_INDEX=1` / `ENV PIP_FIND_LINKS=/opt/pip-wheels`
   をコンテナ全体に設定する。これにより、コンテナ内のどのpip実行も常に
   `/opt/pip-wheels`だけを見るようになり(PyPIへの通信自体が発生しない)、
   ビルド実行時のvenv内pipもこの設定を継承する(`ENV`はコンテナの環境変数として
   永続するため、`docker exec`等で入った場合や、`idf.py build`→ninja→cmakeの
   カスタムコマンド経由で起動される孫プロセスにも問題なく伝わる。
   `PROJECT_BUILD_CONFIG`環境変数と同じ伝播の仕組み)

実際に検証もした: `PIP_NO_INDEX=1 PIP_FIND_LINKS=<ローカルディレクトリ>`かつ
存在しないインデックスURLを指定した状態で`pip install littlefs-python==0.15.0`を
実行し、ローカルのwheelだけから(ネットワーク通信なしで)正常にインストールできる
ことを確認済み。

**トレードオフ**: `PIP_NO_INDEX`/`PIP_FIND_LINKS`はコンテナ全体に効くため、
将来他の目的で何かpipインストールが必要になった場合、事前に`/opt/pip-wheels`へ
用意しない限り失敗するようになる(ESP-IDFの component manager自体はPyPIではなく
ESP Component Registryを見る別の仕組みなので影響を受けない)。今のところこの
コンテナ内でpipを使うのはここだけなので許容している。
