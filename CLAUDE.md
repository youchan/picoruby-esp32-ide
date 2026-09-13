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
- **実機への書き込み(flash)が未実装**: プラットフォーム選択+セットアップ
  (`POST /api/platform`)までは実装済みだが、ビルド済みイメージをUSB接続した
  ESP32に書き込む機能(`R2P2-ESP32/rakelib/flash.rake` の `flash` タスク相当)は
  まだない。公式の [R2P2-ESP32-installer](https://picoruby.org/R2P2-ESP32-installer/)
  はブラウザのWeb Serial API(ESP Web Tools)で直接USBに書き込む方式だが、
  今のこのプロジェクトのアーキテクチャ(サーバ側=Dockerコンテナでrake/idf.pyを実行)
  で同じことをするには、コンテナにUSBシリアルデバイスを渡す
  (`docker run --device /dev/ttyUSB0` 等、`bin/dev` の変更が要る)か、
  Web Serial API側に倒すか、設計判断が必要

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
