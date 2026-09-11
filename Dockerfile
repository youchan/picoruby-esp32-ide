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

RUN git clone https://github.com/rbenv/rbenv.git "${RBENV_ROOT}"
RUN git clone https://github.com/rbenv/ruby-build.git "$(rbenv root)"/plugins/ruby-build
RUN rbenv init

RUN rbenv install 4.0.6
RUN rbenv global 4.0.6

COPY R2P2-ESP32/ /R2P2-ESP32

WORKDIR /R2P2-ESP32
RUN . "${IDF_PATH}/export.sh" && rake setup_esp32

WORKDIR /root

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY app/ .
COPY projects/ /projects

EXPOSE 4567

CMD ["ruby", "app.rb", "-o", "0.0.0.0"]
