#!/usr/bin/env bash

#根据本文件的位置，确定项目根目录。
#即使用户从其他目录调用脚本，路径也不会发生变化。
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || return 1

log_info() {
    printf '[信息] %s\n' "$*"
}

log_success() {
    printf '[完成] %s\n' "$*"
}

log_error() {
    printf '[错误] %s\n' "$*" >&2
}
