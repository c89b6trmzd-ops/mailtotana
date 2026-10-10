#!/bin/zsh
#-------------------------------------------------------------------------------
# MailToTana - install.sh
#
# Sets MailToTana up on this Mac. Idempotent: running it again after a change in
# the source updates the installation.
#
# Run it from the folder that holds the source files:
#     /bin/zsh install.sh
#
# What happens:
#     1. "MailToTana.applescript"  ->  ~/Library/Scripts/MailToTana.scpt
#     2. "mailtotana-helper.sh"    ->  ~/bin/mailtotana-helper.sh   (mode 755)
#     3. three Quick Actions       ->  ~/Library/Services/
#     4. refresh the Services menu
#     5. ask for a keyboard shortcut, and assign it
#     6. check what still has to be done outside this script
#     7. settings: ask your running Tana which supertags and fields to use, and
#        write them to ~/.config/mailtotana/config.txt
#
# There used to be a bulk variant, which would process a manual selection
# without thread expansion. It was dropped on 30 July 2026 because Tana needs
# about 0.2 seconds per node it creates; large selections therefore give long
# waits. A bundle from an older installation is cleaned up.
#
# INSTALLING ON A SECOND MACHINE
#
# The Keychain does not sync through iCloud, so both secrets have to be entered
# on every Mac separately: the Anthropic API key by hand, the Tana token by this
# script.
#
# For the Tana token: make your OWN Personal Token per machine with a
# recognisable name. Then you can revoke one without silencing the other.
# VERIFIED on 20 August 2026 during the installation on a second Mac: two
# Personal Tokens on the same graph simply work side by side. The token of the
# first Mac stayed valid while the one for the second was created and used.
# The Tana documentation says nothing about this; it was established empirically.
#
# The Anthropic key may be the same on both machines (it is not device-bound),
# but creating a second key has the same advantage: revocable per machine.
#
# Nothing is needed on the Tana side: supertags, fields and the Open-in-Mail
# button live in the graph and sync along.
#
# What does NOT happen, and so has to be done by hand:
#     * put the Anthropic API key in the Keychain
#       (see the README, section "Anthropic API key")
#     * approve Automation permissions; macOS asks for them at the first run
#     * attach a function key in
#       System Settings > Keyboard > Keyboard Shortcuts > Services
#-------------------------------------------------------------------------------
#
# ARCHITECTURE: WHO DOES WHAT
#
#     Quick Action stub  ->  MailToTana.scpt  ->  mailtotana-helper.sh  ->  clipboard
#      (23 lines, no         (talks to Mail,      (zsh bootstrap +
#       logic)                writes a /tmp file)   Python: API + Tana Paste)
#
# That is why this installer knows only two source files. The stubs are generated
# here from STUB_TEMPLATE and deliberately contain no logic: an earlier version
# had the complete routine both in the .scpt and in document.wflow, and a change
# in one of the two places gave a difference in behaviour between the shortcut
# and the menu.
#
# Links that break if you rename something:
#     * MailToTanaMainRoutine  -- that name is in STUB_TEMPLATE below and must
#       stay equal to the handler in the AppleScript
#     * the separators RS/US/GS and the seven fields of the exchange record are
#       fixed on both sides of the chain
#       (BuildExchangeRecordForMessage <-> read_the_exchange_file)
#     * the file names mailtotana-helper.sh, /tmp/mailtotana-in.txt and
#       /tmp/mailtotana-out.txt appear both here and in the AppleScript
#     * the Tana supertag and field IDs live only in config.txt, which the Python
#       helper inside mailtotana-helper.sh reads
#-------------------------------------------------------------------------------

set -euo pipefail

#-------------------------------------------------------------------------------
# Paths
#
# The source folder is derived from the location of this script itself, so that
# it works from a USB stick, from iCloud or from a git checkout.
#-------------------------------------------------------------------------------
readonly PATH_OF_THE_SOURCE_FOLDER="${0:A:h}"
readonly PATH_OF_THE_APPLESCRIPT_SOURCE="$PATH_OF_THE_SOURCE_FOLDER/MailToTana.applescript"
readonly PATH_OF_THE_SHELL_HELPER_SOURCE="$PATH_OF_THE_SOURCE_FOLDER/mailtotana-helper.sh"

