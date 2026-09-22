require 'js'
require 'crc'

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
#
# ■ ターミナル(xterm.js + Web Serial)を別コンポーネントに切り出さない理由
#
# 当初は TerminalPanel という別コンポーネントに分けていたが、「ファイルペインと
# ターミナルペインを行き来すると接続が切れる」不具合が発生した。原因はFunicularの
# 子コンポーネント(component(...)で呼び出す側)が、**親が再レンダリングされる
# たびに initialize_state / component_mounted をもう一度呼び直す**という挙動
# だったこと(実際にカウンタを仕込んでブラウザで確認した。EditorAppのような
# Funicular.startに渡すルートコンポーネントだけがマウント1回を保証される)。
# xterm.jsのインスタンスやシリアルポートの接続(@port)のような「1回だけ
# 初期化して使い回したい副作用」を持つ以上、それらは全部ルートコンポーネントである
# このEditorAppの中に置く必要がある。textarea/ハイライト層を子コンポーネントに
# 切り出さず、非制御textarea+refで直接扱っているのと同じ理由・同じ対処。
class EditorApp < Funicular::Component
  # 拡張子 → Prism の言語名
  LANGUAGES = { 'rb' => 'ruby', 'c' => 'c', 'h' => 'c' }

  # PicoModemプロトコル定数(picoruby-picomodemのmrblib/picomodem.rbと対応)
  TERM_FILE_WRITE = 0x02
  TERM_CHUNK      = 0x04
  TERM_FILE_ACK   = 0x82
  TERM_CHUNK_ACK  = 0x84
  TERM_DONE_ACK   = 0x8F
  TERM_ERROR      = 0xFE
  TERM_OK         = 0x00

  TERM_CHUNK_SIZE      = 480  # PicoModemの1フレームあたりの最大ペイロード
  TERM_TX_CHUNK_SIZE   = 32   # シリアル書き込み自体を分割するサイズ(USB-CDCの安定性のため)
  TERM_TX_CHUNK_GAP_MS = 20
  TERM_TIMEOUT_MS      = 5000

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
      settings_dialog_open: false,
      project_config: default_project_config,
      settings_platform: nil,
      settings_vm: '',
      settings_usb_console: false,
      platform_status: 'idle',
      platform_log: '',
      platform_log_truncated: false,
      platform_building: false,
      log_tab: 'build',
      editor_tab: 'code',
      terminal_status: 'disconnected', # 'disconnected' | 'connecting' | 'connected'
      terminal_status_message: '未接続',
      terminal_uploading: false,
      terminal_upload_log: []
    }
  end

  def default_project_config
    { 'platform' => nil, 'vm' => nil, 'usb_console' => false }
  end

  def component_mounted
    load_project_list
    setup_terminal
    watch_for_terminal_reconnect
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
      # 最上部のメニュー/グローバルステータスバー。プロジェクト切り替えも
      # ここのドロップダウンに集約している(サイドバーはファイル一覧専用)。
      component(MenuBar,
        projects: state[:projects],
        loading_projects: state[:loading_projects],
        current_project: state[:current_project],
        project_config: state[:project_config],
        build_status: state[:build_status],
        building: state[:building],
        platform_building: state[:platform_building],
        on_project_select: ->(name) { select_project(name) },
        on_settings: -> { open_settings_dialog },
        on_setup: -> { start_platform_setup },
        on_build: -> { start_build }
      )

      if state[:settings_dialog_open]
        component(ProjectSettingsDialog,
          project: state[:current_project],
          platform: state[:settings_platform],
          vm: state[:settings_vm],
          usb_console: state[:settings_usb_console],
          on_platform_change: ->(platform) { patch(settings_platform: platform) },
          on_vm_change: ->(vm) { patch(settings_vm: vm) },
          on_usb_console_change: ->(enabled) { patch(settings_usb_console: enabled) },
          on_save: -> { save_project_settings },
          on_cancel: -> { patch(settings_dialog_open: false) }
        )
      end

      div(class: 'app-body') do
        div(class: 'sidebar') do
          component(FileList,
            files: state[:files],
            loading: state[:loading_files],
            current_path: state[:current_path],
            on_select: ->(path) { open_file(path) }
          )
        end

        div(class: 'editor-area') do
          render_editor_tabs

          # コード編集タブとターミナルタブは常に両方マウントしたままにし、
          # 非表示時は class(hidden)でCSS上隠すだけにしてある。ターミナルタブを
          # 条件付きレンダリングでVDOMから外し入れすると、タブを切り替えるたびに
          # TerminalPanelがunmount/remountされ、シリアル接続やxterm.jsの状態が
          # 消えてしまうため。
          div(class: tab_pane_class('code')) do
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

          div(class: tab_pane_class('terminal')) { render_terminal_panel }

          component(LogPanel,
            active_tab: state[:log_tab],
            build_status: state[:build_status],
            build_log: state[:build_log],
            build_log_truncated: state[:build_log_truncated],
            platform_status: state[:platform_status],
            platform_log: state[:platform_log],
            platform_log_truncated: state[:platform_log_truncated],
            selected_platform: value_of(state[:project_config], 'platform'),
            on_tab_change: ->(tab) { patch(log_tab: tab) },
            on_build_refresh: -> { refresh_build_status },
            on_platform_refresh: -> { refresh_platform_status }
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

  def handle_select_code_tab(event)
    event.preventDefault
    patch(editor_tab: 'code')
  end

  def handle_select_terminal_tab(event)
    event.preventDefault
    patch(editor_tab: 'terminal')
  end

  def handle_terminal_connect(event)
    event.preventDefault
    terminal_connected? ? terminal_disconnect : terminal_connect
  end

  def handle_terminal_upload(event)
    event.preventDefault
    upload_app_directory
  end

  # 行番号カラムを本文のスクロールに追従させる
  def handle_scroll(event)
    scroll = refs[:scroll]
    lines = refs[:lines]
    return unless scroll && lines
    lines[:scrollTop] = scroll[:scrollTop]
  end

  private

  def render_editor_tabs
    div(class: 'editor-tabs') do
      render_editor_tab_button('code', 'エディタ', :handle_select_code_tab)
      render_editor_tab_button('terminal', 'ターミナル', :handle_select_terminal_tab)
    end
  end

  def render_editor_tab_button(key, label, handler)
    classes = key == state[:editor_tab] ? 'editor-tab active' : 'editor-tab'
    button(class: classes, onclick: handler) { label }
  end

  def tab_pane_class(key)
    key == state[:editor_tab] ? 'tab-pane' : 'tab-pane hidden'
  end

  # --- ターミナル(xterm.js + Web Serial) --------------------------------
  #
  # R2P2-ESP32のUSBシリアルに、ブラウザのWeb Serial API (JS::WebSerial、
  # picoruby-wasm本体が提供する。picoruby.org/terminal と同じ仕組み)経由で
  # 直接つなぎ、xterm.jsでターミナルとして表示する。ビルド/インストールとは違い
  # サーバは一切関与しない(ブラウザ⇔実機のUSBが直結)。
  #
  # 「app/ をアップロード」ボタンは、R2P2のシェル(picoruby-shell)がプロンプトで
  # Ctrl-B(STX, 0x02)を受け取るとPicoModemセッション(picoruby-picomodem。
  # picoruby-shellのデフォルト依存gemなので、R2P2-ESP32の標準ビルドには常に
  # 含まれている。R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/
  # picoruby-shell/mrbgem.rake 参照)に入る仕組みを使い、現在のプロジェクトの
  # app/以下をファイルごとに実機の/home/以下へ書き込む。PicoModemは1セッションに
  # つき1ファイルのFILE_WRITEしか処理せずシェルへ戻るため、複数ファイルは
  # 「Ctrl-B送信→ACK待ち→FILE_WRITE」をファイルごとに繰り返す。
  #
  # フレームの組み立て・CRC計算・エラー処理・自動再接続は picoruby/picoruby.github.io
  # の pages/r2p2/terminal.rb (picoruby.org/terminal の実装)にあるPicoModem
  # ホストクライアント/自動再接続をほぼそのまま移植したもの。

  def render_terminal_panel
    div(class: 'terminal-panel') do
      div(class: 'terminal-controls') do
        render_terminal_connect_button
        render_terminal_upload_button
        span(class: "terminal-status #{state[:terminal_status]}") { state[:terminal_status_message] }
      end
      div(class: 'terminal-container', ref: :terminal_container)
      render_terminal_upload_log
    end
  end

  def terminal_connected?
    state[:terminal_status] == 'connected'
  end

  def render_terminal_connect_button
    if state[:terminal_status] == 'connecting'
      button(class: 'terminal-connect', disabled: true) { '接続中…' }
    else
      button(class: 'terminal-connect', onclick: :handle_terminal_connect) { terminal_connected? ? '切断' : 'デバイスに接続' }
    end
  end

  def render_terminal_upload_button
    if terminal_connected? && !state[:terminal_uploading]
      button(class: 'terminal-upload', onclick: :handle_terminal_upload) { 'app/ をアップロード' }
    else
      button(class: 'terminal-upload', disabled: true) { state[:terminal_uploading] ? 'アップロード中…' : 'app/ をアップロード' }
    end
  end

  def render_terminal_upload_log
    return if state[:terminal_upload_log].empty?
    tag(:pre, class: 'terminal-upload-log') { state[:terminal_upload_log].join("\n") }
  end

  # xterm.jsの初期化。EditorApp(ルートコンポーネント)のcomponent_mountedから
  # 一度だけ呼ばれる。まだターミナルタブが非表示(class=hidden、display:none)の
  # 間はコンテナの寸法が0になるが、`terminal.open`自体は非表示要素に対しても
  # 問題なく行える。実際の行数/桁数はタブを表示したときにResizeObserverが
  # コンテナの寸法変化を検知して`fit`し直すので、正しいサイズに追従する。
  def setup_terminal
    container = refs[:terminal_container]
    return unless container

    opts = JS.global.create_object
    opts[:scrollback] = 1000
    opts[:cursorBlink] = true
    opts[:convertEol] = true
    opts[:fontFamily] = '"SF Mono", Menlo, Consolas, "Courier New", monospace'
    opts[:fontSize] = 14
    theme = JS.global.create_object
    theme[:background] = '#1a1a1a'
    opts[:theme] = theme

    xterm = JS.global[:Terminal].new(opts)
    @terminal_fit_addon = JS.global[:FitAddon][:FitAddon].new
    xterm.loadAddon(@terminal_fit_addon)
    xterm.open(container)
    @xterm = xterm
    fit_terminal

    JS.global[:ResizeObserver].new { |_entries| fit_terminal }.observe(container)

    # Escapeキーをブラウザに奪われないようにする(全画面解除等のショートカットと衝突するため)
    xterm.attachCustomKeyEventHandler do |event|
      event.preventDefault if event[:key].to_s == 'Escape'
      true
    end

    # 入力はそのままシリアルへ流す(R2P2のシェルが側でエコーバックする)
    xterm.onData { |data| terminal_send_bytes(data.to_s) }
  end

  def fit_terminal
    @terminal_fit_addon&.fit
  end

  def terminal_connect
    unless JS::WebSerial.supported?
      patch(terminal_status: 'disconnected', terminal_status_message: 'Web Serial APIに対応していないブラウザです(Chrome/Edge推奨)')
      return
    end

    patch(terminal_status: 'connecting', terminal_status_message: '接続中…')

    begin
      JS::WebSerial.connect(baud_rate: 115_200) do |ws|
        @terminal_port = ws
        ws.start_terminal_read(@xterm) if @xterm
        ws.on_disconnect { handle_terminal_port_disconnected }
      end
      # ユーザーが明示的に「切断」するまでは、デバイス側の再起動等で
      # ポートが一旦消えても自動再接続を試みる(watch_for_terminal_reconnect参照)。
      @terminal_auto_reconnect = true
      patch(terminal_status: 'connected', terminal_status_message: '接続済み')
      @xterm&.focus
    rescue => e
      @terminal_port = nil
      patch(terminal_status: 'disconnected', terminal_status_message: "接続エラー: #{e.message}")
    end
  end

  # ユーザーがボタンを押しての明示的な切断。以後は自動再接続もしない。
  def terminal_disconnect
    @terminal_auto_reconnect = false
    port = @terminal_port
    @terminal_port = nil
    patch(terminal_status: 'disconnected', terminal_status_message: '未接続')
    return unless port

    port.close rescue nil
  end

  # ポート側からの切断通知(_set_on_disconnect経由、または後述の
  # navigator.serialのdisconnectイベント)。ユーザーの明示的な切断とは違い
  # @terminal_auto_reconnectはそのままにしておく(自動再接続待ちの状態にする)。
  def handle_terminal_port_disconnected
    return unless @terminal_port

    @terminal_port = nil
    if @terminal_auto_reconnect
      patch(terminal_status: 'connecting', terminal_status_message: 'デバイスが再起動中です…自動的に再接続します')
    else
      patch(terminal_status: 'disconnected', terminal_status_message: 'デバイスが切断されました')
    end
  end

  # デバイスがCPUリセット等で再起動すると、USBの列挙が一瞬切れてから
  # 同じ物理ポートとして再度現れる(Web Serial的には対象ポートの'disconnect'に
  # 続けて、ブラウザ全体に'connect'イベントが飛んでくる)。
  # picoruby.org/terminal (pages/r2p2/terminal.rb)のApp#connect/bind_eventsと
  # 同じ仕組みで、権限を与え済みのポートが再度現れたら(ユーザー操作なしに)
  # 自動で開き直す。
  #
  # JS::WebSerial._watch_connect_events / _take_last_connected_port は
  # npmパッケージのwasmにC拡張として直接コンパイルされているが、mrblib側に
  # 高レベルのラッパーメソッドが無い(webserial.rbのRuby側APIには存在しない)
  # ため、"_"付きのまま直接呼び出している。実際に呼べることは
  # `JS::WebSerial.methods(false)`をブラウザのコンソールに出して確認済み。
  def watch_for_terminal_reconnect
    return unless JS::WebSerial.supported?

    JS::WebSerial._watch_connect_events
    JS.global.addEventListener('serial-port-connect') { attempt_terminal_auto_reconnect }

    # 個別ポートのon_disconnect(_set_on_disconnect)がブラウザ/デバイスの
    # 組み合わせによっては発火しないことがあるための保険。terminal.rbでも
    # navigator.serial自体のdisconnectイベントを別途見ている。
    JS.global[:navigator][:serial].addEventListener('disconnect') { handle_terminal_port_disconnected }
  end

  def attempt_terminal_auto_reconnect
    return unless @terminal_auto_reconnect
    return if @terminal_port

    raw_port = JS::WebSerial._take_last_connected_port
    return unless raw_port

    patch(terminal_status: 'connecting', terminal_status_message: '再接続中…')
    # 再起動直後はまだUSBの列挙が安定していないことがあるため、
    # terminal.rbに倣って少し待ってから開く。
    sleep_ms 1500

    begin
      ws = JS::WebSerial.new(raw_port)
      ws.open(baud_rate: 115_200)
      ws.start_terminal_read(@xterm) if @xterm
      ws.on_disconnect { handle_terminal_port_disconnected }
      @terminal_port = ws
      patch(terminal_status: 'connected', terminal_status_message: '再接続しました')
    rescue => e
      patch(terminal_status: 'disconnected', terminal_status_message: "再接続に失敗しました: #{e.message}")
    end
  end

  def terminal_send_bytes(str)
    @terminal_port&.write(str)
  end

  # --- app/ のアップロード(PicoModemプロトコル) ---------------------------

  def upload_app_directory
    return if state[:terminal_uploading]
    return unless terminal_connected?

    files = terminal_app_files
    if files.empty?
      patch(terminal_upload_log: ['app/ 以下にアップロード可能なファイルがありません'])
      return
    end

    patch(terminal_uploading: true, terminal_upload_log: ["#{files.length}個のファイルをアップロードします…"])
    upload_next_terminal_file(files, 0)
  end

  # state[:files](現在のプロジェクトのALLOWED_EXTENSIONSファイル一覧)から
  # "app/"配下だけを取り出し、[プロジェクト内の相対パス, 実機上のパス]の
  # ペアにする。POST /api/buildがapp/以下をstorage/home/へコピーする
  # (=実機からは/home/以下に見える)のと対応を合わせてある。
  def terminal_app_files
    result = []
    (state[:files] || []).each do |path|
      next unless path.start_with?('app/')
      relative = path.sub('app/', '')
      next if relative.empty?
      result << [path, "/home/#{relative}"]
    end
    result
  end

  # ファイルを1つずつ順番に処理する(継続渡し)。Funicular::HTTPのコールバックが
  # 同期/非同期どちらであっても、必ず1ファイルの転送が完全に終わってから
  # 次のCtrl-B送信に進むようにするため、Enumerable#eachではなくこの形にしてある
  # (PicoModemは1本のシリアル接続を排他的に使うプロトコルなので、複数ファイルの
  # 転送が重なるとフレームが混ざって壊れる)。
  def upload_next_terminal_file(files, index)
    if index >= files.length
      patch(terminal_uploading: false)
      append_terminal_upload_log('アップロードが完了しました')
      return
    end

    relative_path, device_path = files[index]
    upload_one_terminal_file(relative_path, device_path) { upload_next_terminal_file(files, index + 1) }
  end

  def upload_one_terminal_file(relative_path, device_path, &done)
    append_terminal_upload_log("#{relative_path} -> #{device_path} …")
    project = state[:current_project]

    Funicular::HTTP.get("/api/file?project=#{encode(project)}&path=#{encode(relative_path)}") do |response|
      unless response.ok
        append_terminal_upload_log('  読み込みに失敗しました')
        done.call
        next
      end

      content = value_of(response.data, 'content').to_s
      begin
        enter_picomodem_mode
        write_picomodem_file(device_path, content)
        append_terminal_upload_log("  完了 (#{content.bytesize} bytes)")
      rescue => e
        append_terminal_upload_log("  失敗: #{e.message}")
      ensure
        exit_picomodem_mode
        done.call
      end
    end
  end

  # --- PicoModemクライアント(ホスト側) -----------------------------------
  # 実装は picoruby.org/terminal (picoruby/picoruby.github.io の
  # pages/r2p2/terminal.rb)のPicoModemクライアント部分に準拠している。

  def enter_picomodem_mode
    raise 'デバイスに接続されていません' unless @terminal_port
    js_port = @terminal_port.instance_variable_get(:@js_port)

    JS::WebSerial.binary_capture_start(js_port)
    @terminal_port.write("\x02")
    @terminal_port.drain.await

    waited = 0
    while waited < TERM_TIMEOUT_MS
      b = JS::WebSerial.binary_capture_read(js_port, 1)
      if b && 0 < b.bytesize
        return if b.getbyte(0) == 0x06
        next
      end
      sleep_ms 10
      waited += 10
    end

    JS::WebSerial.binary_capture_stop(js_port) rescue nil
    raise 'デバイスからの応答がありません(R2P2のプロンプトが表示されているか確認してください)'
  end

  def exit_picomodem_mode
    return unless @terminal_port
    js_port = @terminal_port.instance_variable_get(:@js_port)
    JS::WebSerial.binary_capture_stop(js_port) rescue nil
  end

  def write_picomodem_file(path, content)
    js_port = @terminal_port.instance_variable_get(:@js_port)

    send_picomodem_frame(TERM_FILE_WRITE, [content.bytesize].pack('N') + path)

    frame = recv_picomodem_frame(js_port)
    raise 'タイムアウト(書き込み開始の応答待ち)' unless frame
    raise "デバイスエラー: #{frame[1]}" if frame[0] == TERM_ERROR
    raise "想定外の応答: 0x#{frame[0].to_s(16)}" unless frame[0] == TERM_FILE_ACK

    offset = 0
    while offset < content.bytesize
      remain = content.bytesize - offset
      size = remain < TERM_CHUNK_SIZE ? remain : TERM_CHUNK_SIZE
      chunk = content.byteslice(offset, size)
      send_picomodem_frame(TERM_CHUNK, chunk)

      ack = recv_picomodem_frame(js_port)
      raise "タイムアウト(#{offset}バイト目)" unless ack
      raise "デバイスエラー: #{ack[1]}" if ack[0] == TERM_ERROR
      raise "想定外の応答: 0x#{ack[0].to_s(16)}" unless ack[0] == TERM_CHUNK_ACK

      offset += size
    end

    frame = recv_picomodem_frame(js_port)
    raise 'タイムアウト(完了待ち)' unless frame
    raise "デバイスエラー: #{frame[1]}" if frame[0] == TERM_ERROR
    raise "想定外の応答: 0x#{frame[0].to_s(16)}" unless frame[0] == TERM_DONE_ACK

    payload = frame[1]
    return unless 5 <= payload.bytesize

    status = payload.getbyte(0)
    remote_crc = payload.byteslice(1, 4).unpack('N')[0]
    local_crc = CRC.crc32(content)
    raise 'CRC32が一致しません(転送中にデータが壊れた可能性があります)' unless status == TERM_OK && local_crc == remote_crc
  end

  def send_picomodem_frame(cmd, payload = '')
    body = cmd.chr + payload.to_s
    crc = CRC.crc16(body)
    frame = [0x02, body.bytesize].pack('Cn') + body + [crc].pack('n')
    send_picomodem_bytes(frame)
  end

  def send_picomodem_bytes(data)
    return unless @terminal_port
    off = 0
    while off < data.bytesize
      remain = data.bytesize - off
      size = remain < TERM_TX_CHUNK_SIZE ? remain : TERM_TX_CHUNK_SIZE
      @terminal_port.write(data.byteslice(off, size))
      off += size
      sleep_ms(TERM_TX_CHUNK_GAP_MS) if off < data.bytesize
    end
    @terminal_port.drain.await
  end

  def recv_picomodem_frame(js_port)
    stx = read_picomodem_exact(js_port, 1)
    return nil unless stx
    return nil unless stx.getbyte(0) == 0x02

    len_bytes = read_picomodem_exact(js_port, 2)
    return nil unless len_bytes
    length = len_bytes.unpack('n')[0]

    rest = read_picomodem_exact(js_port, length + 2)
    return nil unless rest
    body = rest.byteslice(0, length)
    expected_crc = rest.byteslice(length, 2).unpack('n')[0]
    return nil unless CRC.crc16(body) == expected_crc

    cmd = body.getbyte(0)
    payload = 1 < length ? body.byteslice(1, length - 1) : ''
    [cmd, payload]
  end

  def read_picomodem_exact(js_port, n)
    buf = ''
    waited = 0
    while buf.bytesize < n
      chunk = JS::WebSerial.binary_capture_read(js_port, n - buf.bytesize)
      if chunk && 0 < chunk.bytesize
        buf << chunk
        waited = 0
      else
        return nil if TERM_TIMEOUT_MS <= waited
        sleep_ms 10
        waited += 10
      end
    end
    buf
  end

  def append_terminal_upload_log(line)
    patch(terminal_upload_log: state[:terminal_upload_log] + [line])
  end

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
        select_project(projects.first.to_s) if state[:current_project].nil? && !projects.empty?
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
      status_kind: '',
      settings_dialog_open: false,
      project_config: default_project_config
    )
    # プロジェクト切り替え時は非制御の textarea もクリアしておく
    sync_textarea('')
    load_file_list(name)
    load_project_config(name)
  end

  def load_project_config(name)
    Funicular::HTTP.get("/api/projects/#{encode(name)}/config") do |response|
      next unless response.ok
      next unless name == state[:current_project]

      data = response.data || {}
      patch(
        project_config: {
          'platform' => value_of(data, 'platform'),
          'vm' => value_of(data, 'vm'),
          'usb_console' => truthy?(value_of(data, 'usb_console'))
        }
      )
    end
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

    payload = { project: state[:current_project] }
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

  def start_platform_setup
    return if state[:platform_building]
    return if value_of(state[:project_config], 'platform').to_s.empty?

    patch(platform_building: true, platform_status: 'running', platform_log: '')

    Funicular::HTTP.post('/api/platform', { project: state[:current_project] }) do |response|
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

  # --- プロジェクト設定ダイアログ -----------------------------------------

  # 現在保存されている設定(state[:project_config])を作業用のフィールドへ
  # コピーしてダイアログを開く。キャンセルすれば作業用フィールドは捨てられる。
  def open_settings_dialog
    config = state[:project_config] || {}
    patch(
      settings_dialog_open: true,
      settings_platform: value_of(config, 'platform'),
      settings_vm: value_of(config, 'vm').to_s,
      settings_usb_console: truthy?(value_of(config, 'usb_console'))
    )
  end

  def save_project_settings
    project = state[:current_project]
    platform = state[:settings_platform]
    vm = state[:settings_vm].to_s.empty? ? nil : state[:settings_vm]
    usb_console = state[:settings_usb_console]

    payload = { platform: platform, vm: vm, usb_console: usb_console }
    Funicular::HTTP.post("/api/projects/#{encode(project)}/config", payload) do |response|
      if response.ok
        patch(
          settings_dialog_open: false,
          project_config: { 'platform' => platform, 'vm' => vm, 'usb_console' => usb_console },
          status: 'プロジェクト設定を保存しました',
          status_kind: 'ok'
        )
      else
        message = response.error_message
        patch(status: (message && !message.empty?) ? message : '設定の保存に失敗しました', status_kind: 'error')
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
