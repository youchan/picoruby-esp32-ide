# Prism.js + Sinatra サンプルエディタ

Ruby / C のソースコードをブラウザ上で編集できる最小構成のサンプルアプリです。

エディタ部分は https://picoruby.org/terminal の「File Editor (PicoModem)」と同じ
アプローチ(`textarea` + 行番号レイヤー + シンタックスハイライトレイヤーの重ね合わせ)を
参考にしています。

## 構成

- **サーバー**: Sinatra (Ruby) — ファイルの一覧取得・読み込み・保存をJSON APIで提供
- **エディタ**: 自作の `textarea` オーバーレイ方式(ビルド不要)
  - `<textarea>` を透明にしてキャレットだけ見せ、その下に
    [Prism.js](https://prismjs.com/) でハイライトした `<pre><code>` を、
    CSS Grid で同じセルに重ねて表示
  - `<textarea>` は内容があふれると要素内部で独自にスクロールする性質があるため、
    `position: absolute` で単純に重ねるとキャレット位置とハイライト表示がズレる。
    Gridで重ねてスクロール可能な要素を親コンテナひとつに集約することでこれを回避している
  - 行番号は別カラムに描画し、`scroll` イベントでスクロール位置を同期
  - Prism.jsはcdnjs経由・バージョン固定の `<script>` タグで読み込み(npm/ビルド不要)
- **編集対象**: `project/` ディレクトリ以下の `.rb` `.c` `.h` ファイル

## なぜCodeMirror 6からこの方式に変えたか

CodeMirror 6をesm.sh経由のESMで読み込んでいたところ、パッケージ間のバージョン解決が
ずれて `does not provide an export named 'basicSetup'` のような読み込みエラーが
発生しました。CDN上のESMは複数パッケージ間のバージョン整合性が崩れやすく、
特にCodeMirror 6のような多パッケージ構成のライブラリとは相性が悪い場合があります。

Prism.jsは昔ながらの `<script>` タグ読み込みが標準かつ安定しており、バージョンを
固定したCDN URLを直接指定するだけで動きます。ビルドステップ(npm/esbuild)も
不要になったため、Rubyだけで完結するという当初の狙いにも近づきました。

その代わり、CodeMirror 6にあった補完・複数カーソル・折りたたみなどの高度な編集機能は
ありません。あくまで「シンタックスハイライト付きのシンプルなコードエディタ」です。

## セットアップ

```bash
bundle install
```

## 起動

```bash
ruby app.rb
```

デフォルトで `http://localhost:4567` で起動します。ブラウザで開いてください。
npmやNode.jsのインストール、ビルドは不要です。

## 使い方

1. 左サイドバーに `project/` 以下の編集可能ファイル(`.rb` `.c` `.h`)が一覧表示されます
2. ファイルをクリックするとエディタに読み込まれ、拡張子に応じてシンタックスハイライトが切り替わります
3. 編集後、「保存」ボタンまたは `Ctrl/Cmd + S` で保存されます(サーバー側でファイルに書き込み)
4. `Tab` キーでスペース2つ分のインデントを挿入します

## ディレクトリ構成

```
.
├── app.rb                   # Sinatraアプリ本体(API定義)
├── Gemfile
├── views/
│   └── index.erb              # エディタ画面のHTML(Prism.jsをCDNから読み込み)
├── public/
│   ├── css/style.css          # textareaオーバーレイ・行番号・Prismトークン配色
│   └── js/editor.js           # エディタ本体のロジック(ビルド不要のvanilla JS)
└── project/                   # 編集対象のサンプルプロジェクト
    ├── lib/sample.rb
    └── ext/
        ├── sample.c
        └── sample.h
```

## 拡張のヒント

- **編集対象の拡張子を増やす**: `app.rb` の `ALLOWED_EXTENSIONS`、`views/index.erb` の
  Prismコンポーネント読み込み(例: Pythonなら `prism-python.min.js`)、
  `public/js/editor.js` の `languageFor` / `iconFor` を対応させて追加してください
- **自動インデント**: 現状はTabキーでのスペース挿入のみです。picoruby側の
  `auto_indent.rb` のように、改行時に直前行のインデント幅を引き継ぐ処理を
  `renderHighlight` 前後に追加すると使い勝手が上がります
- **新規ファイル作成やファイルツリーの階層表示**: 現状は保存は既存ファイルの上書きのみです。
  作成・削除・リネームAPIを `app.rb` に追加し、サイドバーをツリー構造にすると本格的なIDEに近づきます
- **複数人での同時編集**: 現状は単純な上書き保存のため、同時編集での競合は考慮していません。
  必要であれば `Faye::WebSocket` や `ActionCable` 相当の仕組み、あるいは
  Yjs (CRDT) との連携を検討してください
- **大きいファイルでのパフォーマンス**: この方式は入力のたびに全文を再トークナイズするため、
  数千行を超えるような大きいファイルでは重くなる可能性があります。その場合は
  デバウンス処理を入れるか、CodeMirror 6のような差分更新型のエディタへの移行を検討してください
