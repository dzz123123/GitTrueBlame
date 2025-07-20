#!/bin/bash
#
# Git True Blame (v3.1) - 线性追溯单行代码的最早起源
#
# 工作原理:
# 1. 从一个起始提交开始，grep/blame 找到最早的嫌疑提交。
# 2. 检查该嫌疑提交的父提交是否包含字符串。
# 3. 如果包含，则以父提交为新起点，重复此过程，线性向历史回溯。
# 4. 如果不包含，则该嫌疑提交就是最终的起源。

set -e

# --- 全局变量和颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 脚本状态
ORIGINAL_BRANCH=""
ORIGINAL_COMMIT=""
STASH_CREATED=false
TEMP_BRANCH=""
SEARCH_STRING=""
VERBOSE=false

# 搜索控制
MAX_ITERATIONS=100

# --- 帮助与交互函数 ---
show_help() {
    echo -e "${YELLOW}用法: $0 [OPTIONS] [START_COMMIT]${NC}"
    echo ""
    echo "本脚本通过'线性追溯'的方式，高效地找到一个单行字符串的最早起源提交。"
    echo ""
    echo -e "${CYAN}选项:${NC}"
    echo "  -h, --help              显示此帮助信息"
    echo "  -v, --verbose           显示详细的追溯过程"
    echo "  -f, --force             强制执行（忽略工作区变更警告，自动stash）"
    echo "  --no-stash              不自动stash变更（有变更时直接失败）"
    echo "  --max-iterations N      设置最大回溯次数 (默认: ${MAX_ITERATIONS})"
    echo ""
    echo -e "${CYAN}参数:${NC}"
    echo "  START_COMMIT            起始提交哈希 (可选，默认为HEAD)"
}

# --- 环境管理与清理函数 ---
check_working_tree() {
    if ! git diff --quiet --exit-code; then
        echo -e "${YELLOW}检测到工作区有未提交的变更。${NC}" >&2
        git status --porcelain >&2
        return 1
    fi
    return 0
}

safe_stash() {
    local stash_message="true-blame-temp-stash-$(date +%s)"
    echo -e "${BLUE}正在暂存当前变更...${NC}"
    if git stash push -u -m "$stash_message" > /dev/null 2>&1; then STASH_CREATED=true; echo -e "${GREEN}变更已成功暂存。${NC}"; else echo -e "${RED}错误: 无法暂存变更。${NC}" >&2; exit 1; fi
}

restore_stash() {
    if [[ "$STASH_CREATED" == "true" ]]; then
        echo -e "${BLUE}正在恢复之前暂存的变更...${NC}"
        if git stash pop > /dev/null 2>&1; then echo -e "${GREEN}变更已恢复。${NC}"; else echo -e "${YELLOW}警告: 自动恢复stash失败。请手动运行 'git stash pop'。${NC}" >&2; fi
        STASH_CREATED=false
    fi
}

create_temp_branch() {
    TEMP_BRANCH="true-blame-temp-$(date +%s)-$$"
    if git checkout -b "$TEMP_BRANCH" > /dev/null 2>&1; then
        [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}创建并切换到临时分支: $TEMP_BRANCH${NC}"
    else
        echo -e "${RED}错误: 无法创建临时分支。${NC}" >&2; exit 1
    fi
}

cleanup() {
    local exit_code=$?
    [[ "$VERBOSE" == "true" ]] && echo -e "\n${MAGENTA}--- 开始清理 ---${NC}"
    if [[ -n "$ORIGINAL_BRANCH" ]]; then git checkout "$ORIGINAL_BRANCH" > /dev/null 2>&1 || git checkout "$ORIGINAL_COMMIT" > /dev/null 2>&1;
    elif [[ -n "$ORIGINAL_COMMIT" ]]; then git checkout "$ORIGINAL_COMMIT" > /dev/null 2>&1; fi
    if [[ -n "$TEMP_BRANCH" ]]; then
        if git branch -D "$TEMP_BRANCH" > /dev/null 2>&1; then [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}已删除临时分支: $TEMP_BRANCH${NC}"; fi
        TEMP_BRANCH=""
    fi
    restore_stash
    [[ "$VERBOSE" == "true" ]] && echo -e "${MAGENTA}--- 清理完成 ---${NC}"
    exit $exit_code
}

