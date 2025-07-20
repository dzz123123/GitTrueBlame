#!/bin/bash

# Git True Blame - 找到字符串真正的第一次提交
# 用法: git-true-blame.sh [起始commit] [文件路径]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# 全局变量
ORIGINAL_BRANCH=""
ORIGINAL_COMMIT=""
STASH_CREATED=false
STASH_HAD_STAGED=false
TEMP_BRANCH=""
MAX_OCCURRENCES=10
MAX_FILES=20
SEARCH_MODE=""  # "legacy", "exact", "exact_trim"

show_help() {
    echo "用法: $0 [OPTIONS] [START_COMMIT] [FILE_PATH]"
    echo ""
    echo "选项:"
    echo "  -h, --help              显示帮助信息"
    echo "  -v, --verbose           显示详细过程"
    echo "  -f, --force             强制执行（忽略工作区变更警告）"
    echo "  --no-stash              不自动stash变更（有变更时直接失败）"
    echo "  --max-occurrences N     设置最大出现次数阈值（默认10）"
    echo "  --max-files N           设置最大文件数阈值（默认20）"
    echo "  --ignore-duplicates     忽略重复检查，强制继续搜索"
    echo ""
    echo "参数:"
    echo "  START_COMMIT            起始提交哈希(可选，默认为HEAD)"
    echo "  FILE_PATH               文件路径(可选，用于缩小搜索范围)"
    echo ""
    echo "多行搜索模式:"
    echo "- 传统模式: 匹配到任意一行即算找到（兼容旧版本）"
    echo "- 精确模式: 必须完整匹配整个多行字符串"
    echo "- 精确+Trim模式: 精确匹配但忽略行首尾空白字符"
}

# 询问用户选择多行搜索模式
choose_multiline_mode() {
    local search_string="$1"
    
    echo -e "${MAGENTA}=================================${NC}"
    echo -e "${YELLOW}检测到多行搜索字符串！${NC}"
    echo ""
    echo -e "${CYAN}搜索内容:${NC}"
    echo "$search_string" | sed 's/^/  /'
    echo ""
    echo -e "${CYAN}请选择匹配模式:${NC}"
    echo "1. 传统模式 - 匹配到任意一行即算找到（兼容旧版本）"
    echo "2. 精确模式 - 必须完整匹配整个多行字符串"
    echo "3. 精确+Trim模式 - 精确匹配但忽略行首尾空白字符"
    echo ""
    echo -e "${YELLOW}说明:${NC}"
    echo -e "${CYAN}传统模式:${NC} 文件中只要有任意一行包含搜索内容的任意一行就匹配"
    echo -e "${CYAN}精确模式:${NC} 文件中必须有连续的行完全匹配搜索内容的所有行"
    echo -e "${CYAN}精确+Trim:${NC} 与精确模式相同，但忽略每行的前后空白字符"
    echo ""
    echo -e "${MAGENTA}=================================${NC}"
    echo -n "请选择 [1/2/3]: "
    
    read -r choice
    case $choice in
        1|"")
            SEARCH_MODE="legacy"
            echo -e "${BLUE}已选择: 传统模式${NC}"
            ;;
        2)
            SEARCH_MODE="exact"
            echo -e "${BLUE}已选择: 精确模式${NC}"
            ;;
        3)
            SEARCH_MODE="exact_trim"
            echo -e "${BLUE}已选择: 精确+Trim模式${NC}"
            ;;
        *)
            echo -e "${RED}无效选择，使用默认的传统模式${NC}"
            SEARCH_MODE="legacy"
            ;;
    esac
    echo ""
}

# 检查字符串在当前提交中的出现情况
check_occurrences() {
    local search_string="$1"
    local file_path="$2"
    local commit="$3"
    
    local total_occurrences=0
    local file_count=0
    local files_with_matches=()
    
    if [[ -n "$file_path" ]]; then
        if [[ -f "$file_path" ]]; then
            local count=$(search_in_file "$search_string" "$file_path")
            if [[ $count -gt 0 ]]; then
                total_occurrences=$count
                file_count=1
                files_with_matches=("$file_path")
            fi
        fi
    else
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                local count=$(search_in_file "$search_string" "$file")
                if [[ $count -gt 0 ]]; then
                    total_occurrences=$((total_occurrences + count))
                    file_count=$((file_count + 1))
                    files_with_matches+=("$file:$count")
                fi
            fi
        done < <(git ls-files 2>/dev/null)
    fi
    
    echo "$total_occurrences:$file_count:$(IFS=';'; echo "${files_with_matches[*]}")"
}