readonly PATH_OF_THE_SCRIPTS_FOLDER="$HOME/Library/Scripts"
readonly PATH_OF_THE_COMPILED_SCRIPT="$PATH_OF_THE_SCRIPTS_FOLDER/MailToTana.scpt"
readonly PATH_OF_THE_BIN_FOLDER="$HOME/bin"
readonly PATH_OF_THE_SERVICES_FOLDER="$HOME/Library/Services"

print "Installing MailToTana from: $PATH_OF_THE_SOURCE_FOLDER"

#-------------------------------------------------------------------------------
# 1. Compile the AppleScript
#
# osacompile is also the syntax check: on an error the installation stops here
# and nothing has changed yet in your existing installation.
#-------------------------------------------------------------------------------
if [[ ! -r "$PATH_OF_THE_APPLESCRIPT_SOURCE" ]]; then
    print -u2 "Source not found: $PATH_OF_THE_APPLESCRIPT_SOURCE"
    exit 66
fi

#-------------------------------------------------------------------------------
# Find missing handlers
#
# osacompile does NOT check this: a call to a handler that does not exist
# compiles without complaint and only blows up while running, in Mail, with
# "«script» does not understand the message 'X'". Exactly what happened when a
# helper handler had been removed while the call stayed. This check catches that
# before the installation touches anything.
#-------------------------------------------------------------------------------
PATH_OF_THE_APPLESCRIPT_SOURCE_FOR_PYTHON="$PATH_OF_THE_APPLESCRIPT_SOURCE" /usr/bin/python3 - <<'PYTHON_EOF'
import os
import re
import sys

the_source = open(os.environ["PATH_OF_THE_APPLESCRIPT_SOURCE_FOR_PYTHON"], encoding="utf-8").read()

# drop the comment lines: they contain examples that are not real calls
the_code = "\n".join(
    the_line for the_line in the_source.splitlines()
    if not the_line.lstrip().startswith("--")
)

the_defined = set(re.findall(r"^on\s+([A-Za-z_]\w*)\s*\(", the_code, re.MULTILINE))
the_called = set(re.findall(r"\bmy\s+([A-Za-z_]\w*)\s*\(", the_code))

the_missing = sorted(the_called - the_defined)

if the_missing:
    sys.exit("Called but not defined: " + ", ".join(the_missing))
PYTHON_EOF

/bin/mkdir -p "$PATH_OF_THE_SCRIPTS_FOLDER"
/usr/bin/osacompile -o "$PATH_OF_THE_COMPILED_SCRIPT" "$PATH_OF_THE_APPLESCRIPT_SOURCE"
print "  [1/4] compiled      -> $PATH_OF_THE_COMPILED_SCRIPT"

#-------------------------------------------------------------------------------
# 2. Place the shell helper
#-------------------------------------------------------------------------------
if [[ ! -r "$PATH_OF_THE_SHELL_HELPER_SOURCE" ]]; then
    print -u2 "Source not found: $PATH_OF_THE_SHELL_HELPER_SOURCE"
    exit 66
fi

/bin/mkdir -p "$PATH_OF_THE_BIN_FOLDER"
/bin/cp "$PATH_OF_THE_SHELL_HELPER_SOURCE" "$PATH_OF_THE_BIN_FOLDER/mailtotana-helper.sh"
/bin/chmod 755 "$PATH_OF_THE_BIN_FOLDER/mailtotana-helper.sh"
print "  [2/4] helper        -> $PATH_OF_THE_BIN_FOLDER/mailtotana-helper.sh"

#-------------------------------------------------------------------------------
# 3. Generate the Quick Actions, and clean up an old one
#
# A .workflow is a folder with Info.plist and document.wflow. Both are plists,
# so we build them with python3 instead of dragging them along as binary blobs.
#
# The stubs deliberately contain no logic: that lives in the .scpt. An earlier
# version had the complete code in both the .scpt and document.wflow, so that a
# change in one copy did not reach the other.
#-------------------------------------------------------------------------------
/bin/mkdir -p "$PATH_OF_THE_SERVICES_FOLDER"

export PATH_OF_THE_SERVICES_FOLDER PATH_OF_THE_COMPILED_SCRIPT

/usr/bin/python3 - <<'PYTHON_EOF'
# -*- coding: utf-8 -*-

import os
import plistlib
import shutil
import uuid

