#!/bin/bash
set -eo pipefail

MODULE_NAME="mpu"
MODULE_FILE="mpu.ko"
MODULE_PATH="$(pwd)/${MODULE_FILE}"  # 使用绝对路径

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
    echo "  REPLACE        - [true/false] Force replace existing module (default: false)"
    echo "  AUTO_LOAD      - [true/false] Configure module to load at boot (default: true)"
    echo "  MODULE_OPTIONS - Optional parameters to pass to the module at load time"
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

install_ () {
  apt-get update && apt-get install -y build-essential && apt-get install -y linux-headers-$(uname -r) kmod
}

build_ko(){
  make
}

install_module() {
    echo -e "${YELLOW}Attempting to install module...${NC}"
    
    # 确保模块目录存在
    local modules_dir="/lib/modules/$(uname -r)/extra"
    mkdir -p "${modules_dir}"
    
    # 复制模块到标准位置
    echo -e "${YELLOW}Copying module to ${modules_dir}...${NC}"
    cp "${MODULE_FILE}" "${modules_dir}/${MODULE_NAME}.ko"
    
    # 运行 depmod 以更新模块依赖关系
    echo -e "${YELLOW}Updating module dependencies...${NC}"
    depmod -a
    
    # 加载模块
    echo -e "${YELLOW}Loading module with modprobe...${NC}"
    if modprobe "${MODULE_NAME}"; then
        echo -e "${GREEN}Module loaded successfully${NC}"
        
        # 配置开机自动加载
        echo -e "${YELLOW}Setting up module to load at boot time...${NC}"
        if ! grep -q "^${MODULE_NAME}" /etc/modules; then
            echo "${MODULE_NAME}" >> /etc/modules
            echo -e "${GREEN}Module will be loaded automatically at boot${NC}"
        else
            echo -e "${GREEN}Module already configured to load at boot${NC}"
        fi
        
        return 0
    else
        echo -e "${RED}Failed to load module with modprobe!${NC}" >&2
        
        # 尝试回退到 insmod
        echo -e "${YELLOW}Falling back to insmod...${NC}"
        if insmod "${MODULE_FILE}"; then
            echo -e "${GREEN}Module installed with insmod (won't auto-load at boot)${NC}"
            echo -e "${YELLOW}To enable auto-load at boot, fix modprobe issues${NC}"
            return 0
        else
            echo -e "${RED}All installation methods failed!${NC}" >&2
            return 2
        fi
    fi
}

uninstall_module() {
    echo -e "${YELLOW}Uninstalling module...${NC}"
    
    # 卸载模块
    if modprobe -r "${MODULE_NAME}" || rmmod "${MODULE_NAME}"; then
        echo -e "${GREEN}Module uninstalled successfully${NC}"
        
        # 从开机自动加载配置中移除
        if grep -q "^${MODULE_NAME}" /etc/modules; then
            echo -e "${YELLOW}Removing from boot configuration...${NC}"
            sed -i "/^${MODULE_NAME}/d" /etc/modules
            echo -e "${GREEN}Module removed from boot configuration${NC}"
        fi
        
        # 从模块目录中删除
        local module_path="/lib/modules/$(uname -r)/extra/${MODULE_NAME}.ko"
        if [ -f "${module_path}" ]; then
            echo -e "${YELLOW}Removing module file from system...${NC}"
            rm "${module_path}"
            depmod -a  # 更新依赖
            echo -e "${GREEN}Module file removed${NC}"
        fi
        
        return 0
    else
        echo -e "${RED}Failed to uninstall module!${NC}" >&2
        return 1
    fi
}

setup_modprobe_config() {
    local modname="$1"
    local module_options="${2:-}"  # 可选的模块参数
    local conf_file="/etc/modprobe.d/${modname}.conf"
    
    echo -e "${YELLOW}Setting up modprobe configuration...${NC}"
    
    # 创建 modprobe 配置文件
    echo "# Configuration for ${modname} module" > "${conf_file}"
    
    # 如果有提供模块选项，添加它们
    if [ -n "${module_options}" ]; then
        echo "options ${modname} ${module_options}" >> "${conf_file}"
    fi
    
    echo -e "${GREEN}Created modprobe configuration at ${conf_file}${NC}"
}

handle_install() {
    install_
    local replace="${REPLACE:-false}"
    local auto_load="${AUTO_LOAD:-true}"  # 新增自动加载选项
    local module_options="${MODULE_OPTIONS:-}"  # 新增模块选项
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
            build_ko
            install_module
            ;;
        false)
            if ! "${is_loaded}"; then
                build_ko
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
    
    # 设置 modprobe 配置（如果指定了自动加载）
    if [ "${auto_load}" = "true" ] && [ -n "${module_options}" ]; then
        setup_modprobe_config "${MODULE_NAME}" "${module_options}"
    fi
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