# --- 核心搜索逻辑 ---

# 检查在给定的提交中是否存在字符串
string_exists_in_commit() {
    local commit_hash="$1"
    git -c core.pager=cat grep -Fq -- "$SEARCH_STRING" "$commit_hash" -- . 2>/dev/null
}

find_true_origin() {
    local current_commit_to_check="$1"
    local iteration=0

    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        iteration=$((iteration + 1))
        
        [[ "$VERBOSE" == "true" ]] && echo -e "\n${YELLOW}--- 第 ${iteration} 次迭代 ---${NC}"
        [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}检查提交:${NC} $(git show -s --oneline --no-color $current_commit_to_check)"

        # 切换到当前检查的提交
        git checkout --quiet "$current_commit_to_check"

        # 1. 查找所有出现位置并收集Blame结果
        local occurrences
        occurrences=$(git -c core.pager=cat grep -Fn -- "$SEARCH_STRING" 2>/dev/null || true)
        
        if [[ -z "$occurrences" ]]; then
            echo -e "${RED}错误: 在追溯过程中，字符串在提交 ${current_commit_to_check:0:7} 消失了。这不应该发生。${NC}"
            return 1
        fi
        
        declare -A blame_commits_map
        while IFS= read -r line; do
            local file_path=$(echo "$line" | cut -d: -f1)
            local line_num=$(echo "$line" | cut -d: -f2)
            local blame_commit=$(git blame -L "${line_num},${line_num}" --porcelain -- "$file_path" 2>/dev/null | head -n1 | cut -d' ' -f1 || true)
            if [[ -n "$blame_commit" ]]; then
                blame_commits_map[$blame_commit]=1
            fi
        done <<< "$occurrences"

        if [[ ${#blame_commits_map[@]} -eq 0 ]]; then
            echo -e "${RED}错误: 找到字符串，但无法 blame 到任何提交。${NC}" >&2
            return 1
        fi
        
        local blame_commits=("${!blame_commits_map[@]}")
        [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}Blame结果指向 ${#blame_commits[@]} 个提交:${NC} $(for c in "${blame_commits[@]}"; do echo -n "${c:0:7} "; done)"

        # 2. 找到这些提交中最早的那一个
        local earliest_blame_commit
        earliest_blame_commit=$(git rev-list --reverse --date-order --no-walk "${blame_commits[@]}" 2>/dev/null | head -n 1)

        if [[ -z "$earliest_blame_commit" ]]; then
            echo -e "${RED}错误: 无法确定Blame结果中最早的提交。${NC}" >&2
            return 1
        fi
        [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}最早的嫌疑提交:${NC} ${earliest_blame_commit:0:7}"

        # 3. 检查最早嫌疑提交的父提交
        local parents=($(git rev-parse "${earliest_blame_commit}^@" 2>/dev/null || true))
        
        if [[ ${#parents[@]} -eq 0 ]]; then
            [[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}这是根提交，没有父提交可检查。判定为起源！${NC}"
            echo -e "\n${GREEN}找到最终起源提交:${NC}"
            git --no-pager log -1 --color=always --pretty="format:%C(yellow)%H%n%C(green)Author: %an <%ae>%nDate:   %ad%n%n%w(72,1,2)%s%n%b" "$earliest_blame_commit"
            return 0
        fi

        local found_in_parent=false
        local next_commit_to_check=""
        for parent_commit in "${parents[@]}"; do
             if string_exists_in_commit "$parent_commit"; then
                [[ "$VERBOSE" == "true" ]] && echo -e "${MAGENTA}字符串存在于父提交 ${parent_commit:0:7}，以此为新起点继续追溯...${NC}"
                found_in_parent=true
                next_commit_to_check="$parent_commit"
                break
             else
                [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}父提交 ${parent_commit:0:7} 不含该字符串。${NC}"
             fi
        done

        if [[ "$found_in_parent" == "true" ]]; then
            current_commit_to_check="$next_commit_to_check"
        else
             [[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}所有父提交均不含此字符串。判定为起源！${NC}"
             echo -e "\n${GREEN}找到最终起源提交:${NC}"
             git --no-pager log -1 --color=always --pretty="format:%C(yellow)%H%n%C(green)Author: %an <%ae>%nDate:   %ad%n%n%w(72,1,2)%s%n%b" "$earliest_blame_commit"
             return 0
        fi
    done

    echo -e "${RED}错误: 已达到最大迭代次数 (${MAX_ITERATIONS})，搜索中止。${NC}"
    return 1
}

# --- 主程序 ---
main() {
    local START_COMMIT="HEAD"
    local positional_args=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -f|--force) FORCE=true; shift ;;
            --no-stash) NO_STASH=true; shift ;;
            --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
            -*) echo -e "${RED}未知选项: $1${NC}" >&2; show_help; exit 1 ;;
            *) positional_args+=("$1"); shift ;;
        esac
    done
    [[ ${#positional_args[@]} -gt 0 ]] && START_COMMIT="${positional_args[0]}"

    # --- 环境验证与准备 ---
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then echo -e "${RED}错误: 当前目录不是一个Git仓库。${NC}" >&2; exit 1; fi
    
    # 【新增】检查仓库是否为空
    if ! git rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
        echo -e "${RED}错误: Git仓库中没有任何提交。无法进行追溯。${NC}" >&2
        exit 1
    fi
    
    # 【修正】修正了重定向语法错误 (2>&1)
    if ! git rev-parse --verify "${START_COMMIT}^{commit}" > /dev/null 2>&1; then 
        echo -e "${RED}错误: 无法将起始点 '${START_COMMIT}' 解析为一个有效的提交。${NC}" >&2; 
        exit 1; 
    fi

    ORIGINAL_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    ORIGINAL_COMMIT=$(git rev-parse HEAD)
    trap cleanup EXIT INT TERM
    if ! check_working_tree; then
        if [[ "$NO_STASH" == "true" ]]; then echo -e "${RED}错误: 工作区有变更且设置了 --no-stash。${NC}" >&2; exit 1; fi
        if [[ "$FORCE" == "false" ]]; then
            read -p "是否自动暂存变更并在结束后恢复？(y/N) " -n 1 -r; echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "操作已取消。"; exit 0; fi
        fi
        safe_stash
    fi
    echo -e "${BLUE}请输入要搜索的单行代码 (输入后按Enter):${NC}"
    read -r SEARCH_STRING
    if [[ -z "$SEARCH_STRING" ]]; then echo -e "${RED}错误: 搜索内容不能为空。${NC}" >&2; exit 1; fi
    if [[ "$SEARCH_STRING" == *$'\n'* ]]; then echo -e "${RED}错误: 本脚本仅支持单行字符串搜索。${NC}" >&2; exit 1; fi
    
    # --- 执行搜索 ---
    echo -e "\n${MAGENTA}======================================================${NC}"
    echo -e "${YELLOW}开始线性追溯字符串的真正起源...${NC}"
    echo -e "${CYAN}搜索内容:${NC} '$SEARCH_STRING'"
    echo -e "${CYAN}起始提交:${NC} $(git rev-parse --short $START_COMMIT)"
    echo -e "${MAGENTA}======================================================${NC}"
    create_temp_branch
    
    find_true_origin "$START_COMMIT"
    local search_result=$?
    
    if [[ $search_result -ne 0 ]]; then
        echo -e "\n${RED}未能找到起源提交。${NC}" >&2
        exit 1
    fi
}

main "$@"