THE_SERVICES_FOLDER = os.environ["PATH_OF_THE_SERVICES_FOLDER"]
THE_COMPILED_SCRIPT = os.environ["PATH_OF_THE_COMPILED_SCRIPT"]

STUB_TEMPLATE = '''--------------------------------------------------------------------------------
-- MailToTana - Quick Action stub, destination "{destination}", output "{outputtype}"
--
-- Deliberately contains NO logic. All the code is in:
--     {script}
--
-- The only content of its own is the two words below. All Quick Actions load the
-- same .scpt; they differ only in that and in their key combination.
--
-- Reason: an earlier version had the complete routine both in the .scpt and here
-- in document.wflow. Two copies of the same 300 lines meant that a change in one
-- did not reach the other.
--
-- So make changes in "MailToTana.applescript", followed by "install.sh".
--------------------------------------------------------------------------------
on run {{input, parameters}}

	set theCompiledScriptFile to POSIX file "{script}"
	set theMailToTanaScript to load script theCompiledScriptFile

	tell theMailToTanaScript to MailToTanaMainRoutine("{destination}", "{outputtype}")

	return input

end run
'''


def build_the_info_plist(the_menu_item_name):
    """Info.plist of a Quick Action.

    NSRequiredContext limits the service to Mail, so that it does not show up in
    the Services menu of other apps. There are deliberately no NSSendTypes: the
    script reads the selection itself through the Mail dictionary and so needs no
    input from the Services system."""
    return {
        "NSServices": [
            {
                "NSBackgroundColorName": "background",
                "NSIconName": "NSActionTemplate",
                "NSMenuItem": {"default": the_menu_item_name},
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.mail"},
            }
        ]
    }


def build_the_workflow_document(the_applescript_source):
    """document.wflow with a single action: Run AppleScript.

    The structure follows that of a working workflow; only the UUIDs are new per
    bundle, because Automator uses them to identify actions."""
    return {
        "AMApplicationBuild": "534",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "actions": [
            {
                "action": {
                    "AMAccepts": {
                        "Container": "List",
                        "Optional": True,
                        "Types": ["com.apple.applescript.object"],
                    },
                    "AMActionVersion": "1.0.2",
                    "AMApplication": ["Automator"],
                    "AMParameterProperties": {"source": {}},
                    "AMProvides": {
                        "Container": "List",
                        "Types": ["com.apple.applescript.object"],
                    },
                    "ActionBundlePath": "/System/Library/Automator/Run AppleScript.action",
                    "ActionName": "Run AppleScript",
                    "ActionParameters": {"source": the_applescript_source},
                    "BundleIdentifier": "com.apple.Automator.RunScript",
                    "CFBundleVersion": "1.0.2",
                    "CanShowSelectedItemsWhenRun": False,
                    "CanShowWhenRun": True,
                    "Category": ["AMCategoryUtilities"],
                    "Class Name": "RunScriptAction",
                    "InputUUID": str(uuid.uuid4()).upper(),
                    "OutputUUID": str(uuid.uuid4()).upper(),
                    "UUID": str(uuid.uuid4()).upper(),
                    "UnlocalizedApplications": ["Automator"],
                    "conversionLabel": 0,
                    "isViewVisible": 1,
                    "location": "309.000000:253.000000",
                    "nibPath": "/System/Library/Automator/Run AppleScript.action/Contents/Resources/Base.lproj/main.nib",
                }
            }
        ],
        "connectors": {},
        "workflowMetaData": {
            "applicationBundleID": "com.apple.mail",
            "applicationBundleIDsByPath": {"/System/Applications/Mail.app": "com.apple.mail"},
            "applicationPath": "/System/Applications/Mail.app",
            "applicationPaths": ["/System/Applications/Mail.app"],
            "inputTypeIdentifier": "com.apple.Automator.nothing",
            "outputTypeIdentifier": "com.apple.Automator.nothing",
            "presentationMode": 11,
            "processesInput": False,
            "serviceApplicationBundleID": "com.apple.mail",
            "serviceApplicationPath": "/System/Applications/Mail.app",
            "serviceInputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceProcessesInput": False,
            "systemImageName": "NSActionTemplate",
            "useAutomaticInputType": True,
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
        },
    }


