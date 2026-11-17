deployments=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/deployments
valid_name() {
    [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}
resolve() {
    local usage=$1 found
    shift
    if [[ $# -gt 0 ]] && valid_name "$1" && [[ -d $deployments/$1 ]]; then
        folder=$deployments/$1
        consumed=1
        return
    fi
    found=$(cd -- "$deployments" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sed 's|^\./||')
    [[ -n $found && $found != *$'\n'* ]] || { echo "usage: $usage (NAME is required unless exactly one deployment exists)" >&2; exit 124; }
    folder=$deployments/$found
    consumed=0
}
address() {
    local state=$folder/terraform.tfstate file=$folder/address
    if [[ -e $state && -e $file ]]; then
        echo "$folder has both terraform.tfstate and address" >&2
        return 1
    elif [[ -e $state ]]; then
        python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["outputs"]["ipv4"]["value"])' "$state" 2>/dev/null \
            || { echo "$state has no ipv4 output" >&2; return 1; }
    elif [[ -e $file ]]; then
        cat -- "$file"
    else
        echo "$folder has no terraform.tfstate or address" >&2
        return 1
    fi
}
