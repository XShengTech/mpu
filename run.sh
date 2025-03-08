#!/bin/bash
set -eo pipefail

MODULE_NAME="mpu"
MODULE_FILE="mpu.ko"  # 修改为你的模块路径

# 彩色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [command]"
    echo "Commands:"
    echo "  install    - Install kernel module"
    echo "  uninstall  - Uninstall kernel module"
    echo "Environment:"
    echo "  REPLACE    - [true/false] Force replace existing module (default: false)"
}

is_module_loaded() {
    if lsmod | grep "${MODULE_NAME}"; then
        return 0  # 模块存在
    else
        return 1  # 模块不存在
    fi
}


check_module_file() {
    if [ ! -f "${MODULE_FILE}" ]; then
        echo -e "${RED}Error: Module file ${MODULE_FILE} not found!${NC}" >&2
        exit 3
    fi
}

install_module() {
    echo -e "${YELLOW}Attempting to install module...${NC}"
    if  insmod "${MODULE_FILE}"; then
        echo -e "${GREEN}Module installed successfully${NC}"
        return 0
    else
        echo -e "${RED}Failed to install module!${NC}" >&2
        return 2
    fi
}

uninstall_module() {
    echo -e "${YELLOW}Uninstalling module...${NC}"
    if  rmmod "${MODULE_NAME}"; then
        echo -e "${GREEN}Module uninstalled successfully${NC}"
        return 0
    else
        echo -e "${RED}Failed to uninstall module!${NC}" >&2
        return 1
    fi
}

handle_install() {
    check_module_file
    local replace="${REPLACE:-false}"
    local is_loaded=false

    if is_module_loaded; then
      is_loaded=true
      echo -e "Module status: ${GREEN}Loaded${NC}"
    else
      echo -e "Module status: ${YELLOW}Not loaded${NC}"
    fi

    case "${replace}" in
        true)
            if "${is_loaded}"; then
                echo -e "${YELLOW}REPLACE mode: Reinstalling module...${NC}"
                uninstall_module || return $?
            fi
            install_module
            ;;
        false)
            if ! "${is_loaded}"; then
                install_module
            else
                echo -e "${GREEN}Module already loaded and REPLACE=false. Skipping.${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Error: Invalid REPLACE value '${replace}'. Must be true/false.${NC}" >&2
            return 4
            ;;
    esac
}

case "$1" in
    install)
        handle_install
        ;;
    uninstall)
        uninstall_module
        ;;
    *)
        usage
        exit 1
        ;;
esac