def write_the_workflow_bundle(the_bundle_file_name, the_menu_item_name, the_destination, the_output_type):
    the_bundle_path = os.path.join(THE_SERVICES_FOLDER, the_bundle_file_name)
    the_contents_path = os.path.join(the_bundle_path, "Contents")

    # remove the existing bundle first: a half overwritten bundle does not work
    if os.path.isdir(the_bundle_path):
        shutil.rmtree(the_bundle_path)

    os.makedirs(the_contents_path)

    the_stub_source = STUB_TEMPLATE.format(script=THE_COMPILED_SCRIPT, destination=the_destination, outputtype=the_output_type)

    with open(os.path.join(the_contents_path, "Info.plist"), "wb") as the_file:
        plistlib.dump(build_the_info_plist(the_menu_item_name), the_file)

    with open(os.path.join(the_contents_path, "document.wflow"), "wb") as the_file:
        plistlib.dump(build_the_workflow_document(the_stub_source), the_file)

    print("  [3/4] Quick Action  -> {path}   (menu: \"{menu}\")".format(path=the_bundle_path, menu=the_menu_item_name))


def remove_the_workflow_bundle(the_bundle_file_name):
    """Really remove a bundle that we no longer install.

    Without this a Quick Action from an earlier installation stays in the
    Services menu, and that is exactly the confusion we want to avoid."""
    the_bundle_path = os.path.join(THE_SERVICES_FOLDER, the_bundle_file_name)

    if os.path.isdir(the_bundle_path):
        shutil.rmtree(the_bundle_path)
        print("  [3/4] cleaned up    -> {path}".format(path=the_bundle_path))


# Three Quick Actions, one code base. They load the same .scpt and only pass a
# different destination and a different output type.
#
# The fourth combination, a task on the clipboard, is deliberately not made: a
# task you want in Tana and not in a paste buffer.
write_the_workflow_bundle("MailToTana.workflow", "MailToTana", "clipboard", "message")
write_the_workflow_bundle("MailToTana to Today.workflow", "MailToTana to Today", "today", "message")
write_the_workflow_bundle("MailToTask.workflow", "MailToTask", "today", "task")

# the bulk variant was dropped; clean up a bundle from an older installation
remove_the_workflow_bundle("MailToTana bulk.workflow")
PYTHON_EOF

#-------------------------------------------------------------------------------
# 4. Refresh the Services menu
#
# Without this step a new Quick Action only shows up after logging out.
#-------------------------------------------------------------------------------
/System/Library/CoreServices/pbs -flush
print "  [4/4] Services menu refreshed"

#-------------------------------------------------------------------------------
# Read which shortcut is attached to each service
#
# Used in two places: below when asking, so that you see what is already there,
# and at the very end with the checks. That is why it sits here and not at one
# of the two.
#-------------------------------------------------------------------------------
readonly THE_SHORTCUT_PROBE='
import plistlib
import subprocess

subprocess.run(["/usr/bin/defaults", "export", "pbs", "/tmp/pbs-check.plist"], check=True)
the_status = plistlib.load(open("/tmp/pbs-check.plist", "rb")).get("NSServicesStatus", {})
the_names = {"@": "Cmd", "^": "Ctrl", "~": "Opt", "$": "Shift"}


def describe(the_key):
    the_parts = []
    while the_key and the_key[0] in the_names:
        the_parts.append(the_names[the_key[0]])
        the_key = the_key[1:]
    if len(the_key) == 1 and ord(the_key) >= 0xF704:
        the_key = "F" + str(ord(the_key) - 0xF704 + 1)
    return "+".join(the_parts + [the_key.upper()])


# Show all of them, because forgetting to set one is exactly the kind of thing
# you only notice when you press the key and nothing happens.
for the_menu_name in ("MailToTana", "MailToTana to Today", "MailToTask"):
    the_entry = the_status.get("(null) - " + the_menu_name + " - runWorkflowAsService", {})
    the_key = the_entry.get("key_equivalent")
    print("{name}\t{key}".format(name=the_menu_name, key=describe(the_key) if the_key else ""))
'

#-------------------------------------------------------------------------------
# 5. Assign a keyboard shortcut
#
# For each service macOS stores in the pbs domain whether it is in the Services
# menu and which key combination is attached to it. That can be set without
# opening System Settings, so we do it here.
#
# ASK and do not impose: whoever installs this on another Mac has already given
# away their own combinations, and an installation should not take a key that you
# use for something else. An empty answer skips the step.
#
# Without a terminal (for instance called from another script) we skip the
# question instead of waiting for input that never comes.
#-------------------------------------------------------------------------------
print ""

