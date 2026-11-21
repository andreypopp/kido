unset KO_STATE_DIR KO_PANE KO_PANE_TOKEN KO_SOCKET
for name in $(env | sed -n 's/^\(KO_AGENT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done

node_ok() {
	if ! command -v node >/dev/null 2>&1; then
		reason="node not found on PATH"
	elif node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)'; then
		return 0
	else
		reason="node $(node --version) is too old to run this suite (need >=24)"
	fi
	if [ "${KO_TS_TEST_REQUIRED:-}" = "1" ]; then
		echo "koa: $reason" >&2
		return 2
	fi
	echo "koa: skipping, $reason" >&2
	return 1
}
