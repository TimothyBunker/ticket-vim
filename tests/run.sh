#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec "${TIM_NVIM:-nvim}" --headless -u NONE -i NONE -l tests/run.lua