if [[ ! -t 0 ]]; then

    print "Shortcut: skipped, no input available."

else

    print "Three Quick Actions, so three key combinations. All three inside Apple Mail."
    print "  Examples: cmd+shift+8   ctrl+opt+m   F6   cmd+F6"
    print "  Leave empty to keep what is already there."

    #---------------------------------------------------------------------------
    # First fetch what is attached to each service NOW
    #
    # Without this the three questions look identical and you do not know which
    # one you are answering. On 5 August 2026 that resulted in a missed key: the
    # first two had to be skipped, and then the third was skipped as well. By
    # showing what is already there you see at once which one is empty.
    #---------------------------------------------------------------------------
    typeset -A THE_CURRENT_SHORTCUTS
    while IFS=$'\t' read -r THE_NAME THE_KEY; do
        THE_CURRENT_SHORTCUTS[$THE_NAME]="$THE_KEY"
    done < <(/usr/bin/python3 -c "$THE_SHORTCUT_PROBE" 2>/dev/null || true)

  for THE_SERVICE in "MailToTana:message to the clipboard" "MailToTana to Today:message under Today in Tana" "MailToTask:task under Today in Tana"; do

    THE_SERVICE_MENU_NAME="${THE_SERVICE%%:*}"
    THE_SERVICE_PURPOSE="${THE_SERVICE#*:}"
    THE_EXISTING_SHORTCUT="${THE_CURRENT_SHORTCUTS[$THE_SERVICE_MENU_NAME]:-}"

    print ""
    if [[ -n "$THE_EXISTING_SHORTCUT" ]]; then
        print "  \"$THE_SERVICE_MENU_NAME\"  ($THE_SERVICE_PURPOSE)  --  currently set to $THE_EXISTING_SHORTCUT"
    else
        print "  \"$THE_SERVICE_MENU_NAME\"  ($THE_SERVICE_PURPOSE)  --  NO KEY YET"
    fi

    THE_ATTEMPT=1
    while (( THE_ATTEMPT <= 3 )); do

        # "|| THE_ANSWER=''" is not sloppiness here but a necessity. This script
        # runs under "set -e", and read returns a 1 as soon as the input runs out
        # (Ctrl-D, or driven from another script). Without this catch the
        # installation stops silently at that moment, in the middle of the
        # question: no error message, no next question, no checks. Exactly that
        # happened on 5 August 2026, so that the second key was never asked for
        # and it looked as if the question had been skipped.
        THE_ANSWER=""
        read -r "THE_ANSWER?    Combination: " || THE_ANSWER=""

        if [[ -z "$THE_ANSWER" ]]; then
            print "    Skipped."
            break
        fi

        if THE_KEY_INPUT="$THE_ANSWER" THE_SERVICE_MENU_NAME="$THE_SERVICE_MENU_NAME" /usr/bin/python3 - <<'PYTHON_EOF'
import os
import plistlib
import subprocess
import sys

# In the pbs format the symbols for the modifier keys come first.
THE_MODIFIER_SYMBOLS = {
    "cmd": "@", "command": "@", "⌘": "@",
    "ctrl": "^", "control": "^", "⌃": "^",
    "opt": "~", "alt": "~", "option": "~", "⌥": "~",
    "shift": "$", "⇧": "$",
}

# Fixed order, so that the same combination always gives the same text.
THE_MODIFIER_ORDER = "@^~$"

# In AppKit, function keys are characters from the private-use area:
# NSF1FunctionKey is 0xF704 and counting up from there.
THE_FIRST_FUNCTION_KEY_CODE = 0xF704

THE_SERVICE_NAME = "(null) - " + os.environ["THE_SERVICE_MENU_NAME"] + " - runWorkflowAsService"


