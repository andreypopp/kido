# Sourced by every program in kido's bin directory, which sits at
# <prefix>/share/kido/bin; not run on its own. Nothing here names an
# absolute path: every location is worked out from where the shim was run
# from, so there is nothing to quote and nothing to go stale when the
# package moves.
#
# kido_bin_dir is the shim's own directory, kido_share the share/kido
# above it, and kido_prefix_bin the bin/ that holds kido and kido-tmux -
# the inverse of findShared, which finds share/kido from the binary. The
# `..` are resolved by the kernel, physically, so a share/kido that is a
# Homebrew symlink into the Cellar lands in that version's own bin/.

set -f
kido_bin_dir=${0%/*}
kido_share=$kido_bin_dir/..
kido_prefix_bin=$kido_bin_dir/../../../bin

# kido_real NAME sets kido_found to the NAME the shim stands in for: the
# first executable NAME on PATH after the shim's own directory. Never the
# shim itself, and never an entry before it - a second kido install's bin
# directory ahead of this one is exactly such an entry, and taking it
# would bounce between the two forever. A shim run by path, with its
# directory nowhere on PATH, takes the first NAME that is not itself.
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