# 根据搜索模式在文件中搜索并返回出现次数
search_in_file() {
    local search_string="$1"
    local file="$2"
    
    case "$SEARCH_MODE" in
        "legacy")
            # 传统模式：匹配任意一行
            if grep -Fq "$search_string" "$file" 2>/dev/null; then
                grep -Fc "$search_string" "$file" 2>/dev/null || echo "1"
            else
                echo "0"
            fi
            ;;
        "exact")
            # 精确模式：完整匹配多行字符串
            if exact_multiline_search "$search_string" "$file" false; then
                echo "1"
            else
                echo "0"
            fi
            ;;
        "exact_trim")
            # 精确+Trim模式：完整匹配但忽略空白
            if exact_multiline_search "$search_string" "$file" true; then
                echo "1"  
            else
                echo "0"
            fi
            ;;
        *)
            echo "0"
            ;;
    esac
}

exact_multiline_search() {
    local search_string="$1"; local file="$2"; local trim_mode="$3"
    if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: ===== 开始精确搜索 ===== 文件: $file, Trim模式: $trim_mode" >&2; fi
    local search_lines=(); local line_num=0
    while IFS= read -r line; do line_num=$((line_num + 1)); if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 搜索第${line_num}行原始: [${line}]" >&2; fi; if [[ "$trim_mode" == "true" ]]; then line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); fi; if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 搜索第${line_num}行处理后: [${line}]" >&2; fi; search_lines+=("$line"); done <<< "$search_string"
    local search_line_count=${#search_lines[@]}
    if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 搜索行数: $search_line_count, 文件存在: $(test -f "$file" && echo "YES" || echo "NO"), 大小: $(wc -c < "$file" 2>/dev/null || echo "ERROR"), wc行数: $(wc -l < "$file" 2>/dev/null || echo "ERROR")" >&2; cat -n "$file" | sed 's/^/DEBUG_TRIM:   /' >&2; echo "DEBUG_TRIM: 开始while循环读取..." >&2; fi
    local file_lines=(); line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do line_num=$((line_num + 1)); if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 文件第${line_num}行原始: [${line}]" >&2; fi; if [[ "$trim_mode" == "true" ]]; then line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); fi; if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 文件第${line_num}行处理后: [${line}]" >&2; fi; file_lines+=("$line"); done < "$file"
    local file_line_count=${#file_lines[@]}
    if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: while循环读取完成，实际读取行数: $file_line_count" >&2; for ((i=0; i<${#file_lines[@]}; i++)); do echo "DEBUG_TRIM:   数组[$i]: [${file_lines[$i]}]" >&2; done; fi
    if [[ $search_line_count -gt $file_line_count ]]; then if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 搜索行数($search_line_count)大于文件行数($file_line_count)，不匹配" >&2; fi; return 1; fi
    for ((i = 0; i <= file_line_count - search_line_count; i++)); do if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: 尝试从文件第$((i+1))行开始匹配..." >&2; fi; local match=true; for ((j = 0; j < search_line_count; j++)); do local file_line="${file_lines[$((i + j))]}"; local search_line="${search_lines[$j]}"; if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM:   比较 文件[${file_line}] vs 搜索[${search_line}]" >&2; fi; if [[ "$file_line" != "$search_line" ]]; then if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM:   不匹配！" >&2; fi; match=false; break; else if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM:   匹配！" >&2; fi; fi; done; if [[ "$match" == "true" ]]; then if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: ===== 找到完整匹配！=====" >&2; fi; return 0; fi; done
    if [[ "${DEBUG_TRIM:-false}" == "true" ]]; then echo "DEBUG_TRIM: ===== 未找到匹配 =====" >&2; fi; return 1
}

show_occurrence_details() {
    local search_string="$1"
    local commit="$2"
    local total_occurrences="$3"
    local file_count="$4"
    local files_info="$5"
    
    echo -e "${MAGENTA}=================================${NC}"
    echo -e "${YELLOW}检测到字符串可能过于常见！${NC}"
    echo ""
    echo -e "${CYAN}当前检查的提交信息:${NC}"
    git log -1 --pretty=format:"  哈希: %H%n  作者: %an <%ae>%n  日期: %ad%n  标题: %s" --date=format:"%Y-%m-%d %H:%M:%S" "$commit"
    echo ""
    echo ""
    echo -e "${CYAN}搜索模式: ${SEARCH_MODE}${NC}"
    echo -e "${CYAN}搜索的字符串:${NC}"
    echo "$search_string" | sed 's/^/  /'
    echo ""
    echo -e "${CYAN}出现统计:${NC}"
    echo -e "  总出现次数: ${YELLOW}$total_occurrences${NC}"
    echo -e "  涉及文件数: ${YELLOW}$file_count${NC}"
    echo ""
    echo -e "${MAGENTA}=================================${NC}"
}

handle_multiple_occurrences() {
    local search_string="$1"
    local commit="$2"
    local total_occurrences="$3"
    local file_count="$4"
    local files_info="$5"
    
    show_occurrence_details "$search_string" "$commit" "$total_occurrences" "$file_count" "$files_info"
    
    echo ""
    echo -e "${YELLOW}由于字符串出现次数较多，继续溯源可能会导致性能问题。${NC}"
    echo "1. 终止搜索（推荐）"
    echo "2. 强制继续搜索"
    echo -n "请选择 [1/2]: "
    
    read -r choice
    case $choice in
        1|"")
            echo -e "${BLUE}搜索已终止${NC}"
            return 1
            ;;
        2)
            echo -e "${YELLOW}强制继续搜索...${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}无效选择，终止搜索${NC}"
            return 1
            ;;
    esac
}

