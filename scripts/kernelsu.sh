#!/usr/bin/env bash
# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it. They differ in three
# ways that matter, all of which are encoded in the registry below:
#
#   * the directory the clone lands in (KernelSU vs KernelSU-Next),
#   * what "no argument" means -- most check out the latest tag, ReSukiSU
#     checks out main,
#   * which ref carries non-GKI support and which carries SUSFS.
#
# The critical safety property: every variant's setup.sh ends its checkout with
#     git checkout "$1" ... || echo "[-] Checkout default branch"
# so an invalid ref does NOT fail the script -- it silently leaves the tree on
# the default branch. A build asking for SukiSU's SUSFS-capable 'builtin'
# branch and typing 'susfs-main' (which does not exist) would quietly produce a
# kernel with no SUSFS at all. So we validate the ref before calling setup.sh
# and verify the checkout afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields, '|'-separated:
#   1 repo URL
#   2 ref the setup.sh script itself is fetched from
#   3 directory setup.sh clones into, relative to the kernel tree
#   4 default ref for modern (>= 5.10) kernels; empty means "let setup.sh pick"
#   5 default ref for legacy (< 5.10) kernels
#   6 refs that already contain SUSFS support (space separated; '-' for none)
#   7 human-readable name
#
# Verified against each repo's live branch/tag list on 2026-07-27.

ksu_registry() {
	case "$1" in
	kernelsu)
		# Official upstream. Dropped non-GKI support at v1.0, so legacy kernels
		# are pinned to the last release that supports them.
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		# 'next' was renamed to 'legacy' and the default branch is now 'dev'.
		# Raw URLs containing /next/ only still work via GitHub's rename
		# redirect, so we address the real branches directly.
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		# Repo moved from the personal ShirkNeko account into its own org.
		# 'main' is the modular v4 tree (KPM, no SUSFS); 'builtin' is the
		# non-GKI/source-integrated tree and is the only one with SUSFS Kconfig.
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		# Re-fork of SukiSU-Ultra aimed at legacy/non-GKI kernels.
		echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|-|ReSukiSU" ;;
	rsuntk)
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() { ksu_registry "$1" | cut -d'|' -f"$2"; }

# ReSukiSU's setup.sh checks out 'main' when given no argument, while every
# other variant checks out the latest tag. Call that out so an unpinned CI
# build is not silently tracking a moving branch.
ksu_default_is_branch() { [ "$1" = "resukisu" ]; }

