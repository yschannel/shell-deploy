#!/usr/bin/env bash

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1

usage() {
    printf '用法：bash deploy.sh {setup|start|stop|restart|status|logs}\n'
}

[[ $# == 1 ]] || { usage >&2; exit 2; }
case $1 in
    setup)
        source "$PROJECT_ROOT/scripts/common.sh" || exit 1
        source "$PROJECT_ROOT/scripts/setup.sh" || exit 1
        if declare -F setup_project >/dev/null; then
            setup_project
        else
            printf 'setup 模块尚未实现，请等待 A 完成 setup_project。\n' >&2
            exit 1
        fi
        ;;
    start|stop|restart|status|logs)
        source "$PROJECT_ROOT/scripts/service.sh" || exit 1
        case $1 in
            start) start_service ;;
            stop) stop_service ;;
            restart) restart_service ;;
            status) status_service ;;
            logs) show_logs ;;
        esac
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
