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
      projects: [],
      loading_projects: true,
      current_project: nil,
      files: [],
      loading_files: false,
      current_path: nil,
      content: '',
      saved_content: '',
      status: '',
      status_kind: '',
      build_status: 'idle',
      build_log: '',
      build_log_truncated: false,
      building: false,
      build_vm: '',
      build_usb_console: false,
      platform_status: 'idle',
      platform_log: '',
      platform_log_truncated: false,
      platform_building: false,
      selected_platform: nil
    }
  end

  def component_mounted
    load_project_list
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
      # 最上部のメニュー/グローバルステータスバー。プロジェクト切り替えなど
      # 操作そのものは左のツリーに残し、ここは「今の状態」を表示するだけに徹する。
      component(MenuBar,
        current_project: state[:current_project],
        selected_platform: state[:selected_platform],
        build_status: state[:build_status],
        building: state[:building],
        platform_building: state[:platform_building],
        on_build: -> { start_build },
        on_platform_select: ->(name) { start_platform_setup(name) }
      )

      div(class: 'app-body') do
        div(class: 'sidebar') do
          component(ProjectList,
            projects: state[:projects],
            loading: state[:loading_projects],
            current_project: state[:current_project],
            on_select: ->(name) { select_project(name) }
          )

          component(FileList,
            files: state[:files],
            loading: state[:loading_files],
            current_path: state[:current_path],
            on_select: ->(path) { open_file(path) }
          )
        end

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

          component(BuildPanel,
            build_status: state[:build_status],
            build_log: state[:build_log],
            build_log_truncated: state[:build_log_truncated],
            building: state[:building],
            selected_vm: state[:build_vm],
            usb_console: state[:build_usb_console],
            on_refresh: -> { refresh_build_status },
            on_vm_change: ->(vm) { patch(build_vm: vm) },
            on_usb_console_change: ->(enabled) { patch(build_usb_console: enabled) }
          )

          component(PlatformPanel,
            platform_status: state[:platform_status],
            platform_log: state[:platform_log],
            platform_log_truncated: state[:platform_log_truncated],
            building: state[:platform_building],
            selected_platform: state[:selected_platform],
            on_refresh: -> { refresh_platform_status }
          )
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

  def load_project_list
    Funicular::HTTP.get('/api/projects') do |response|
      if response.ok
        projects = response.data || []
        patch(projects: projects, loading_projects: false)
        select_project(projects.first) if state[:current_project].nil? && !projects.empty?
      else
        patch(
          projects: [],
          loading_projects: false,
          status: 'プロジェクト一覧の取得に失敗しました',
          status_kind: 'error'
        )
      end
    end
  end

  def select_project(name)
    return if name == state[:current_project]

    patch(
      current_project: name,
      files: [],
      loading_files: true,
      current_path: nil,
      content: '',
      saved_content: '',
      status: '',
      status_kind: ''
    )
    # プロジェクト切り替え時は非制御の textarea もクリアしておく
    sync_textarea('')
    load_file_list(name)
  end

  def load_file_list(project)
    Funicular::HTTP.get("/api/files?project=#{encode(project)}") do |response|
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
    project = state[:current_project]

    Funicular::HTTP.get("/api/file?project=#{encode(project)}&path=#{encode(path)}") do |response|
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

    Funicular::HTTP.post('/api/file', { project: state[:current_project], path: path, content: sending }) do |response|
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

  def start_build
    return if state[:building]

    patch(building: true, build_status: 'running', build_log: '')

    payload = { vm: state[:build_vm], usb_console: state[:build_usb_console] }
    Funicular::HTTP.post('/api/build', payload) do |response|
      if response.ok
        schedule_build_poll
      else
        message = response.error_message
        patch(
          building: false,
          build_status: 'failed',
          build_log: (message && !message.empty?) ? message : 'ビルドの開始に失敗しました'
        )
      end
    end
  end

  # ビルド中は一定間隔で自動的にログを取りに行く。完了(running以外)になったら止める。
  #
  # PicoRubyの JS::Object#setTimeout は setTimeout(delay_ms, &block) というシグネチャ
  # (picoruby-wasm の mrblib/js.rb 参照)で、コールバックは第一引数ではなくブロックとして
  # 渡す。JS.global.setTimeout(callback, delay) のように2引数で渡すと
  # 「ArgumentError: wrong number of arguments (given 2, expected 1)」になる。
  def schedule_build_poll
    JS.global.setTimeout(3000) { refresh_build_status }
  end

  def refresh_build_status
    Funicular::HTTP.get('/api/build') do |response|
      next unless response.ok

      data = response.data || {}
      status = value_of(data, 'status').to_s
      log = value_of(data, 'log').to_s
      log_truncated = truthy?(value_of(data, 'log_truncated'))
      still_running = status == 'running'

      patch(
        build_status: status,
        build_log: log,
        build_log_truncated: log_truncated,
        building: still_running
      )

      # running の間だけポーリングを継続する。手動の「ログを更新」クリックと
      # ポーリングのタイマーが両方生きていると呼び出しが二重になりうるが、
      # 単なる冗長リクエストで実害はないため許容している
      schedule_build_poll if still_running
    end
  end

  def start_platform_setup(name)
    return if state[:platform_building]

    patch(
      platform_building: true,
      platform_status: 'running',
      platform_log: '',
      selected_platform: name
    )

    Funicular::HTTP.post('/api/platform', { platform: name }) do |response|
      if response.ok
        schedule_platform_poll
      else
        message = response.error_message
        patch(
          platform_building: false,
          platform_status: 'failed',
          platform_log: (message && !message.empty?) ? message : 'セットアップの開始に失敗しました'
        )
      end
    end
  end

  # 仕組みはビルドのポーリングと同じ(schedule_build_poll参照)。
  def schedule_platform_poll
    JS.global.setTimeout(3000) { refresh_platform_status }
  end

  def refresh_platform_status
    Funicular::HTTP.get('/api/platform') do |response|
      next unless response.ok

      data = response.data || {}
      status = value_of(data, 'status').to_s
      log = value_of(data, 'log').to_s
      log_truncated = truthy?(value_of(data, 'log_truncated'))
      still_running = status == 'running'

      patch(
        platform_status: status,
        platform_log: log,
        platform_log_truncated: log_truncated,
        platform_building: still_running
      )

      schedule_platform_poll if still_running
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