# ---------------------------------------------------------------- install ---

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && { info "KernelSU integration disabled"; return 0; }

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"
	info "repository: ${repo}"

	# Spoof the kernel release to the stock MIUI 14.0.8 (haydn) string so
	# detection surfaces see a stock version. Stock string, extracted from
	# the user's original boot_a backup:
	#   5.4.233-qgki-gbb70cde46897
	# AGNi tracks the 5.4 LTS tip (5.4.302) with a custom LOCALVERSION.
	# Two rewrites before anything reads the version:
	#   1. Makefile SUBLEVEL 302 -> 233 (affects vermagic/utsrelease/kver)
	#   2. defconfig CONFIG_LOCALVERSION -> stock suffix (drops the -AGNi tag)
	# Do NOT make this a partial "cap": partial spoofing (5.4.256) still
	# identifies as non-stock.
	local sublevel
	sublevel=$(sed -n 's/^SUBLEVEL = //p' "${KERNEL_DIR}/Makefile" | head -n1)
	if [ "$sublevel" != "233" ]; then
		sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 233/' "${KERNEL_DIR}/Makefile"
		ok "kernel SUBLEVEL spoofed: 5.4.${sublevel:-?} -> 5.4.233 (stock MIUI 14.0.8)"
	else
		ok "kernel SUBLEVEL already stock (5.4.233)"
	fi

	local defcfg="${KERNEL_DIR}/arch/arm64/configs/${KERNEL_CONFIG:-agni_haydn_defconfig}"
	if [ -f "$defcfg" ] && grep -q '^CONFIG_LOCALVERSION=' "$defcfg"; then
		if ! grep -q 'CONFIG_LOCALVERSION="-qgki-gbb70cde46897"' "$defcfg"; then
			sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-qgki-gbb70cde46897"|' "$defcfg"
			ok "CONFIG_LOCALVERSION spoofed to stock suffix (-qgki-gbb70cde46897)"
		else
			ok "CONFIG_LOCALVERSION already stock"
		fi
	else
		warn "defconfig ${defcfg} not found or lacks CONFIG_LOCALVERSION; version suffix untouched"
	fi

	# Decide which ref to check out.
	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")
	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref
			[ -n "$ref" ] && info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
		fi
	fi

	# Validate before handing the ref to setup.sh, which would swallow a typo.
	if [ -n "$ref" ]; then
		info "validating ref '${ref}' exists in ${repo}"
		ref_exists "$repo" "$ref" \
			|| die "ref '${ref}' does not exist in ${repo}.
       setup.sh would silently fall back to the default branch and you would
       get a kernel without the feature you asked for.
       Available branches: $(git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"
		ok "ref '${ref}' exists"
	else
		warn "no ref pinned; setup.sh will pick the latest tag. Set KSU_REF for reproducible builds."
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name}'s setup.sh defaults to the moving 'main' branch rather than a tag."
		warn "Pin KSU_REF (e.g. a tag) if you need reproducible builds."
	fi

	# haydn/AGNi trees ship a built-in KSU (SukiSU) at drivers/kernelsu;
	# remove it so setup.sh can create a fresh symlink for the chosen variant.
	# Those trees integrate SUSFS kernel-side (fs/susfs.c, hooks in exec/stat/
	# read_write/input/reboot/pty/sys), and the KSU_SUSFS Kconfig menu lives
	# inside the built-in variant's own Kconfig. Deleting the variant without
	# rescuing it would silently strip every CONFIG_KSU_SUSFS_* symbol out of
	# Kconfig: the #ifdef CONFIG_KSU_SUSFS hooks compile out and the link dies
	# on the missing static keys (run5: undefined ksu_init_rc_hook_key_false).
	local built_in_kconfig="${KERNEL_DIR}/drivers/kernelsu/Kconfig"
	local susfs_menu="${WORKSPACE:-/tmp}/susfs_kconfig_menu.txt"
	rm -f "$susfs_menu"
	if [ -f "$built_in_kconfig" ]; then
		awk '/^menu "KernelSU - SUSFS"/{f=1} f{print} f&&/^endmenu/{exit}' \
			"$built_in_kconfig" > "$susfs_menu" || true
		if [ -s "$susfs_menu" ]; then
			ok "rescued the SUSFS Kconfig menu from the built-in variant ($(wc -l < "$susfs_menu") lines)"
		fi
	fi
	if [ ! -s "$susfs_menu" ] && [ -f "${KERNEL_DIR}/fs/susfs.c" ]; then
		die "the tree ships SUSFS kernel-side (fs/susfs.c) but its built-in KSU
       variant carried no 'KernelSU - SUSFS' Kconfig menu to rescue. Installing
       a replacement variant now would silently disable SUSFS."
	fi
	rm -rf "${KERNEL_DIR}/drivers/kernelsu"
	# Run the variant's own installer.
	local setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"

	# --- verify the installer actually did what it claims ------------------
	local ksu_dir="${KERNEL_DIR}/${dir}"
	[ -d "$ksu_dir" ] || die "${name} setup.sh finished but ${dir}/ is missing"

	local link="${KERNEL_DIR}/drivers/kernelsu"
	[ -e "$link" ] || die "drivers/kernelsu symlink was not created"

	# setup.sh only checks whether the word "kernelsu" already appears.  Some
	# vendor trees carry an obsolete line guarded by CONFIG_WITH_KERNEL_SU, so
	# setup.sh reports success without adding the CONFIG_KSU rule and the final
	# link fails with every ksu_handle_* symbol undefined.  Normalize any stale
	# rule to the symbol declared by the installed Kconfig.
	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "drivers/Makefile was not wired to CONFIG_KSU for kernelsu"
	grep -q 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
		|| die "drivers/Kconfig was not wired up for kernelsu"

	# Confirm we landed on the ref we asked for, catching the silent fallback.
	local head_desc head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	if [ -n "$ref" ]; then
		local want
		want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
		if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi
	ok "${name} installed at ${head_desc} (${head_sha})"

	# --- SUSFS bridging for trees whose built-in variant carried SUSFS -----
	#
	# Re-attach the rescued Kconfig menu, drop in the compat shims for the
	# symbols the kernel-side SUSFS hooks expect from the KSU variant, and
	# expose KSUN's static try_umount() to fs/susfs.c. Only done when the
	# replacement variant does not declare SUSFS itself (SukiSU builtin does).
	local ksu_kernel_dir="${ksu_dir}/kernel"
	if [ -s "$susfs_menu" ] && ! grep -q 'config KSU_SUSFS' "${ksu_kernel_dir}/Kconfig" 2>/dev/null; then
		info "bridging kernel-side SUSFS to ${name}"
		printf '\n# SUSFS options rescued from the tree'"'"'s built-in KSU variant\n' \
			>> "${ksu_kernel_dir}/Kconfig"
		cat "$susfs_menu" >> "${ksu_kernel_dir}/Kconfig"
		grep -q 'config KSU_SUSFS' "${ksu_kernel_dir}/Kconfig" \
			|| die "SUSFS Kconfig menu was re-attached but no KSU_SUSFS symbol is visible"

		# Compat shims: the AGNi kernel-side hooks call three symbols SukiSU
		# used to provide that KSUN v3.4.0-legacy does not (verified against
		# both sources). Everything else resolves natively.
		if [ ! -f "${ksu_kernel_dir}/agni_compat.c" ]; then
			cat > "${ksu_kernel_dir}/agni_compat.c" <<'AGNI_COMPAT_EOF'
/*
 * AGNi <-> KernelSU-Next compatibility shims.
 *
 * Trees like AGNi (SukiSU-Ultra builtin) integrate SUSFS kernel-side and
 * their syscall hooks reference a handful of symbols the KSU variant was
 * expected to provide. KernelSU-Next v3.4.0-legacy provides almost all of
 * them; this file supplies the few it does not.
 */
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/types.h>

