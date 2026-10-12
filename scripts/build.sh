#!/bin/zsh
# Builds the app, with the virtualvm command-line tool and the guest agent for macOS guests inside it.
#   scripts/build.sh                    optimized, at build/VirtualVM.app
#   scripts/build.sh debug              the same app, not optimized
#   scripts/build.sh --output <app>     somewhere else, e.g. while VirtualVM is running from build/
#
# This is the app with your machines in it. For a copy to try changes in, with machines of its own,
# use `swift run VirtualVM`. How the app is signed is described in scripts/bundle-app.sh.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

configuration=release
app=$root/build/VirtualVM.app
while (( $# )); do
    case ${1:l} in
        debug | release) configuration=${1:l}; shift ;;
        --output) app=${${2:?}:a}; shift 2 ;;
        *) fail "Usage: scripts/build.sh [debug] [--output <app>]" ;;
    esac
done
# A relative path would be one file here and another once this script has moved to the repository.
if [[ ${VIRTUALVM_PROVISIONING_PROFILE:--} != - ]]; then
    export VIRTUALVM_PROVISIONING_PROFILE=${VIRTUALVM_PROVISIONING_PROFILE:a}
fi
cd "$root"
# Said now rather than after minutes of building.
check_replaceable "$app"

swift build -c $configuration --product VirtualVM
swift build -c $configuration --package-path Packages/VirtualVMKit --product virtualvm
swift build -c $configuration --package-path Packages/VirtualVMKit --product virtualvm-agent
"$root/scripts/bundle-app.sh" --output "$app" \
    --products "$(swift build -c $configuration --show-bin-path)" \
    --helpers "$(swift build -c $configuration --package-path Packages/VirtualVMKit --show-bin-path)" > /dev/null

print "App: $app"
print "CLI: $app/Contents/Helpers/virtualvm"
