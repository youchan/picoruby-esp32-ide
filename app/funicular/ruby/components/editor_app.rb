require 'js'

# エディタ全体のルートコンポーネント。
#
# 状態(ファイル一覧・編集中のパス・バッファ・保存済み内容)はすべてここが持ち、
# FileList / Toolbar には props で流すだけの構成にしている。
#
# ■ textarea と Prism ハイライトの扱いについて
#
# textarea は VDOM の制御下に置かず(value を render で出力せず)、
# ファイルを切り替えたときだけ ref 経由で value を差し替える「非制御」にしている。
# 入力のたびに VDOM が value を書き戻すとキャレットが末尾に飛ぶため。
#
# ハイライト層 <code> も同様に、VDOM 上は「子を持たない空要素」として描画し、
# Prism が生成したHTMLを innerHTML に直接流し込む。
# 子を持たない要素は再描画時の差分がゼロなので、innerHTML が消されることはない。
class EditorApp < Funicular::Component
  # 拡張子 → Prism の言語名
  LANGUAGES = { 'rb' => 'ruby', 'c' => 'c', 'h' => 'c' }

  def initialize_state
    {
      files: [],
      loading_files: true,
      current_path: nil,
      content: '',
      saved_content: '',
      status: '',
      status_kind: ''
    }
  end

  def component_mounted
    load_file_list
  end

  # state が変わるたびに呼ばれる(Funicular::Component#patch から引数なしで呼ばれる)。
  # ハイライトは VDOM の外側(ref + innerHTML)で管理しているので、ここで同期する。
  # 前回描画時との差分は自前で覚えておく必要がある。
  def component_updated
    return if @prev_highlight_content == state[:content] &&
              @prev_highlight_path == state[:current_path]

    @prev_highlight_content = state[:content]
    @prev_highlight_path = state[:current_path]
    refresh_highlight
  end

  def render
    div(class: 'app') do
      component(FileList,
        files: state[:files],
        loading: state[:loading_files],
        current_path: state[:current_path],
        on_select: ->(path) { open_file(path) }
      )

      div(class: 'editor-area') do
        component(Toolbar,
          current_path: state[:current_path],
          dirty: dirty?,
          status: state[:status],
          status_kind: state[:status_kind],
          on_save: -> { save_file }
        )

        div(class: 'editor-wrapper') do
          # 行番号は innerHTML を使わず、そのまま VDOM で描画する
          div(class: 'line-numbers', ref: :lines) do
            (1..line_count).each do |n|
              div { n.to_s }
            end
          end

          # スクロールする要素をこのコンテナ一箇所に集約し、
          # ハイライト層と textarea は CSS Grid で同じセルに重ねる(style.css 参照)
          div(class: 'editor-scroll-area', ref: :scroll, onscroll: :handle_scroll) do
            tag(:pre, class: 'highlight-layer') do
              tag(:code, ref: :highlight)
            end
            render_textarea
          end
        end
      end
    end
  end

  # --- イベントハンドラ ------------------------------------------------

  def handle_input(event)
    node = refs[:editor]
    return unless node
    patch(content: node[:value].to_s)
  end

  def handle_keydown(event)
    key = event[:key].to_s

    # Ctrl+S / Cmd+S で保存
    if key == 's' && (truthy?(event[:ctrlKey]) || truthy?(event[:metaKey]))
      event.preventDefault
      save_file
      return
    end

    # Tab はフォーカス移動ではなくスペース2つの挿入にする
    if key == 'Tab'
      event.preventDefault
      insert_indent
    end
  end

  # 行番号カラムを本文のスクロールに追従させる
  def handle_scroll(event)
    scroll = refs[:scroll]
    lines = refs[:lines]
    return unless scroll && lines
    lines[:scrollTop] = scroll[:scrollTop]
  end

  private

  def render_textarea
    if state[:current_path]
      tag(:textarea,
        id: 'editor',
        ref: :editor,
        spellcheck: 'false',
        oninput: :handle_input,
        onkeydown: :handle_keydown
      )
    else
      tag(:textarea,
        id: 'editor',
        ref: :editor,
        spellcheck: 'false',
        disabled: true,
        placeholder: '左のファイル一覧から編集するファイルを選んでください'
      )
    end
  end

  # --- サーバとのやりとり ----------------------------------------------

  def load_file_list
    Funicular::HTTP.get('/api/files') do |response|
      if response.ok
        patch(files: response.data || [], loading_files: false)
      else
        patch(
          files: [],
          loading_files: false,
          status: 'ファイル一覧の取得に失敗しました',
          status_kind: 'error'
        )
      end
    end
  end

  def open_file(path)
    return if path == state[:current_path]

    patch(status: '読み込み中…', status_kind: '')

    Funicular::HTTP.get("/api/file?path=#{encode(path)}") do |response|
      if response.ok
        content = value_of(response.data, 'content').to_s
        patch(
          current_path: path,
          content: content,
          saved_content: content,
          status: '',
          status_kind: ''
        )
        # 非制御の textarea なので、ファイル切り替え時はここで流し込む
        sync_textarea(content)
      else
        patch(status: '読み込みに失敗しました', status_kind: 'error')
      end
    end
  end

  def save_file
    path = state[:current_path]
    return unless path
    return unless dirty?

    # 送信時点の内容を控えておく(レスポンスが返る頃には編集が進んでいる可能性がある)
    sending = state[:content]

    Funicular::HTTP.post('/api/file', { path: path, content: sending }) do |response|
      if response.ok
        patch(saved_content: sending, status: '保存しました', status_kind: 'ok')
      else
        message = response.error_message
        patch(
          status: (message && !message.empty?) ? message : '保存に失敗しました',
          status_kind: 'error'
        )
      end
    end
  end

  # --- 表示まわりのヘルパ ----------------------------------------------

  def dirty?
    !state[:current_path].nil? && state[:content] != state[:saved_content]
  end

  def line_count
    count = 1
    state[:content].each_char { |ch| count += 1 if ch == "\n" }
    count
  end

  def refresh_highlight
    node = refs[:highlight]
    return unless node
    html = JS.global.funicularHighlight(state[:content], language).to_s
    node[:innerHTML] = html
  end

  def sync_textarea(content)
    node = refs[:editor]
    return unless node
    node[:value] = content
  end

  def insert_indent
    node = refs[:editor]
    return unless node

    value = node[:value].to_s
    from = node[:selectionStart].to_i
    to = node[:selectionEnd].to_i

    node[:value] = value[0, from].to_s + '  ' + value[to, value.length - to].to_s
    node[:selectionStart] = from + 2
    node[:selectionEnd] = from + 2

    patch(content: node[:value].to_s)
  end

  def language
    LANGUAGES[extension(state[:current_path])] || 'ruby'
  end

  def extension(path)
    parts = path.to_s.split('.')
    parts.length > 1 ? parts.last.to_s : ''
  end

  def encode(path)
    JS.global.encodeURIComponent(path).to_s
  end

  # JSONのパース結果がキーを String / Symbol どちらで持つかは環境差があるため両対応にする
  def value_of(data, key)
    return nil unless data
    data[key] || data[key.to_sym]
  end

  def truthy?(js_value)
    js_value.to_s == 'true'
  end
end
