#!/usr/bin/env bash
#
# Sets up the build Mac (ARC-15, docs/plans/2026-10-11-build-mac-plan.md) with everything Redlamp's
# builds and test suites need, so that it builds and tests a commit as the main Mac does.
#
# On the build Mac, in Terminal, as the account it builds with (an administrator, since Homebrew and
# the settings need one), signed in to the App Store:
#
#   curl -fsSLo /tmp/build-mac-setup.sh \
#       https://raw.githubusercontent.com/pdcgomes/redlamp/main/scripts/build-mac/setup.sh
#   bash /tmp/build-mac-setup.sh [--gate] [--no-settings] [--no-fixtures]
#
# Afterwards it is ~/src/build-mac/redlamp/scripts/build-mac/setup.sh (over SSH, `ssh -t`, for
# sudo). Running it again brings everything up to date and leaves what's right as it is.
#
# In order: Homebrew, which installs the Command Line Tools; the clone at ~/src/build-mac/redlamp,
# put on origin/main; the tools in scripts/build-mac/Brewfile; Xcode, from the App Store (mas) when
# the App Store's version is the main Mac's, or else from Apple's developer downloads (xcodes, which
# asks for an Apple Account), with its licence, first launch, Metal toolchain and iOS SDK; PATH for
# commands run over SSH; mise's tools (mise.toml); the sample raws (2.1 GB); `mise run generate`;
# and the settings a Mac left on its own needs (--no-settings leaves them out): no sleep on the
# charger or with the lid closed, no screen lock, automatic login, Remote Login, and no automatic
# macOS or App Store updates, since macOS and Xcode change on both Macs together. --gate then runs
# the push gate on origin/main, which builds everything and runs the reference tests (a few minutes).
#
# MACOS_VERSION, XCODE_VERSION and XCODE_BUILD are the main Mac's (`sw_vers -productVersion`,
# `xcodebuild -version`); set them when it moves on. A build Mac on other versions can build and
# test differently, so the setup says when they differ.

set -euo pipefail

MACOS_VERSION="${MACOS_VERSION:-26.6.2}"
XCODE_VERSION="${XCODE_VERSION:-26.6}"
XCODE_BUILD="${XCODE_BUILD:-17F113}"
REPOSITORY="${REDLAMP_REPOSITORY:-https://github.com/pdcgomes/redlamp.git}"
ROOT="$HOME/src/build-mac"
CLONE="$ROOT/redlamp"
XCODE_STORE_ID=497799835
# Xcode, the iOS platform, the sample raws and a build or two.
DISK_NEEDED_GB=60
BLOCK_BEGIN="# >>> Redlamp build Mac (scripts/build-mac/setup.sh) >>>"
BLOCK_END="# <<< Redlamp build Mac <<<"

GATE=0
SETTINGS=1
FIXTURES=1
XCODE_APP=""
NOTES=()

say() {
    printf '==> %s\n' "$*"
}

note() {
    NOTES+=("$*")
    printf '    note: %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

parse() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            --gate) GATE=1 ;;
            --no-settings) SETTINGS=0 ;;
            --no-fixtures) FIXTURES=0 ;;
            -h | --help)
                sed -n '3,/^$/p' "$0" | sed -E 's/^# ?//'
                exit 0
                ;;
            *) fail "unknown option $argument (see --help)" ;;
        esac
    done
}

preflight() {
    [ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || fail "the build Mac is a Mac with Apple silicon"
    [ "$(id -u)" != 0 ] || fail "run it as the account the build Mac builds with, not as root"
    case " $(id -Gn) " in
        *" admin "*) ;;
        *) fail "$USER isn't an administrator, which Homebrew and the settings need (System Settings › Users & Groups)" ;;
    esac
    local found free
    found="$(sw_vers -productVersion)"
    [ "$found" = "$MACOS_VERSION" ] \
        || note "macOS is $found here and $MACOS_VERSION on the main Mac: update one of them so they match"
    free="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
    [ "$free" -ge "$DISK_NEEDED_GB" ] \
        || note "$free GB is free; Xcode, the iOS platform, the sample raws and the builds take about $DISK_NEEDED_GB GB"
}

