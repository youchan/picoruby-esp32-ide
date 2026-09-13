# ESP32へのインストール(書き込み)パネル。
#
# ビルド/セットアップと違い、書き込み自体はサーバではなくブラウザの
# Web Serial API経由でESP Web Tools(https://esphome.github.io/esp-web-tools/、
# index.html でCDN読み込み)が行う。サーバは:
#   - /api/firmware/manifest.json でビルド成果物からマニフェストを組み立てる
#   - /api/firmware/:filename で .bin を配信する
# だけを担当し、進捗ダイアログの表示や書き込み処理自体はesp-web-install-button
# (カスタム要素)にすべて任せる。表示専用の他パネルとは違い、状態を持たない。
class InstallPanel < Funicular::Component
  MANIFEST_PATH = '/api/firmware/manifest.json'

  def render
    div(class: 'install-panel') do
      div(class: 'install-panel-header') { h1 { 'Install to Device' } }
      p(class: 'install-hint') do
        'USBケーブルでESP32を接続してから押してください' \
        '(Chrome/Edge/Operaのみ対応。ビルドが完了している必要があります)'
      end
      tag(:'esp-web-install-button', manifest: MANIFEST_PATH) do
        button(slot: 'activate') { 'デバイスにインストール' }
        span(slot: 'unsupported') { 'このブラウザはWeb Serial APIに対応していません(Chrome/Edge/Operaを使ってください)' }
        span(slot: 'not-allowed') { 'HTTPS(またはlocalhost)でアクセスしてください' }
      end
    end
  end
end
