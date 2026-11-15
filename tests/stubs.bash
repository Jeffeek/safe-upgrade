# Sourced AFTER safe-upgrade.sh, inside the throw-away bash started by sh_run.
# External commands are replaced by functions; behaviour is driven by FAKE_*
# variables so each test can describe the "system" it wants.

# Redirect the script's absolute paths into the per-test sandbox.
BOOT_DIR="${TEST_BOOT_DIR:-$BOOT_DIR}"
STATE_DIR="${TEST_STATE_DIR:-$STATE_DIR}"
REBOOT_FLAG="${TEST_REBOOT_FLAG:-$REBOOT_FLAG}"
MODULES_DIR="${TEST_MODULES_DIR:-$MODULES_DIR}"

# Defaults for a "normal" system.
: "${FAKE_KERNEL:=6.1.0-18-generic}"
: "${FAKE_HOLD:=}"
: "${FAKE_DPKG_META:=base-files\tyes\tno\n}"      # name<TAB>Essential<TAB>Protected
: "${FAKE_DPKG_META_ESS:=base-files\tyes\n}"      # used when ${Protected} is unsupported
: "${FAKE_PKGS:=}"                                # 'ii ' lines for write_package_snapshot
: "${FAKE_UNIT:=}"                                # systemctl show output
: "${FAKE_KERNEL_OWNER:=}"                        # package owning the running kernel

uname() {
  if [ "${1-}" = -r ]; then printf '%s\n' "$FAKE_KERNEL"; else command uname "$@"; fi
}

apt-mark() {
  if [ "${1-}" = showhold ]; then printf '%b' "$FAKE_HOLD"; else return 1; fi
}

dpkg-query() {
  if [ "${1-}" = -S ]; then
    [ -n "$FAKE_KERNEL_OWNER" ] || return 1
    printf '%s: %s\n' "$FAKE_KERNEL_OWNER" "${2-}"
    return 0
  fi
  case "$*" in
    *'${db:Status-Abbrev}'*)
      printf '%b' "$FAKE_PKGS" ;;
    *'${Protected}'*)
      [ "${FAKE_DPKG_BROKEN:-0}" != 1 ] || return 1
      [ "${FAKE_NO_PROTECTED:-0}" != 1 ] || return 1
      printf '%b' "$FAKE_DPKG_META" ;;
    *'${Essential}'*)
      [ "${FAKE_DPKG_BROKEN:-0}" != 1 ] || return 1
      printf '%b' "$FAKE_DPKG_META_ESS" ;;
    *) return 1 ;;
  esac
}

systemctl() {
  case "${1-}" in
    show) printf '%b' "$FAKE_UNIT" ;;
    cat)  [ "${FAKE_UNIT_KNOWN:-1}" = 1 ] ;;
    *)    return 1 ;;
  esac
}

# Never really wait in unit tests.
sleep() { :; }