keep_sudo() {
    say "Administrator password, for Homebrew, Xcode's licence and the settings"
    sudo -v
    while kill -0 "$$" 2>/dev/null; do
        sudo -n true
        sleep 50
    done 2>/dev/null &
}

homebrew() {
    if [ ! -x /opt/homebrew/bin/brew ]; then
        say "Installing Homebrew, with the Command Line Tools"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

clone() {
    mkdir -p "$ROOT"
    if [ ! -d "$CLONE/.git" ]; then
        say "Cloning $REPOSITORY into $CLONE"
        git clone --quiet "$REPOSITORY" "$CLONE"
        return
    fi
    git -C "$CLONE" fetch --quiet origin
    if [ -n "$(git -C "$CLONE" status --porcelain --untracked-files=no)" ]; then
        note "$CLONE has uncommitted changes, so it stays at $(git -C "$CLONE" rev-parse --short HEAD)"
    else
        git -C "$CLONE" checkout --quiet --detach origin/main
    fi
    say "The clone is at $(git -C "$CLONE" log -1 --format='%h %s' | cut -c1-100)"
}

# The Brewfile's lines that match (grep's options and pattern), as a Brewfile of their own.
brewfile_part() {
    local part
    part="$(mktemp -t brewfile)"
    grep "$@" "$CLONE/scripts/build-mac/Brewfile" >"$part" || true
    echo "$part"
}

tools() {
    say "Homebrew's tools (scripts/build-mac/Brewfile)"
    local part
    part="$(brewfile_part -vE '^[[:space:]]*mas ')"
    HOMEBREW_BUNDLE_NO_LOCK=1 brew bundle install --file="$part"
    rm -f "$part"
}

xcode_field() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/version.plist" 2>/dev/null || true
}

# The installed Xcode with the main Mac's build.
matching_xcode() {
    local app
    for app in /Applications/Xcode*.app; do
        if [ -d "$app" ] && [ "$(xcode_field "$app" ProductBuildVersion)" = "$XCODE_BUILD" ]; then
            echo "$app"
            return 0
        fi
    done
    return 1
}

# Xcode's version on the App Store, from Apple's public lookup.
store_xcode_version() {
    local answer
    answer="$(mktemp -t xcode-lookup)"
    if curl -fsS "https://itunes.apple.com/lookup?id=$XCODE_STORE_ID" -o "$answer" 2>/dev/null; then
        python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["version"])' <"$answer" 2>/dev/null || true
    fi
    rm -f "$answer"
}

xcode() {
    XCODE_APP="$(matching_xcode || true)"
    if [ -z "$XCODE_APP" ]; then
        local store part
        store="$(store_xcode_version)"
        if [ "$store" = "$XCODE_VERSION" ]; then
            say "Installing Xcode $XCODE_VERSION from the App Store, several GB"
            part="$(brewfile_part -E '^[[:space:]]*mas ')"
            HOMEBREW_BUNDLE_NO_LOCK=1 brew bundle install --file="$part" \
                || fail "the App Store didn't install Xcode: open the App Store, sign in, get Xcode once, and run this again"
            rm -f "$part"
        else
            say "The App Store has Xcode ${store:-(no answer)}, not $XCODE_VERSION: installing $XCODE_VERSION with xcodes, which asks for your Apple Account"
            xcodes install "$XCODE_VERSION"
        fi
        XCODE_APP="$(matching_xcode || true)"
    fi
    if [ -z "$XCODE_APP" ]; then
        local app
        for app in /Applications/Xcode*.app; do
            if [ -d "$app" ]; then
                XCODE_APP="$app"
            fi
        done
        [ -n "$XCODE_APP" ] || fail "there's no Xcode in /Applications"
        note "no Xcode with the main Mac's build ($XCODE_VERSION, $XCODE_BUILD) is installed, so this uses $XCODE_APP ($(xcode_field "$XCODE_APP" CFBundleShortVersionString), $(xcode_field "$XCODE_APP" ProductBuildVersion)); install the main Mac's with \`xcodes install $XCODE_VERSION\` and run this again"
    fi
    say "Xcode: $XCODE_APP"
    sudo xcode-select --switch "$XCODE_APP/Contents/Developer"
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
    local metal
    metal="$(xcodebuild -showComponent MetalToolchain 2>/dev/null || true)"
    case "$metal" in
        *"Status: installed"*) ;;
        *)
            say "Downloading Xcode's Metal toolchain, which compiles the Metal kernels"
            xcodebuild -downloadComponent MetalToolchain || sudo xcodebuild -downloadComponent MetalToolchain
            ;;
    esac
    if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
        say "Downloading the iOS platform: the workspace builds the Bench app's framework for iOS too"
        xcodebuild -downloadPlatform iOS || sudo xcodebuild -downloadPlatform iOS
    fi
    # Lets the test runners and debugger start without asking for authorization.
    sudo DevToolsSecurity -enable >/dev/null
    sudo dseditgroup -o edit -a "$USER" -t user _developer
}

