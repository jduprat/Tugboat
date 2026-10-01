#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s repository-root Info.plist-template output-plist\n' "$0" >&2
    exit 2
fi

repository_root=$1
template_plist=$2
output_plist=$3
git_command=(/usr/bin/git -C "$repository_root")

# Reading build provenance should never refresh the repository's index on disk.
export GIT_OPTIONAL_LOCKS=0

if ! "${git_command[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'error: Tugboat build metadata requires a Git checkout.\n' >&2
    exit 1
fi

is_shallow=$("${git_command[@]}" rev-parse --is-shallow-repository)
case $is_shallow in
    false) ;;
    true)
        printf 'error: Tugboat build numbering requires complete Git history. Fetch the full history and build again.\n' >&2
        exit 1
        ;;
    *)
        printf 'error: Tugboat could not determine whether Git history is complete.\n' >&2
        exit 1
        ;;
esac

commit_id=$("${git_command[@]}" rev-parse --verify 'HEAD^{commit}')
build_number=$("${git_command[@]}" rev-list --count "$commit_id")
branch_name=$("${git_command[@]}" rev-parse --abbrev-ref HEAD)
working_tree_status=$("${git_command[@]}" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)
tree_state=clean
if [[ -n $working_tree_status ]]; then
    tree_state=dirty
fi

output_directory=$(/usr/bin/dirname "$output_plist")
/bin/mkdir -p "$output_directory"
temporary_plist=$(/usr/bin/mktemp "$output_plist.XXXXXX")
trap '/bin/rm -f "$temporary_plist"' EXIT

/bin/cp "$template_plist" "$temporary_plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" -s "$temporary_plist"
/usr/bin/plutil -insert TugboatGitCommit -string "$commit_id" -s "$temporary_plist"
/usr/bin/plutil -insert TugboatGitBranch -string "$branch_name" -s "$temporary_plist"
/usr/bin/plutil -insert TugboatGitTreeState -string "$tree_state" -s "$temporary_plist"

# Preserve the output timestamp when metadata is unchanged, so an incremental
# build does not reprocess and re-sign the bundle just because Git was checked.
if [[ -f $output_plist ]] && /usr/bin/cmp -s "$temporary_plist" "$output_plist"; then
    /bin/rm -f "$temporary_plist"
else
    /bin/mv -f "$temporary_plist" "$output_plist"
fi
trap - EXIT

printf 'Tugboat build %s: %s (%s, %s)\n' "$build_number" "$commit_id" "$branch_name" "$tree_state"