check_working_tree() {
    local has_staged_changes=false
    local has_unstaged_changes=false
    
    if ! git diff --cached --quiet 2>/dev/null; then
        has_staged_changes=true
    fi
    
    if ! git diff --quiet 2>/dev/null; then
        has_unstaged_changes=true
    fi
    
    if [[ "$has_staged_changes" == "true" ]] || [[ "$has_unstaged_changes" == "true" ]]; then
        echo -e "${YELLOW}检测到工作区有未提交的变更:${NC}"
        
        if [[ "$has_staged_changes" == "true" ]]; then
            echo -e "${CYAN}  - 已暂存的变更:${NC}"
            git diff --cached --name-status | sed 's/^/    /'
            STASH_HAD_STAGED=true
        fi
        
        if [[ "$has_unstaged_changes" == "true" ]]; then
            echo -e "${CYAN}  - 未暂存的变更:${NC}"
            git diff --name-status | sed 's/^/    /'
        fi
        
        return 1
    fi
    
    return 0
}

safe_stash() {
    local stash_message="true-blame-temp-stash-$(date +%s)"
    
    echo -e "${YELLOW}正在暂存当前变更...${NC}"
    
    if git stash push -u -m "$stash_message" > /dev/null 2>&1; then
        STASH_CREATED=true
        echo -e "${GREEN}变更已暂存（stash message: $stash_message）${NC}"
        return 0
    else
        echo -e "${RED}错误: 无法暂存当前变更${NC}" >&2
        return 1
    fi
}

restore_stash() {
    if [[ "$STASH_CREATED" == "true" ]]; then
        echo -e "${YELLOW}正在恢复之前的变更...${NC}"
        
        if git stash list | grep -q "true-blame-temp-stash"; then
            if [[ "$STASH_HAD_STAGED" == "true" ]]; then
                if git stash pop --index > /dev/null 2>&1; then
                    echo -e "${GREEN}变更已恢复（保持原有的暂存状态）${NC}"
                else
                    if git stash pop > /dev/null 2>&1; then
                        echo -e "${YELLOW}变更已恢复，但暂存状态可能有变化${NC}"
                        echo -e "${CYAN}提示: 原本暂存的文件现在可能需要重新 git add${NC}"
                    else
                        echo -e "${YELLOW}警告: 自动恢复stash失败，请手动运行 'git stash pop'${NC}" >&2
                    fi
                fi
            else
                if git stash pop > /dev/null 2>&1; then
                    echo -e "${GREEN}变更已恢复${NC}"
                else
                    echo -e "${YELLOW}警告: 自动恢复stash失败，请手动运行 'git stash pop'${NC}" >&2
                fi
            fi
            STASH_CREATED=false
        else
            echo -e "${YELLOW}警告: 找不到对应的stash，可能已被手动处理${NC}" >&2
            STASH_CREATED=false
        fi
    fi
}

create_temp_branch() {
    TEMP_BRANCH="true-blame-temp-$(date +%s)-$$"
    
    if git checkout -b "$TEMP_BRANCH" > /dev/null 2>&1; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "${BLUE}创建临时分支: $TEMP_BRANCH${NC}"
        fi
        return 0
    else
        echo -e "${RED}错误: 无法创建临时分支${NC}" >&2
        return 1
    fi
}