# The file with this script's block in it once, holding these lines.
write_block() {
    local file="$1" kept
    shift
    kept="$(mktemp -t zsh-startup)"
    touch "$file"
    awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" \
        '$0 == begin { skip = 1 } !skip { print } $0 == end { skip = 0 }' "$file" >"$kept"
    {
        cat "$kept"
        echo "$BLOCK_BEGIN"
        printf '%s\n' "$@"
        echo "$BLOCK_END"
    } >"$file"
    rm -f "$kept"
}

shell_environment() {
    # A command run over SSH reads only ~/.zshenv; Terminal's login shell then runs path_helper,
    # which puts the system's folders first again, so ~/.zprofile puts Homebrew's back in front.
    say "PATH for commands run over SSH (~/.zshenv) and in Terminal (~/.zprofile)"
    # shellcheck disable=SC2016
    write_block "$HOME/.zshenv" \
        'case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH" ;; esac' \
        'export MISE_TRUSTED_CONFIG_PATHS="$HOME/src/build-mac"'
    # shellcheck disable=SC2016
    write_block "$HOME/.zprofile" 'eval "$(/opt/homebrew/bin/brew shellenv)"'
    export MISE_TRUSTED_CONFIG_PATHS="$ROOT"
}

mise_tools() {
    say "mise's tools (mise.toml): Tuist, SwiftFormat, SwiftLint and Node"
    (cd "$CLONE" && mise install)
}

fixtures() {
    say "Sample raws from raw.pixls.us (tests/fixtures, 2.1 GB)"
    (cd "$CLONE" && mise run fixtures && mise run fixtures-shoots) \
        || note "some sample raws didn't download, so the tests that need them skip: run \`mise run fixtures\` and \`mise run fixtures-shoots\` in $CLONE again"
}

generate() {
    say "Vendored LibRaw, the Swift packages and the workspace (mise run generate)"
    (cd "$CLONE" && mise run generate)
}

remote_login() {
    nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1
}