def parse_the_combination(the_text):
    """Turns "cmd+shift+8" into "@$8". Returns None for nonsense."""
    the_pieces = [
        the_piece.strip().lower()
        for the_piece in the_text.replace("+", " ").replace("-", " ").split()
        if the_piece.strip()
    ]

    # no separators used, so symbols run together: "⌘⇧8"
    if len(the_pieces) == 1 and len(the_pieces[0]) > 1:
        the_symbols = [c for c in the_pieces[0] if c in THE_MODIFIER_SYMBOLS]
        if the_symbols:
            the_rest = "".join(c for c in the_pieces[0] if c not in THE_MODIFIER_SYMBOLS)
            the_pieces = the_symbols + ([the_rest] if the_rest else [])

    if not the_pieces:
        return None

    the_modifiers = set()
    the_key = None

    for the_piece in the_pieces:
        if the_piece in THE_MODIFIER_SYMBOLS:
            the_modifiers.add(THE_MODIFIER_SYMBOLS[the_piece])
        elif the_key is None:
            the_key = the_piece
        else:
            return None

    if the_key is None:
        return None

    if len(the_key) > 1:
        if the_key.startswith("f") and the_key[1:].isdigit() and 1 <= int(the_key[1:]) <= 12:
            the_key = chr(THE_FIRST_FUNCTION_KEY_CODE + int(the_key[1:]) - 1)
        else:
            return None

    the_prefix = "".join(m for m in THE_MODIFIER_ORDER if m in the_modifiers)
    return the_prefix + the_key


def describe(the_key_equivalent):
    """Readable form, for the confirmation on screen."""
    the_names = {"@": "Cmd", "^": "Ctrl", "~": "Opt", "$": "Shift"}
    the_parts = []
    the_rest = the_key_equivalent
    while the_rest and the_rest[0] in the_names:
        the_parts.append(the_names[the_rest[0]])
        the_rest = the_rest[1:]
    if len(the_rest) == 1 and ord(the_rest) >= THE_FIRST_FUNCTION_KEY_CODE:
        the_rest = "F" + str(ord(the_rest) - THE_FIRST_FUNCTION_KEY_CODE + 1)
    return "+".join(the_parts + [the_rest.upper()])


the_key_equivalent = parse_the_combination(os.environ["THE_KEY_INPUT"])

if the_key_equivalent is None:
    sys.exit("  Cannot be read as a key combination. Try for instance cmd+shift+8.")

subprocess.run(["/usr/bin/defaults", "export", "pbs", "/tmp/pbs-before-mailtotana.plist"], check=True)

with open("/tmp/pbs-before-mailtotana.plist", "rb") as the_file:
    the_preferences = plistlib.load(the_file)

the_status = the_preferences.setdefault("NSServicesStatus", {})

# Collisions. Other MailToTana services we may clean up: they belong to the same
# family and an old version should not hold on to the key. A service of somebody
# else we stay away from, and only warn.
for the_name, the_entry in the_status.items():
    if the_name == THE_SERVICE_NAME:
        continue
    if the_entry.get("key_equivalent") != the_key_equivalent:
        continue
    the_readable = the_name.replace("(null) - ", "").replace(" - runWorkflowAsService", "")
    if "ailtoTana" in the_name or "ailToTana" in the_name:
        del the_entry["key_equivalent"]
        print("  key removed from older version: " + the_readable)
    else:
        print("  NOTE: " + the_readable + " uses this combination too.")

the_status[THE_SERVICE_NAME] = {
    "key_equivalent": the_key_equivalent,
    "presentation_modes": {"ContextMenu": True, "ServicesMenu": True, "TouchBar": True},
}

with open("/tmp/pbs-after-mailtotana.plist", "wb") as the_file:
    plistlib.dump(the_preferences, the_file)

subprocess.run(["/usr/bin/defaults", "import", "pbs", "/tmp/pbs-after-mailtotana.plist"], check=True)

print("  assigned: " + describe(the_key_equivalent))
PYTHON_EOF
        then
            /System/Library/CoreServices/pbs -flush
            break
        fi

        (( THE_ATTEMPT++ ))

    done

  done

  print ""
  print "  Restart Mail before the keys work."

fi

#-------------------------------------------------------------------------------
# 6. Pre-flight: the things that lie outside this script
#
# Everything below is a precondition that the installation cannot set itself,
# and each of them gives a SILENT error if it is missing. Without Contacts access
# there are e-mail addresses instead of names in your Tana nodes; without an API
# key you only get an error message at the first run in Mail. Better to see
# right here what is still missing.
#
# IMPORTANT LIMITATION: the tests below run under the app that YOU start this
# script from, usually Terminal. Automation rights depend on the calling app, so
# a tick for Terminal does not mean that the Quick Action has them too. macOS
# asks for those separately, at the first run from Mail. This test therefore
# shows whether the set-up is right, not whether Automator already has
# permission.
#-------------------------------------------------------------------------------
print ""
print "Checks:"

