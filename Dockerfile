FROM espressif/idf:v5.5.1

SHELL ["/bin/bash", "-c"]

ENV RBENV_ROOT=/root/.rbenv
ENV PATH="${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libyaml-dev \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/rbenv/rbenv.git "${RBENV_ROOT}"
RUN git clone --depth 1 https://github.com/rbenv/ruby-build.git "$(rbenv root)"/plugins/ruby-build
RUN rbenv init

RUN rbenv install 4.0.6
RUN rbenv global 4.0.6

RUN git clone --depth 1 https://github.com/picoruby/R2P2-ESP32.git

WORKDIR /R2P2-ESP32
RUN git submodule update --init --recursive

# プロジェクトごとのgem追加/除外(picoruby-esp32-ide側の projects/<name>/build_config.rb)
# をビルドに反映させるためのフック。本家の4つのbuild_config(xtensa/riscv ×
# femtoruby/picoruby)を複製せず、各ファイルの `do |conf| ... end` ブロック末尾に
# 1行だけ差し込む。PROJECT_BUILD_CONFIG環境変数(未設定なら何もしない)が指す
# Rubyファイルをconfのコンテキストで評価するだけなので、本家の内容には一切手を
# 加えない(詳細はCLAUDE.mdおよびapp.rbのコメント参照)。
RUN for f in components/picoruby-esp32/build_config/*.rb; do \
    head -n -1 "$f" > "$f.tmp" && \
    printf '\n  conf.instance_eval(File.read(ENV["PROJECT_BUILD_CONFIG"]), ENV["PROJECT_BUILD_CONFIG"]) if ENV["PROJECT_BUILD_CONFIG"] && File.exist?(ENV["PROJECT_BUILD_CONFIG"])\nend\n' >> "$f.tmp" && \
    mv "$f.tmp" "$f"; \
done

RUN . "${IDF_PATH}/export.sh"

# main/idf_component.yml は joltwallet/littlefs を "~=1.20.0"(レンジ指定)で
# 依存させているため、実際に解決されるパッチバージョンは実行時のESP Component
# Registryの状態次第で変わりうる(1.20.0〜1.20.4 の間でimage-building-requirements.txt
# の中身、つまり後段でpip installされるlittlefs-pythonのバージョンが変わることを
# 確認済み)。バージョン解決そのものを不要にするため、Docker build時点で実在を
# 確認できた最新パッチ版(1.20.4、https://components.espressif.com/components/
# joltwallet/littlefs で確認)に固定してしまう。
RUN sed -i 's/joltwallet\/littlefs: "~=1.20.0"/joltwallet\/littlefs: "1.20.4"/' main/idf_component.yml

# main/CMakeLists.txt の littlefs_create_partition_image(joltwallet/esp_littlefs、
# storageパーティションのイメージ作成に使う)は、初回ビルド時にvenvを作って
# PyPIから littlefs-python をインストールする。ビルド実行時にネットワークが
# 不安定だとここでタイムアウトして失敗する(実際に発生した)。上でjoltwallet/littlefsを
# 1.20.4に固定したことで、image-building-requirements.txtの中身は
# littlefs-python==0.15.0 で一意に確定している(実際にv1.20.4のリポジトリで確認済み)。
# これをイメージビルド時に取得して /opt/pip-wheels に置いておき、
# PIP_NO_INDEX/PIP_FIND_LINKS で「常にこのローカルディレクトリだけを見る」よう
# コンテナ全体のpipに指示することで、ビルド実行時はPyPIへの通信自体を
# (バージョン解決の問い合わせも含めて)一切発生させないようにする。
#
# pip3(python3含む)はこのイメージだとentrypoint.sh(コンテナ起動時にのみ実行される)
# 経由でPATHに追加される、export.shが用意するESP-IDF専用のvenv
# (/opt/esp/python_env/idf5.5_py3.12_env)にしか無い。`docker build`のRUNは
# entrypointを経由しない生のシェルなので、同じRUN内で明示的にexport.shを
# sourceしないとpip3が見つからない(r2p2_shell_commandがidf.py/rakeの実行時に
# 毎回export.shをsourceしているのと同じ理由)。
RUN . "${IDF_PATH}/export.sh" > /dev/null && pip3 download littlefs-python==0.15.0 -d /opt/pip-wheels

ENV PIP_NO_INDEX=1
ENV PIP_FIND_LINKS=/opt/pip-wheels

WORKDIR /root

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# イメージをそのまま `docker run` した場合は本番相当(キャッシュ有効)。
# 開発時は bin/dev が RACK_ENV=development で上書きする(app.rb 参照)。
ENV RACK_ENV=production

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY app/ .
COPY projects/ /projects

EXPOSE 4567

CMD ["ruby", "app.rb", "-o", "0.0.0.0"]
