#!/usr/bin/env bash

main(){
    local project_root

    project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" \
        || return 1

    source "$project_root/scripts/common.sh" || return 1
    source "$project_root/scripts/setup.sh" || return 1

    case "${1:-}" in
        setup)
            setup_project
            ;;
        *)
            printf '用法:bash deploy.sh setup\n' >&2
            return 1
            ;;
    esac
}

main "$@"
