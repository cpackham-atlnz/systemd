#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux
set -o pipefail

# Save the end.service state before we start fuzzing, as it might get changed
# on the fly by one of the fuzzers
systemctl list-jobs | grep -F 'end.service' && SHUTDOWN_AT_EXIT=1 || SHUTDOWN_AT_EXIT=0

at_exit() {
    # "Safety net" - check for any coredumps which might have not caused dfuzzer
    # to stop & return an error (we need to do this now before truncating the
    # journal)
    # TODO: check fo ASan/UBSan errors
    local found_cd=0
    while read -r exe; do
        coredumctl info "$exe"
        found_cd=1
    done < <(coredumpctl -F COREDUMP_EXE | sort -u)
    [[ $found_cd -eq 0 ]] || exit 1

    # We have to call the end.service explicitly even if it's specified on
    # the kernel cmdline via systemd.wants=end.service, since dfuzzer calls
    # org.freedesktop.systemd1.Manager.ClearJobs() which drops the service
    # from the queue
    [[ $SHUTDOWN_AT_EXIT -ne 0 ]] && systemctl start --job-mode=flush end.service
}

trap at_exit EXIT

systemctl log-level info

# TODO
#   * check for possibly newly introduced buses?
BUS_LIST=(
    org.freedesktop.home1
    org.freedesktop.hostname1
    org.freedesktop.import1
    org.freedesktop.locale1
    org.freedesktop.login1
    org.freedesktop.machine1
    org.freedesktop.network1
    org.freedesktop.portable1
    org.freedesktop.resolve1
    org.freedesktop.systemd1
    org.freedesktop.timedate1
    org.freedesktop.timesync1
)

# systemd-oomd requires PSI
if tail -n +1 /proc/pressure/{cpu,io,memory}; then
    BUS_LIST+=(org.freedesktop.oom1)
fi

SESSION_BUS_LIST=(
    org.freedesktop.systemd1
)

# Maximum payload size generated by dfuzzer (in bytes) - default: 50K
PAYLOAD_MAX=50000
# Tweak the maximum payload size if we're running under sanitizers, since
# with larger payloads we start hitting reply timeouts
if [[ -v ASAN_OPTIONS || -v UBSAN_OPTIONS ]]; then
    PAYLOAD_MAX=10000 # 10K
fi

# Overmount /var/lib/machines with a size-limited tmpfs, as fuzzing
# the org.freedesktop.machine1 stuff makes quite a mess
mount -t tmpfs -o size=50M tmpfs /var/lib/machines

# Fuzz both the system and the session buses (where applicable)
for bus in "${BUS_LIST[@]}"; do
    echo "Bus: $bus (system)"
    systemd-run --pipe --wait \
                -- dfuzzer -b "$PAYLOAD_MAX" -n "$bus"

    # Let's reload the systemd daemon to test (de)serialization as well
    systemctl daemon-reload
done

umount /var/lib/machines

for bus in "${SESSION_BUS_LIST[@]}"; do
    echo "Bus: $bus (session)"
    systemd-run --machine 'testuser@.host' --user --pipe --wait \
                -- dfuzzer -b "$PAYLOAD_MAX" -n "$bus"

    # Let's reload the systemd user daemon to test (de)serialization as well
    systemctl --machine 'testuser@.host' --user daemon-reload
done

echo OK >/testok

exit 0
