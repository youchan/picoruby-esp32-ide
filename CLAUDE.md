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

## 開発環境まわりの注意点

- Rubyの実行環境がこちらのサンドボックスに無かったため、`app.rb` 等は目視レビューのみで
  実機での起動確認はできていない(ユーザー側の `ruby app.rb` で都度確認してもらっている)
- Prism.jsのCDN URL (`cdnjs.cloudflare.com`) はサンドボックスのネットワーク制限で
  直接疎通確認できなかったため、`npm pack prismjs@1.30.0` でnpmレジストリ経由で
  ファイル名(`prism-core.min.js` 等)の実在のみ検証した
- esm.sh経由のESM CDN importは、今回のようなバージョン解決の不安定さが起きやすいので、
  今後もCDN経由でJSライブラリを追加する場合は、安定版の `<script>` タグ+バージョン固定URLを
  優先する方針でよい