# ---- the API key --------------------------------------------------------------
if /usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s anthropic-api-key -w >/dev/null 2>&1; then
    print "  [ok]  Anthropic API key found in the Keychain"
else
    print "  [!!]  NO API key in the Keychain. Nothing works without it:"
    print "            security add-generic-password -a \"\$USER\" -s anthropic-api-key -j \"Used by ~/bin/mailtotana-helper.sh\" -U -w"
    print "        See the README, section \"Anthropic API key\""
fi

# ---- the local Tana API -------------------------------------------------------
#
# Only needed for the variant that writes directly under Today. If the token is
# missing or Tana is closed, that variant falls back to the clipboard; so it is
# no blocker, but you do want to know.
if /usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s tana-local-api-token -w >/dev/null 2>&1; then
    if /usr/bin/curl -s --max-time 5 -o /dev/null -w '' http://localhost:8262/health 2>/dev/null; then
        print "  [ok]  Tana token present and the local API answers"
    else
        print "  [--]  Tana token present, but the local API does not answer."
        print "        Start Tana Outliner; the API runs inside the app itself."
    fi
else

    print "  [!!]  NO Tana Personal Token in the Keychain. \"MailToTana to"
    print "        Today\" then always falls back to the clipboard."

    if [[ -t 0 ]]; then

        #-----------------------------------------------------------------------
        # Being able to store the token straight away
        #
        # NOT through "security add-generic-password -w" without a value, however
        # tempting that form is. It asks for the value itself with an invisible
        # input line, but TRUNCATES AT 128 CHARACTERS. A Tana Personal Token is a
        # JWT of around 250 characters, so you keep half a token. It is stored
        # neatly, there is no warning at all, and only at the first call Tana says
        # "unauthorized" (HTTP 401) without telling you why. Seen on 5 August
        # 2026: 249 characters in, 128 out.
        #
        # What we do use is "security -i": it reads its commands from stdin, so the
        # value goes in through a here-document and does NOT appear in the process
        # table. That was the reason for choosing the interactive form, and that
        # reason still stands. No length limit.
        #
        # We read the value ourselves with "read -rs": silent, without echo on the
        # screen, and without the truncation that the prompt of security does have.
        #-----------------------------------------------------------------------
        print ""
        print "        You make a token in Tana Outliner:"
        print "          profile top right > API tokens > Personal Tokens tab"
        print "          > Create token > Copy"
        print ""

        # same catch as with the key question: read fails at the end of the
        # input, and under "set -e" that is the end of the whole script
        THE_WANTS_TOKEN=""
        read -r "THE_WANTS_TOKEN?        Store the token in the Keychain now? (y/n) " || THE_WANTS_TOKEN=""

        if [[ "$THE_WANTS_TOKEN" == (j|J|ja|Ja|y|Y|yes) ]]; then

            print -n "        Paste the token and press Enter (you will see nothing appear): "
            THE_PASTED_TOKEN=""
            read -rs THE_PASTED_TOKEN || THE_PASTED_TOKEN=""
            print ""

            if [[ -z "$THE_PASTED_TOKEN" ]]; then

                print "        Nothing pasted, so nothing stored."

            else

                # A Personal Token is a JWT: three pieces with dots between them,
                # around 250 characters. If it is noticeably shorter, something
                # went wrong with pasting and we say so now, instead of letting
                # you search tomorrow for an inexplicable 401.
                if (( ${#THE_PASTED_TOKEN} < 100 )); then
                    print "        NOTE: only ${#THE_PASTED_TOKEN} characters. That does not look like a complete token."
                fi

                /usr/bin/security -i >/dev/null 2>&1 <<SECURITY_EOF
add-generic-password -a "$(/usr/bin/id -un)" -s tana-local-api-token -j "Local API of Tana Outliner, used by MailToTana" -U -w "$THE_PASTED_TOKEN"
SECURITY_EOF

                unset THE_PASTED_TOKEN

                # try it straight away: a token that Tana refuses is as useless
                # as no token, and you want to know that now
                THE_TOKEN="$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s tana-local-api-token -w 2>/dev/null)"
                THE_STATUS="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
                    -H "Authorization: Bearer $THE_TOKEN" \
                    http://localhost:8262/workspaces 2>/dev/null || print '000')"

                case "$THE_STATUS" in
                    200) print "        [ok]  Stored and working: Tana accepts the token (${#THE_TOKEN} characters)." ;;
                    401) print "        [!!]  Stored (${#THE_TOKEN} characters), but Tana REFUSES it." ;;
                    000) print "        [--]  Stored. Cannot be tested: Tana Outliner is not running." ;;
                    *)   print "        [--]  Stored. Tana answered with HTTP $THE_STATUS." ;;
                esac

                unset THE_TOKEN
            fi

        else
            print "        Skipped. Run this script again later to store it"
            print "        after all."
        fi

    else
        print "        Create one in Tana under profile > API tokens > Personal"
        print "        Tokens, and then run this script from a terminal:"
        print "        then it can store the token for you."
    fi