cleanup_temp_branch() {
    if [[ -n "$TEMP_BRANCH" ]]; then
        if [[ -n "$ORIGINAL_BRANCH" ]]; then
            git checkout "$ORIGINAL_BRANCH" > /dev/null 2>&1 || \
            git checkout "$ORIGINAL_COMMIT" > /dev/null 2>&1
        else
            git checkout "$ORIGINAL_COMMIT" > /dev/null 2>&1
        fi
        
        if git branch -D "$TEMP_BRANCH" > /dev/null 2>&1; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${BLUE}已删除临时分支: $TEMP_BRANCH${NC}"
            fi
        fi
        TEMP_BRANCH=""
    fi
}

cleanup() {
    local exit_code=$?
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}正在清理...${NC}"
    fi
    
    cleanup_temp_branch
    restore_stash
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${GREEN}清理完成${NC}"
    fi
    
    exit $exit_code
}

# 解析命令行参数
VERBOSE=false
FORCE=false
NO_STASH=false
IGNORE_DUPLICATES=false
START_COMMIT="HEAD"
FILE_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        --no-stash) NO_STASH=true; shift ;;
        --max-occurrences) MAX_OCCURRENCES="$2"; shift 2 ;;
        --max-files) MAX_FILES="$2"; shift 2 ;;
        --ignore-duplicates) IGNORE_DUPLICATES=true; shift ;;
        -*) echo "未知选项: $1" >&2; exit 1 ;;
        *)
            if [[ "$START_COMMIT" == "HEAD" ]]; then
                START_COMMIT="$1"
            elif [[ -z "$FILE_PATH" ]]; then
                FILE_PATH="$1"
            else
                echo "错误: 参数过多" >&2; exit 1
            fi
            shift ;;
    esac
done

# 验证参数
if ! [[ "$MAX_OCCURRENCES" =~ ^[0-9]+$ ]] || [[ "$MAX_OCCURRENCES" -le 0 ]]; then
    echo -e "${RED}错误: --max-occurrences 必须是正整数${NC}" >&2
    exit 1
fi

if ! [[ "$MAX_FILES" =~ ^[0-9]+$ ]] || [[ "$MAX_FILES" -le 0 ]]; then
    echo -e "${RED}错误: --max-files 必须是正整数${NC}" >&2
    exit 1
fi

# 验证是否在git仓库中
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}错误: 当前目录不是git仓库${NC}" >&2
    exit 1
fi

# 验证起始提交是否存在
if ! git rev-parse --verify "$START_COMMIT" > /dev/null 2>&1; then
    echo -e "${RED}错误: 提交 '$START_COMMIT' 不存在${NC}" >&2
    exit 1
fi

# 保存当前状态
ORIGINAL_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
ORIGINAL_COMMIT=$(git rev-parse HEAD)

# 设置trap进行清理
trap cleanup EXIT INT TERM

# 检查工作区状态并处理
if ! check_working_tree; then
    if [[ "$NO_STASH" == "true" ]]; then
        echo -e "${RED}错误: 工作区有未提交的变更${NC}" >&2
        exit 1
    fi
    
    if [[ "$FORCE" == "false" ]]; then
        echo ""
        echo -e "${YELLOW}选择处理方式:${NC}"
        echo "1. 自动stash变更，搜索完成后恢复 (推荐)"
        echo "2. 取消操作，手动处理变更"
        echo -n "请选择 [1/2]: "
        read -r choice
        
        case $choice in
            1|"") ;;
            2) echo -e "${BLUE}操作已取消${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择，操作已取消${NC}"; exit 1 ;;
        esac
    fi
    
    if ! safe_stash; then
        exit 1
    fi
fi

echo ""

# 读取要搜索的字符串
echo -e "${BLUE}请输入要搜索的代码内容（支持多行，输入完成后按 Ctrl+D）:${NC}"
SEARCH_STRING=$(cat)

if [[ -z "$SEARCH_STRING" ]]; then
    echo -e "${RED}错误: 搜索内容不能为空${NC}" >&2
    exit 1
fi

# 检查是否为多行字符串并让用户选择搜索模式
if [[ "$SEARCH_STRING" == *$'\n'* ]]; then
    choose_multiline_mode "$SEARCH_STRING"
else
    SEARCH_MODE="legacy"  # 单行字符串使用传统模式
fi

