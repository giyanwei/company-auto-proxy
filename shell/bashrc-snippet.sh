# >>> company-auto-proxy >>>
__proxy_switch() {
    local state_file="$HOME/.proxy/state"
    if [[ -f "$state_file" ]]; then
        local state
        state=$(<"$state_file")
        if [[ "$state" == "CORP" ]]; then
            export HTTPS_PROXY="$(cat "$HOME/.proxy/.proxy_url" 2>/dev/null)"
            export HTTP_PROXY="$HTTPS_PROXY"
        else
            unset HTTPS_PROXY HTTP_PROXY
        fi
    else
        unset HTTPS_PROXY HTTP_PROXY
    fi
}
PROMPT_COMMAND="__proxy_switch;${PROMPT_COMMAND}"
# <<< company-auto-proxy <<<