fi

# ---- Contacts -----------------------------------------------------------------
#
# Measures what the script itself does as well: start the app and try a lookup.
# Error -1743 is "user has refused permission", -600 is "app is not running".
# The latter cost a whole thread of names on 30 July 2026.
readonly THE_CONTACTS_PROBE='
tell application "Contacts" to launch
tell application "Contacts" to return (count of people) as text
'
if THE_COUNT="$(/usr/bin/osascript -e "$THE_CONTACTS_PROBE" 2>&1)"; then
    print "  [ok]  Contacts reachable, $THE_COUNT cards"
else
    print "  [!!]  Contacts NOT reachable: $THE_COUNT"
    print "        Without access, e-mail addresses end up in the Contactperson"
    print "        field instead of names. Tick Contacts under:"
    print "            System Settings > Privacy & Security > Automation"
    print "        If the app does not appear there, run this installation again"
    print "        and approve the dialog that macOS shows."
fi

# ---- Mail ---------------------------------------------------------------------
#
# Only look whether it is there. A script test would start Mail, and that is a
# heavier intervention than this check is worth.
if [[ -d /System/Applications/Mail.app || -d /Applications/Mail.app ]]; then
    print "  [ok]  Apple Mail present"
else
    print "  [!!]  Apple Mail not found; this tool only works with Apple Mail"
fi

# ---- the shortcut -------------------------------------------------------------
/usr/bin/python3 -c "$THE_SHORTCUT_PROBE" 2>/dev/null | while IFS=$'\t' read -r THE_NAME THE_KEY; do
    if [[ -n "$THE_KEY" ]]; then
        print "  [ok]  Shortcut \"$THE_NAME\": $THE_KEY"
    else
        print "  [--]  No shortcut for \"$THE_NAME\". Run this script again"
        print "        to give one."
    fi
done

#-------------------------------------------------------------------------------
# 7. Settings
#
# Runs last on purpose: it needs the Tana token, which the preflight above has
# just made sure exists, and it asks your running Tana what supertags and fields
# you actually have rather than making you look up identifiers by hand.
#
# Separate script rather than more lines here, so that changing one setting later
# does not mean reinstalling everything:
#
#     python3 configure.py
#
# The settings land in ~/.config/mailtotana/config.txt, outside the code, so
# installing a newer version never overwrites your answers.
#-------------------------------------------------------------------------------
print ""

THE_CONFIGURATION_FILE="$HOME/.config/mailtotana/config.txt"

if [[ ! -t 0 ]]; then

    print "Settings: skipped, no input available. Run later:  python3 configure.py"

elif [[ -f "$THE_CONFIGURATION_FILE" ]]; then

    print "Settings already present: $THE_CONFIGURATION_FILE"
    print -n "Go through them again? (y/N) "
    read THE_ANSWER || THE_ANSWER=""

    if [[ "$THE_ANSWER" == (y|Y|j|J) ]]; then
        /usr/bin/python3 "$PATH_OF_THE_SOURCE_FOLDER/configure.py" || true
    else
        print "  Left as they were."
    fi

else

    /usr/bin/python3 "$PATH_OF_THE_SOURCE_FOLDER/configure.py" || true

fi

print ""
print "Done."
