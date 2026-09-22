# PicoRuby/FemtoRuby ESP32 IDE

This is PicoRuby/FemtoRuby for ESP32 development environment.
This IDE can do as following

- Edit source codes(.c .h .rb) for mrbgem as a project
- Build image
- Install image to your device

## Setup

The app itself runs natively on your machine (Ruby). Docker is only used to run
`idf.py build` / `rake setup_xxx`, so it needs to be built once up front:

```bash
bundle install
docker build -t picoruby-esp32-ide-builder .
```

## Run

```bash
./bin/server
```

Open http://localhost:4567 . Projects live under `./projects` by default
(override with the `PROJECTS_ROOT` env var to use any directory on disk).

