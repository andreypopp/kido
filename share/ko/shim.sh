# The `..` are resolved by the kernel, physically, so a share/ko that is a
# Homebrew symlink into the Cellar lands in that version's own bin/.

set -f
ko_bin_dir=${0%/*}
ko_share=$ko_bin_dir/..
ko_prefix_bin=$ko_bin_dir/../../../bin

# Never an entry before our dir, or two installs' shims bounce between each other.
ko_real() {
	ko_seen=
	ko_after=
	ko_any=
	ko_ifs=$IFS
	IFS=:
	for ko_d in $PATH; do
		[ -n "$ko_d" ] || ko_d=.
		if [ "$ko_d" -ef "$ko_bin_dir" ]; then
			ko_seen=1
			continue
		fi
		ko_c=$ko_d/$1
		[ -f "$ko_c" ] && [ -x "$ko_c" ] || continue
		if [ "$ko_c" -ef "$0" ]; then
			continue
		fi
		if [ -n "$ko_seen" ]; then
			[ -n "$ko_after" ] || ko_after=$ko_c
		else
			[ -n "$ko_any" ] || ko_any=$ko_c
		fi
	done
	IFS=$ko_ifs
	if [ -n "$ko_seen" ]; then
		ko_found=$ko_after
	else
		ko_found=$ko_any
	fi
	if [ -z "$ko_found" ]; then
		echo "ko: no $1 on PATH after $ko_bin_dir" >&2
		exit 127
	fi
}
