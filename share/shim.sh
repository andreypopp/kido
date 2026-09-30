# The `..` are resolved by the kernel, physically, so a share/kido that is a
# Homebrew symlink into the Cellar lands in that version's own bin/.

set -f
kido_bin_dir=${0%/*}
kido_share=$kido_bin_dir/..
kido_prefix_bin=$kido_bin_dir/../../../bin

# Never an entry before our dir, or two installs' shims bounce between each other.
kido_real() {
	kido_seen=
	kido_after=
	kido_any=
	kido_ifs=$IFS
	IFS=:
	for kido_d in $PATH; do
		[ -n "$kido_d" ] || kido_d=.
		if [ "$kido_d" -ef "$kido_bin_dir" ]; then
			kido_seen=1
			continue
		fi
		kido_c=$kido_d/$1
		[ -f "$kido_c" ] && [ -x "$kido_c" ] || continue
		if [ "$kido_c" -ef "$0" ]; then
			continue
		fi
		if [ -n "$kido_seen" ]; then
			[ -n "$kido_after" ] || kido_after=$kido_c
		else
			[ -n "$kido_any" ] || kido_any=$kido_c
		fi
	done
	IFS=$kido_ifs
	if [ -n "$kido_seen" ]; then
		kido_found=$kido_after
	else
		kido_found=$kido_any
	fi
	if [ -z "$kido_found" ]; then
		echo "kido: no $1 on PATH after $kido_bin_dir" >&2
		exit 127
	fi
}