# 预检查搜索字符串的复杂度
if [[ ${#SEARCH_STRING} -lt 5 ]] && [[ "$IGNORE_DUPLICATES" == "false" ]]; then
    echo -e "${YELLOW}警告: 搜索字符串过短（少于5个字符），可能会导致大量匹配${NC}"
    echo -e "${CYAN}建议使用更具体的搜索字符串或添加 --ignore-duplicates 选项${NC}"
fi

echo -e "${YELLOW}开始搜索...${NC}"
if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}搜索内容: $(echo "$SEARCH_STRING" | head -1)$([ $(echo "$SEARCH_STRING" | wc -l) -gt 1 ] && echo "... (多行)")${NC}"
    echo -e "${BLUE}搜索模式: $SEARCH_MODE${NC}"
    echo -e "${BLUE}起始提交: $START_COMMIT${NC}"
    if [[ -n "$FILE_PATH" ]]; then
        echo -e "${BLUE}文件路径: $FILE_PATH${NC}"
    fi
    echo "----------------------------------------"
fi

# 创建临时分支进行安全操作
if ! create_temp_branch; then
    exit 1
fi

# 搜索函数
search_in_commit() {
    local commit="$1"
    
    # 切换到指定提交
    if ! git checkout "$commit" > /dev/null 2>&1; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "${RED}警告: 无法切换到提交 $commit${NC}" >&2
        fi
        return 1
    fi
    
    # 在指定提交中搜索字符串
    if [[ -n "$FILE_PATH" ]]; then
        if [[ -f "$FILE_PATH" ]]; then
            local count=$(search_in_file "$SEARCH_STRING" "$FILE_PATH")
            [[ $count -gt 0 ]]
        else
            return 1
        fi
    else
        # 在所有跟踪的文件中搜索
        local found=false
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                local count=$(search_in_file "$SEARCH_STRING" "$file")
                if [[ $count -gt 0 ]]; then
                    found=true
                    break
                fi
            fi
        done < <(git ls-files 2>/dev/null)
        $found
    fi
}

# 获取父提交
get_parent_commits() {
    local commit="$1"
    local parents_line=$(git rev-list --parents -n 1 "$commit" 2>/dev/null || echo "")
    local parts=($parents_line)
    
    if [[ ${#parts[@]} -le 1 ]]; then
        echo ""
        return
    fi
    
    for (( i=1; i<${#parts[@]}; i++ )); do
        echo "${parts[$i]}"
    done
}

# 主搜索逻辑
find_true_origin() {
    local current_commit="$START_COMMIT"
    local found_commits=()
    local checked_commits=0
    local visited_commits=()
    local max_depth=1000
    
    while true; do
        checked_commits=$((checked_commits + 1))
        
        # 检查是否已经访问过这个提交（防止循环）
        for visited in "${visited_commits[@]}"; do
            if [[ "$visited" == "$current_commit" ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    echo -e "${YELLOW}检测到已访问过的提交，停止搜索以避免循环${NC}"
                fi
                break 2
            fi
        done
        
        # 添加到已访问列表
        visited_commits+=("$current_commit")
        
        if [[ $checked_commits -gt $max_depth ]]; then
            echo -e "${RED}警告: 已达到最大搜索深度 ($max_depth)，停止搜索${NC}"
            break
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "${YELLOW}检查提交 ($checked_commits): $(git log -1 --oneline "$current_commit" 2>/dev/null || echo "$current_commit")${NC}"
        fi
        
        # 在当前提交中搜索
        if search_in_commit "$current_commit"; then
            # 检查出现次数（如果不忽略重复检查）
            if [[ "$IGNORE_DUPLICATES" == "false" ]]; then
                local occurrence_result=$(check_occurrences "$SEARCH_STRING" "$FILE_PATH" "$current_commit")
                local occurrences=$(echo "$occurrence_result" | cut -d: -f1)
                local file_count=$(echo "$occurrence_result" | cut -d: -f2)
                local files_info=$(echo "$occurrence_result" | cut -d: -f3-)
                
                if [[ "$VERBOSE" == "true" ]]; then
                    echo -e "${CYAN}  出现次数: $occurrences, 文件数: $file_count${NC}"
                fi
                
                # 检查是否超过阈值
                if [[ $occurrences -gt $MAX_OCCURRENCES ]] || [[ $file_count -gt $MAX_FILES ]]; then
                    if ! handle_multiple_occurrences "$SEARCH_STRING" "$current_commit" "$occurrences" "$file_count" "$files_info"; then
                        return 1
                    fi
                fi
            fi
            
            # 关键修复：将符号引用转换为实际的提交哈希
            local actual_commit=$(git rev-parse "$current_commit" 2>/dev/null || echo "$current_commit")
            found_commits+=("$actual_commit")
            
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${GREEN}✓ 在提交中找到目标字符串${NC}"
            fi
            
            # 获取父提交
            local parent_commits=($(get_parent_commits "$current_commit"))
            
            if [[ ${#parent_commits[@]} -eq 0 ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    echo -e "${BLUE}到达根提交，搜索完成${NC}"
                fi
                break
            elif [[ ${#parent_commits[@]} -eq 1 ]]; then
                current_commit="${parent_commits[0]}"
                if [[ "$VERBOSE" == "true" ]]; then
                    echo -e "${CYAN}-> 继续检查父提交: $current_commit${NC}"
                fi
            else
                if [[ "$VERBOSE" == "true" ]]; then
                    echo -e "${YELLOW}遇到合并提交，检查所有父提交...${NC}"
                fi
                
                local found_in_parent=false
                for parent in "${parent_commits[@]}"; do
                    if [[ -n "$parent" ]] && search_in_commit "$parent"; then
                        current_commit="$parent"
                        found_in_parent=true
                        if [[ "$VERBOSE" == "true" ]]; then
                            echo -e "${GREEN}在父提交 $parent 中找到，继续追溯${NC}"
                        fi
                        break
                    fi
                done
                
                if [[ "$found_in_parent" == "false" ]]; then
                    if [[ "$VERBOSE" == "true" ]]; then
                        echo -e "${BLUE}在任何父提交中都没找到，当前提交是引入点${NC}"
                    fi
                    break
                fi
            fi
        else
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${RED}✗ 在提交中未找到目标字符串，停止搜索${NC}"
            fi
            break
        fi
    done
    
    # 输出结果
    if [[ ${#found_commits[@]} -gt 0 ]]; then
        local origin_commit="${found_commits[-1]}"
        echo ""
        echo -e "${GREEN}找到字符串的真正起源提交:${NC}"
        echo -e "${YELLOW}提交哈希: $origin_commit${NC}"
        
        # 切换到起源提交以显示详细信息
        git checkout "$origin_commit" > /dev/null 2>&1
        
        echo -e "${YELLOW}提交信息:${NC}"
        git log -1 --pretty=format:"%H%n作者: %an <%ae>%n日期: %ad%n%n%s%n%b" --date=format:"%Y-%m-%d %H:%M:%S" "$origin_commit"
        echo ""
        
        # 显示在哪个文件中找到
        echo -e "${YELLOW}包含该字符串的文件:${NC}"
        if [[ -n "$FILE_PATH" ]]; then
            if [[ -f "$FILE_PATH" ]] && [[ $(search_in_file "$SEARCH_STRING" "$FILE_PATH") -gt 0 ]]; then
                echo "  $FILE_PATH"
                
                echo -e "${CYAN}匹配的内容 (搜索模式: $SEARCH_MODE):${NC}"
                if [[ "$SEARCH_MODE" == "legacy" ]]; then
                    grep -Fn "$SEARCH_STRING" "$FILE_PATH" 2>/dev/null | head -5 | while IFS=: read -r line_num line_content; do
                        echo "  第${line_num}行: ${line_content}"
                    done
                else
                    echo "  [精确匹配模式下找到完整的多行内容]"
                fi
            fi
        else
            # 显示包含字符串的文件列表
            local found_files=()
            while IFS= read -r file; do
                if [[ -f "$file" ]] && [[ $(search_in_file "$SEARCH_STRING" "$file") -gt 0 ]]; then
                    found_files+=("$file")
                fi
            done < <(git ls-files 2>/dev/null)
            
            for file in "${found_files[@]:0:10}"; do
                echo "  $file"
            done
            
            if [[ ${#found_files[@]} -gt 10 ]]; then
                echo "  ... 以及其他 $((${#found_files[@]} - 10)) 个文件"
            fi
        fi
        
        echo ""
        echo -e "${CYAN}统计信息:${NC}"
        echo -e "  使用搜索模式: $SEARCH_MODE"
        echo -e "  检查的提交数: $checked_commits"
        echo -e "  包含字符串的提交数: ${#found_commits[@]}"
        
        return 0
    else
        echo -e "${RED}未找到包含指定字符串的提交${NC}"
        return 1
    fi
}

# 执行搜索
find_true_origin
