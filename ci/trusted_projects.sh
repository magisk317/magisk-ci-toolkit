#!/usr/bin/env bash
# Shared allowlist for every trusted upstream project handled by the CI
# controller. Keep project IDs and target branches together so the merge and
# cancellation controllers cannot drift apart.
#
# Upstreams are the consumer repositories the controller serves. The toolkit
# itself is the controller project, never an upstream: it cannot bridge into
# itself, so its own Renovate merge requests are merged by
# ci/auto_merge_self_renovate_mrs.sh from its own schedule pipeline.

trusted_project_id() {
  case "$1" in
    magisk3171/MiPushFramework) printf '%s\n' "83955143" ;;
    magisk3171/XposedSmsCode) printf '%s\n' "83955172" ;;
    magisk3171/xinyi-relay) printf '%s\n' "84113188" ;;
    magisk3171/SerialBridge) printf '%s\n' "85198813" ;;
    magisk3171/napgram-ecosystem/NapGram) printf '%s\n' "84583729" ;;
    magisk3171/napgram-ecosystem/napgram-ui-dist) printf '%s\n' "84583731" ;;
    magisk3171/MiPushConfigurations) printf '%s\n' "84115161" ;;
    magisk3171/MiPushZygisk) printf '%s\n' "84115160" ;;
    magisk3171/napgram-ecosystem/NapLink) printf '%s\n' "84834294" ;;
    magisk3171/android-host-tools-arm64) printf '%s\n' "85413835" ;;
    *) return 1 ;;
  esac
}

trusted_target_branch() {
  trusted_project_id "$1" >/dev/null || return 1
  case "$1" in
    # Every consumer renovates its protected beta branch. The toolkit is the
    # controller project itself and is never an upstream target.
    *) printf '%s\n' "beta" ;;
  esac
}

trusted_project_is_allowed() {
  trusted_project_id "$1" >/dev/null
}
# E2E probe: auto-merged by renovate:self-automerge on 2026-09-26.