settings() {
    # The regression suite drives the app on screen, so the display stays on too.
    say "Power: on the charger, no sleep, the display's included, and wake for network access"
    sudo pmset -c sleep 0 displaysleep 0 disksleep 0 womp 1
    # Closing a laptop's lid puts it to sleep unless it's on power with a display connected. This
    # undocumented setting, which the tools for keeping a Mac awake closed use, keeps it awake
    # whatever is connected, on battery too, so it isn't for a Mac carried closed in a bag.
    say "Lid: no sleep when it's closed (sudo pmset -a disablesleep 0 undoes it)"
    sudo pmset -a disablesleep 1
    local disabled
    disabled="$(pmset -g | awk '/SleepDisabled/ { print $2 }')"
    [ "$disabled" = 1 ] \
        || note "pmset didn't take disablesleep, so closing the lid still sleeps this Mac: keep a display or dummy plug connected"

    say "Screen lock: off, and no screen saver (sysadminctl asks for this account's password)"
    sysadminctl -screenLock off -password - \
        || note "turn off the password after the screen saver or display (System Settings › Lock Screen)"
    defaults -currentHost write com.apple.screensaver idleTime -int 0

    say "Updates: no automatic macOS or App Store installs"
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
    sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
    note "check that automatic macOS updates are off (System Settings › General › Software Update) and so are the App Store's (App Store › Settings), since Xcode updating itself would leave the Macs on different versions"

    if remote_login; then
        say "Remote Login: on"
    else
        sudo systemsetup -setremotelogin on >/dev/null 2>&1 || true
        if remote_login; then
            say "Remote Login: turned on"
        else
            note "turn on Remote Login for $USER (System Settings › General › Sharing)"
        fi
    fi

    local vault login
    vault="$(fdesetup status 2>/dev/null || true)"
    login="$(sysadminctl -autologin status 2>&1 || true)"
    case "$vault" in
        *"FileVault is On"*)
            note "FileVault is on, so macOS can't log in by itself: after each restart, log in once before the build Mac serves again (or turn FileVault off in Privacy & Security and run this again)"
            ;;
        *)
            case "$login" in
                *"$USER"*) say "Automatic login: $USER" ;;
                *)
                    say "Automatic login as $USER (sysadminctl asks for this account's password)"
                    sudo sysadminctl -autologin set -userName "$USER" -password - \
                        || note "set Automatically log in as $USER (System Settings › Users & Groups)"
                    ;;
            esac
            ;;
    esac

    tmutil addexclusion "$ROOT" >/dev/null 2>&1 || true
}

check_gate() {
    say "The push gate on origin/main: a build of everything and the reference tests"
    if ! (cd "$CLONE" && scripts/push-gate.py); then
        note "the push gate failed on origin/main; its logs are in $CLONE/build/push-gate/logs"
        return 1
    fi
}

report() {
    local metal host
    metal="$(xcodebuild -showComponent MetalToolchain 2>/dev/null | awk -F': ' '/^Build Version/ { print $2 }' || true)"
    host="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
    say "This Mac, against the main Mac's versions:"
    printf '    %-16s %s\n' \
        "macOS" "$(sw_vers -productVersion) (main Mac: $MACOS_VERSION)" \
        "Xcode" "$(xcode_field "$XCODE_APP" CFBundleShortVersionString) ($(xcode_field "$XCODE_APP" ProductBuildVersion)) (main Mac: $XCODE_VERSION, $XCODE_BUILD)" \
        "Metal toolchain" "${metal:-not installed}" \
        "iOS SDK" "$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo missing)" \
        "Python" "$(python3 --version 2>&1)"
    (cd "$CLONE" && mise ls --current 2>/dev/null | sed 's/^/    /') || true
    if [ "${#NOTES[@]}" -gt 0 ]; then
        say "Still to do here, by hand:"
        local item
        for item in ${NOTES[@]+"${NOTES[@]}"}; do
            printf '    - %s\n' "$item"
        done
    fi
    cat <<EOF
==> Then, on the main Mac, in your own Terminal:
    ssh-keygen -t ed25519 -f ~/.ssh/build-mac -C build-mac
    ssh-copy-id -i ~/.ssh/build-mac.pub $USER@$host
    and add to ~/.ssh/config:
        Host build-mac
            HostName $host
            User $USER
            IdentityFile ~/.ssh/build-mac
    An hour after closing this Mac's lid, check it from there:
    ssh -o ConnectTimeout=3 build-mac 'sw_vers -productVersion; xcodebuild -version'
EOF
}

main() {
    parse "$@"
    preflight
    keep_sudo
    caffeinate -i -w "$$" &
    homebrew
    clone
    tools
    xcode
    shell_environment
    mise_tools
    [ "$FIXTURES" = 0 ] || fixtures
    generate
    [ "$SETTINGS" = 0 ] || settings
    local failed=0
    [ "$GATE" = 0 ] || check_gate || failed=1
    report
    return "$failed"
}

# On one line, so bash has read all of it before the clone's checkout can replace this file.
main "$@"; exit