#include "selinux/selinux.h"

/*
 * drivers/tty/pty.c (CONFIG_KSU): devpts open notifier. KernelSU-Next
 * covers devpts through its own LSM hooks instead; keep the call site
 * happy with a no-op.
 */
int ksu_handle_devpts(struct inode *inode)
{
	return 0;
}

/*
 * fs/exec.c and fs/stat.c: SukiSU's st_size report hook used for init.rc
 * injection. KernelSU-Next handles that via ksu_handle_sys_read(); there
 * is nothing for this hook to do.
 */
void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
}

#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>

/* fs/susfs.c asks whether the current task is in the KSU SELinux domain;
 * delegate to KernelSU-Next's own check. */
bool susfs_is_current_ksu_domain(void)
{
	return is_ksu_domain();
}

/* SukiSU used to call susfs_init() during its own initialization. Without
 * it the SUSFS static keys never enable and every kernel-side SUSFS hook
 * stays dormant, so trigger it from a late initcall. */
static int __init agni_ksu_susfs_late_init(void)
{
	susfs_init();
	return 0;
}
late_initcall(agni_ksu_susfs_late_init);
#endif /* CONFIG_KSU_SUSFS */
AGNI_COMPAT_EOF
		fi
		grep -q 'agni_compat' "${ksu_kernel_dir}/Kbuild" \
			|| printf 'kernelsu-objs += agni_compat.o\n' >> "${ksu_kernel_dir}/Kbuild"

		# fs/susfs.c (CONFIG_KSU_SUSFS_TRY_UMOUNT) calls try_umount() via a
		# plain extern; KSUN's implementation is static in kernel_umount.c.
		# Un-static it so the symbol is visible at link time.
		local umount_c="${ksu_kernel_dir}/feature/kernel_umount.c"
		if [ -f "$umount_c" ] && grep -q '^static void try_umount(' "$umount_c"; then
			sed -i 's/^static void try_umount(/void try_umount(/' "$umount_c"
			ok "exposed KSUN's static try_umount() to fs/susfs.c"
		fi
	fi

	# Keep the release string free of "-dirty": this script has now touched
	# tracked files (Makefile, defconfig) and dropped untracked ones into the
	# tree. scripts/setlocalversion appends -dirty when `git diff-index HEAD`
	# is non-quiet, which would give the spoof away. Commit everything so the
	# worktree is clean again.
	if git -C "$KERNEL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
		if ! git -C "$KERNEL_DIR" diff-index --quiet HEAD 2>/dev/null; then
			git -C "$KERNEL_DIR" add -A
			git -C "$KERNEL_DIR" -c user.email=ci@local \
				-c user.name=ci commit -qm "spoof kernel release to stock MIUI 14.0.8 string"
			ok "committed tree changes (KERNELRELEASE stays -dirty-free)"
		fi
	fi

	# --- publish facts the later steps need --------------------------------
	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# ------------------------------------------------------------ hook config ---
#
# Which hook mechanism a variant should use is genuinely version- and
# fork-specific. 'auto' picks the option that the variant actually declares.

# Resolve 'auto' into a concrete mode and publish it.
#
# This has to happen once, early, and be reused by BOTH the source-patching
# step and the defconfig step. Resolving it independently in each place is how
# you end up setting CONFIG_KSU_MANUAL_HOOK on a tree whose syscall entry
# points were never actually patched -- which builds fine and then does
# nothing at runtime.
ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			# kprobes on pre-GKI kernels is the classic source of "KernelSU
			# installed but su does nothing" reports; manual hooks are patched
			# straight into the syscall entry points instead.
			mode="manual"
		fi
		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4

	if [ "$mode" = "auto" ]; then
		[ -n "${KSU_HOOK_MODE_RESOLVED:-}" ] || ksu_resolve_hook_mode "$mode" "$kver"
		mode=$KSU_HOOK_MODE_RESOLVED
	fi

	case "$mode" in
	none) return 0 ;;
	kprobes)
		kconf_enable "$defconfig" CONFIG_MODULES
		kconf_enable "$defconfig" CONFIG_KPROBES
		kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
		kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
		kconf_enable "$defconfig" CONFIG_KRETPROBES
		[ "$variant" = "kernelsu-next" ] && kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
		;;
	manual)
		case "$variant" in
			kernelsu-next)  kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			sukisu-ultra)
				kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			resukisu)
				# ReSukiSU's non-GKI static export check requires the complete
				# kallsyms table unless every internal SELinux symbol is exported
				# manually by the vendor tree.
				kconf_set_many "$defconfig" \
					CONFIG_KSU_MANUAL_HOOK=y CONFIG_DEBUG_KERNEL=y \
					CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y ;;
			*) : ;;  # tiann/KernelSU 0.9.x infers manual hooks from the source patch
		esac
		;;
	tracepoint)
		[ "$variant" = "resukisu" ] || [ "$variant" = "sukisu-ultra" ] \
			|| warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"
		kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
		;;
	syscall)
		kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
		;;
	esac
}

# Only run the installer when sourced as a script entry point.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
