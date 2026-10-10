#!/bin/zsh
#-------------------------------------------------------------------------------
# mailtotana-helper.sh
#
# Helper for "MailToTana.scpt". Reads the exchange file the AppleScript wrote,
# has Claude summarise each message to a length that scales with the message,
# and writes the result as Tana Paste.
#
# Usage:
#     mailtotana-helper.sh <input file> <output file> [clipboard|today] [message|task]
#
# It is called by the AppleScript; to test by hand:
#     /bin/zsh ~/bin/mailtotana-helper.sh /tmp/mailtotana-in.txt /tmp/out.txt
#
#-------------------------------------------------------------------------------
#
# ARCHITECTURE: WHO DOES WHAT
#
#     Quick Action stub  ->  MailToTana.scpt  ->  THIS FILE  ->  clipboard / Tana
#                            (talks to Mail)      (zsh + Python)
#
# The AppleScript is the only layer that can talk to Apple Mail. It hands over
# the raw message data through the exchange file in /tmp. This file has two
# layers:
#
#   * The ZSH LAYER (below, up to the heredoc) is only a bootstrap: check the
#     arguments, fetch the API key from the Keychain with /usr/bin/security,
#     and pass the settings on as environment variables. Needed because
#     AppleScript calls a shell through "do shell script", not an interpreter
#     directly, and because Keychain access is a shell command.
#
#   * The PYTHON HELPER (the heredoc, most of this file) does the real work:
#     parse the exchange file back into records, strip quoted text and
#     signatures, work out a target length per message, send the messages in
#     batches to the Claude API using tool use, and build the Tana Paste. The
#     Tana IDs come from config.txt (see config.example.txt); this is the only
#     place that formats the Tana Paste.
#
# Why Python and not plain zsh: building JSON and safely escaping mail text with
# quotes, backslashes and emoji is a source of silent errors in a shell.
# json.dumps() does not have that problem, and everything needed is in the
# standard library. No pip, no virtualenv, no dependencies.
#
#-------------------------------------------------------------------------------
#
# INSTALLATION (install.sh does all of this for you)
#
# 1. ANTHROPIC API KEY in the Keychain. All on one line:
#
#        security add-generic-password -a "$USER" -s anthropic-api-key -j "Used by ~/bin/mailtotana-helper.sh" -U -w
#
#    Check:
#        security find-generic-password -a "$USER" -s anthropic-api-key -w | cut -c1-14
#
#    If a Keychain dialog appears, choose "Always Allow" once, so that
#    /usr/bin/security ends up in the item's ACL. Otherwise it keeps asking
#    whenever this script runs from the Automator service.
#
#    The login keychain does not sync through iCloud: do this on every Mac.
#
# 2. PLACE THE FILE
#        mkdir -p ~/bin
#        cp "mailtotana-helper.sh" ~/bin/
#        chmod 755 ~/bin/mailtotana-helper.sh
#
# 3. DEPENDENCIES
#    Only what macOS ships itself: /bin/zsh, /usr/bin/security,
#    /usr/bin/python3 (Command Line Tools). No Homebrew, no pip.
#
#-------------------------------------------------------------------------------

set -euo pipefail

#-------------------------------------------------------------------------------
# Settings
#-------------------------------------------------------------------------------
readonly KEYCHAIN_SERVICE_NAME="anthropic-api-key"
readonly CLAUDE_MODEL_NAME="claude-sonnet-5"
readonly MESSAGES_PER_API_CALL=10
readonly SUMMARY_LENGTH_FRACTION=0.15

# The local API of Tana Outliner: it runs inside the desktop app itself, on
# localhost. It needs a Personal Token, kept in the Keychain under its own name.
readonly KEYCHAIN_TANA_TOKEN_SERVICE_NAME="tana-local-api-token"

#-------------------------------------------------------------------------------
# Check the arguments
#
# Two switches, and together they decide what kind of tool this is:
#
#   3rd  DESTINATION  "clipboard" puts the result on the clipboard,
#                     "today" writes it under today's day node in Tana
#   4th  OUTPUT TYPE  "message" makes #Message nodes (documenting),
#                     "task" makes a #task with a briefing (making work)
#
# If they are missing you get the clipboard with messages: the behaviour from
# before these switches existed.
#
# Not all four combinations are actually installed; the installer only sets up
# three Quick Actions. That the code can handle all of them costs nothing, and
# it saves an exception.
#-------------------------------------------------------------------------------
if [[ $# -lt 2 || $# -gt 4 ]]; then
    print -u2 "Usage: $0 <input file> <output file> [clipboard|today] [message|task]"
    exit 64
fi

readonly PATH_OF_THE_INPUT_FILE="$1"
readonly PATH_OF_THE_OUTPUT_FILE="$2"
readonly THE_DESTINATION="${3:-clipboard}"
readonly THE_OUTPUT_TYPE="${4:-message}"

if [[ "$THE_DESTINATION" != "clipboard" && "$THE_DESTINATION" != "today" ]]; then
    print -u2 "Unknown destination: $THE_DESTINATION (choose clipboard or today)"
    exit 64
fi

if [[ "$THE_OUTPUT_TYPE" != "message" && "$THE_OUTPUT_TYPE" != "task" ]]; then
    print -u2 "Unknown output type: $THE_OUTPUT_TYPE (choose message or task)"
    exit 64
fi

if [[ ! -r "$PATH_OF_THE_INPUT_FILE" ]]; then
    print -u2 "Input file not readable: $PATH_OF_THE_INPUT_FILE"
    exit 66
fi

#-------------------------------------------------------------------------------
# Fetch the API key from the Keychain
#
# Absolute paths, because this script runs through "do shell script" with a bare
# environment and does not inherit the user's PATH.
#-------------------------------------------------------------------------------
if ! ANTHROPIC_API_KEY="$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s "$KEYCHAIN_SERVICE_NAME" -w 2>/dev/null)"; then
    print -u2 "No API key found in the Keychain under service '$KEYCHAIN_SERVICE_NAME'. See the installation block at the top of this script."
    exit 69
fi
export ANTHROPIC_API_KEY

#-------------------------------------------------------------------------------
# Token for the local Tana API, only needed with destination "today"
#
# If it is missing that is NOT a reason to stop: the Python helper then falls
# back to the clipboard and says why. A summary that has already been paid for
# must never be lost to a missing key.
#-------------------------------------------------------------------------------
TANA_LOCAL_API_TOKEN="$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s "$KEYCHAIN_TANA_TOKEN_SERVICE_NAME" -w 2>/dev/null || true)"
export TANA_LOCAL_API_TOKEN

export CLAUDE_MODEL_NAME MESSAGES_PER_API_CALL SUMMARY_LENGTH_FRACTION
export THE_DESTINATION THE_OUTPUT_TYPE

#-------------------------------------------------------------------------------
# The actual work
#
# Python does the parsing, the API call and the building of the Tana Paste.
# Reason not to do that in zsh: building JSON and safely escaping mail text with
# quotes, backslashes and emoji is a source of silent errors in a shell.
# Anything the python3 stdlib can do, we do there.
#
# The heredoc sits between single quotes ('PYTHON_EOF'), so that zsh does not
# expand anything in the Python code.
#-------------------------------------------------------------------------------
/usr/bin/python3 - "$PATH_OF_THE_INPUT_FILE" "$PATH_OF_THE_OUTPUT_FILE" <<'PYTHON_EOF'
# -*- coding: utf-8 -*-

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ------------------------------------------------------------------------------
# Separators, identical to the ones in the AppleScript
# ------------------------------------------------------------------------------
RECORD_SEPARATOR = "\x1e"   # between messages
UNIT_SEPARATOR = "\x1f"     # between the fields of a message
GROUP_SEPARATOR = "\x1d"    # between several recipients

# ==============================================================================
# SETTINGS
#
# There is nothing to configure in this file. Every setting lives in
# ~/.config/mailtotana/config.txt, which install.sh writes for you and which the
# AppleScript reads as well. One file, one source of truth, and an update of the
# code never overwrites what you chose.
#
# The reader below is deliberately dumb: "key = value", # for comments, an empty
# value means "not set". No sections, no quoting, no escaping. A settings file
# you cannot get wrong is worth more than one that can express everything.
# ==============================================================================

THE_CONFIGURATION_PATH = os.path.expanduser("~/.config/mailtotana/config.txt")


def read_the_configuration(the_path=THE_CONFIGURATION_PATH):
    """Reads the settings file into a plain dictionary.

    A missing file is not an error here. The caller decides what it cannot do
    without, and says so in words the user can act on -- which beats a traceback
    pointing at a path they have never heard of.
    """
    the_settings = {}
    try:
        with open(the_path, encoding="utf-8") as the_file:
            for the_line in the_file:
                the_line = the_line.strip()
                if not the_line or the_line.startswith("#") or "=" not in the_line:
                    continue
                the_key, _, the_value = the_line.partition("=")
                the_settings[the_key.strip().lower()] = the_value.strip()
    except OSError:
        pass
    return the_settings


THE_SETTINGS = read_the_configuration()


def the_setting(the_key, the_fallback=""):
    return THE_SETTINGS.get(the_key, the_fallback) or the_fallback


def the_number_setting(the_key, the_fallback):
    try:
        return int(the_setting(the_key, str(the_fallback)))
    except ValueError:
        return the_fallback


# ---- About you ---------------------------------------------------------------
OUTPUT_LANGUAGE = the_setting("output_language", "English")
THE_OWNER_NAME_OF_LAST_RESORT = the_setting("owner_name", "")

# ---- Tana ---------------------------------------------------------------------
#
# An empty identifier means "skip this field": nothing is written for it. That is
# what lets this run against a supertag that has no Media type, or no place for
# the body of the message. The supertag and the essence field are the two that
# cannot be skipped; main() refuses to run without them.
TANA_WORKSPACE_ID = the_setting("tana_workspace_id")

TANA_SUPERTAG_MESSAGE_ID = the_setting("tana_supertag_message")
TANA_FIELD_CONTACTPERSON_ID = the_setting("tana_field_contactperson")
TANA_FIELD_MEDIA_TYPE_ID = the_setting("tana_field_media_type")
TANA_FIELD_WHEN_ID = the_setting("tana_field_when")
TANA_FIELD_ESSENCE_ID = the_setting("tana_field_essence")
TANA_FIELD_CONTENT_ID = the_setting("tana_field_content")
TANA_FIELD_MESSAGE_LINK_ID = the_setting("tana_field_message_link")
TANA_MEDIA_TYPE_VALUE_EMAIL = the_setting("tana_media_type_value", "E-mail")

TANA_SUPERTAG_TASK_ID = the_setting("tana_supertag_task")
TANA_FIELD_BRIEFING_ID = the_setting("tana_field_briefing")
TANA_FIELD_TASK_OWNER_ID = the_setting("tana_field_task_owner")
TANA_FIELD_TASK_MESSAGE_LINK_ID = the_setting("tana_field_task_message_link")

# Two notes on those identifiers, both of which cost an afternoon to learn.
#
# TAKE A FIELD ID FROM THE SUPERTAG, NEVER FROM A TEST NODE. A field definition
# in Tana is itself a node, and it goes to the trash along with the node you
# first used the field on. The field then still appears to exist, but writing to
# that ID produces an orphaned value that shows up as plain text instead of a
# working field. The installer reads the supertag, so it cannot make this
# mistake; you can, if you fill the file in by hand.
#
# THE TWO "Link to the Message" FIELDS ARE DIFFERENT ATTRIBUTES WITH THE SAME
# NAME, one on #Message and one on #task. That is deliberate. The command button
# that opens the mail refers to the field by name, with the expression
# ${Link to the Message}, so a single button serves both supertags. Rename one
# and you must rename the other.

# From the settings file, with an environment variable still able to override it
# for a single run. That is what makes "try this with a different model" a one
# line experiment instead of an edit you have to remember to undo.
CLAUDE_MODEL_NAME = os.environ.get(
    "CLAUDE_MODEL_NAME", the_setting("claude_model", "claude-sonnet-5"))
MESSAGES_PER_API_CALL = int(os.environ.get(
    "MESSAGES_PER_API_CALL", the_number_setting("messages_per_api_call", 10)))
SUMMARY_LENGTH_FRACTION = float(os.environ.get("SUMMARY_LENGTH_FRACTION", "0.15"))

MINIMUM_SUMMARY_WORD_COUNT = 12
MAXIMUM_SUMMARY_WORD_COUNT = 140

# How much may remain, plotted against the length of the source message.
#
# A fixed 15% only works at the top. For a mail of 2000 words, 300 words is
# generous; for a mail of 92 words, 14 words is crippling: the essence sentence
# alone uses it up and nothing is left for the content. Short mail is also a
# different kind of text. It has little run-up, little repetition and little
# politeness padding; what is there is usually exactly the point.
#
# Short messages therefore get their own route: relatively much may stay, and as
# the message gets longer that sinks towards the normal 15%.
#
# This is deliberately written as ANCHOR POINTS on the curve (source words,
# target words) and not as classes with a percentage per class. With classes you
# get a cliff at the class boundary: at 200 words still a budget of 80 words, at
# 201 words only 30. Between the anchors we interpolate linearly, and above the
# last one the budget stays at the last anchor. That way the budget rises
# monotonically with length.
SUMMARY_LENGTH_ANCHORS = (
    (0, 0),        # lower end of the curve; MINIMUM_SUMMARY_WORD_COUNT catches the tail
    (60, 48),      # a note: keep almost everything
    (200, 80),     # short business mail: well over half goes, the facts stay
    (930, MAXIMUM_SUMMARY_WORD_COUNT),  # from here 15% would pass the ceiling
)


# ------------------------------------------------------------------------------
# Strip quoted text and signatures from a mail body
#
# Without this you walk into the summary with the complete quoted thread: a
# two-sentence reply to a mail of ten paragraphs would otherwise produce a
# "summary" that is mostly about the original message. In threads every
# predecessor ends up in Tana as its own node anyway, so the quote is redundant.
# (The patterns below also match the Dutch "Op ... schreef" and similar headers
# on purpose: they recognise mail written in other languages.)
# ------------------------------------------------------------------------------
QUOTE_HEADER_PATTERNS = [
    re.compile(r"^\s*On .{5,120}\bwrote:\s*$", re.IGNORECASE),
    re.compile(r"^\s*Op .{5,120}\bschreef\b.*:\s*$", re.IGNORECASE),
    re.compile(r"^\s*-{2,}\s*(Original Message|Oorspronkelijk bericht|Forwarded message|Doorgestuurd bericht)\s*-{2,}\s*$", re.IGNORECASE),
    re.compile(r"^\s*(Van|From)\s*:\s*.+$", re.IGNORECASE),
    re.compile(r"^\s*(Begin forwarded message|Begin doorgestuurd bericht)\s*:\s*$", re.IGNORECASE),
    re.compile(r"^\s*_{10,}\s*$"),
]

SIGNATURE_PATTERN = re.compile(r"^--\s?$")


def strip_quoted_text_and_signature(the_raw_body):
    """Returns only the newly written text of this message."""
    the_kept_lines = []

    for the_line in the_raw_body.splitlines():

        # quoted lines with > in front
        if the_line.lstrip().startswith(">"):
            break

        # header lines that start a quote or a forwarded message
        if any(the_pattern.match(the_line) for the_pattern in QUOTE_HEADER_PATTERNS):
            break

        # signature separator by convention: a line of exactly "-- "
        if SIGNATURE_PATTERN.match(the_line):
            break

        the_kept_lines.append(the_line)

    the_stripped_body = "\n".join(the_kept_lines).strip()

    # nothing left? then the message was probably only a quote; fall back to the
    # original text so that there is something to summarise
    if not the_stripped_body:
        the_stripped_body = the_raw_body.strip()

    return the_stripped_body


def count_words(the_text):
    return len([the_word for the_word in the_text.split() if the_word.strip()])


def budget_on_the_curve_for(the_word_count):
    """Target words according to SUMMARY_LENGTH_ANCHORS, linearly interpolated."""
    the_previous_source, the_previous_target = SUMMARY_LENGTH_ANCHORS[0]

    for the_source, the_target in SUMMARY_LENGTH_ANCHORS[1:]:

        if the_word_count <= the_source:
            the_span = the_source - the_previous_source
            the_position = (the_word_count - the_previous_source) / the_span
            return the_previous_target + the_position * (the_target - the_previous_target)

        the_previous_source, the_previous_target = the_source, the_target

    # past the last anchor: the plain fraction, which touches the ceiling there
    return the_word_count * SUMMARY_LENGTH_FRACTION


def target_word_count_for(the_body_text, the_subject_text):
    """Target word count for the summary, with a lower and an upper limit.

    Giving a percentage in the prompt does not work: models ignore it. A
    concrete number they do follow."""
    the_total = count_words(the_body_text) + count_words(the_subject_text)
    the_target = int(round(budget_on_the_curve_for(the_total)))
    return max(MINIMUM_SUMMARY_WORD_COUNT, min(MAXIMUM_SUMMARY_WORD_COUNT, the_target))


# ------------------------------------------------------------------------------
# Read the exchange file
# ------------------------------------------------------------------------------
def read_the_exchange_file(the_path):
    with open(the_path, "r", encoding="utf-8") as the_file:
        the_content = the_file.read()

    the_messages = []

    for the_record in the_content.split(RECORD_SEPARATOR):
        if not the_record.strip():
            continue

        the_fields = the_record.split(UNIT_SEPARATOR)

        # seven fields expected; fewer means a damaged record, or an exchange
        # file from before the seventh field existed
        while len(the_fields) < 7:
            the_fields.append("")

        the_recipient_names = [
            the_name.strip()
            for the_name in the_fields[3].split(GROUP_SEPARATOR)
            if the_name.strip()
        ]

        the_raw_body = the_fields[5]
        the_clean_body = strip_quoted_text_and_signature(the_raw_body)

        the_messages.append({
            "messageId": the_fields[0].strip(),
            "timestamp": the_fields[1].strip(),
            "senderName": the_fields[2].strip(),
            "recipientNames": the_recipient_names,
            "subject": the_fields[4].strip(),
            "body": the_clean_body,
            "targetWords": target_word_count_for(the_clean_body, the_fields[4]),
            # Steers ONLY the Contactperson field. The sender name in field 3
            # stays as it is, so that the title does know who wrote it: for a
            # reply the owner sends themselves it should say "Your Name: ...",
            # while they should not end up in the graph as the contact person
            # of their own mail.
            "senderIsMe": bool(the_fields[6].strip()),
        })

    return the_messages


# ------------------------------------------------------------------------------
# Calling Claude
#
# The prompts are in English. The language of the ANSWER is a separate setting
# (output_language in config.txt) and is filled in where {OUTPUT_LANGUAGE} stands.
# That is the one place where the translation of this file changes behaviour.
# ------------------------------------------------------------------------------
SYSTEM_PROMPT = """You summarise business e-mail for a personal knowledge base in Tana.

For each message you deliver:
- "essence": ONE sentence that captures the core of the message. Say what the
  sender does or asks, not what the message is about. So not "reaction to the
  benchmark" but "wants to run the benchmark through the pilot programme". No
  full stop at the end. Never leave it empty, not even for a message of three
  words.

  START WITH A VERB IN THE THIRD PERSON, IN LOWER CASE: "proposes to", "asks
  whether", "reports that", "confirms that", "doubts whether". So not "Proposes"
  with a capital, and not "A proposal to". The sender's name is put in front
  later, so that the whole becomes one running sentence: "Sam Okafor: proposes to
  put the advice to the board". So do NOT repeat that name in the essence
  sentence itself.

  If the sentence starts with a word that always has a capital, such as an
  acronym or a brand name, keep that capital.
- "rest": the remaining sentences of the summary, each as a separate element in
  a list. Together with the essence sentence you stay within the given number of
  words. Leave the list empty when the essence sentence already covers the
  message completely.
- "senderName": fill this in only when the given sender name is an e-mail
  address AND you can see a real name in the signature of the message. In all
  other cases an empty string.

Write in {OUTPUT_LANGUAGE}, also when the source messages are in another
language. Businesslike and factual. Invent nothing: if there is no action or
commitment in the message, do not mention one. Copy the names of people and
organisations, dates and amounts literally from the message.

Deliver exactly one object for each message offered, in the same order as the
input."""
SYSTEM_PROMPT = SYSTEM_PROMPT.replace("{OUTPUT_LANGUAGE}", OUTPUT_LANGUAGE)


# ------------------------------------------------------------------------------
# The task variant: a different assignment, not just a different layout
#
# This is where the real difference between the two tools sits. MailToTana
# DOCUMENTS: compress to the core, because later you look up what happened.
# MailToTask BRIEFS: the text must be enough to start working without fetching
# the original mail.
#
# That is why the length curve from SUMMARY_LENGTH_ANCHORS does NOT apply here.
# Compressing is exactly the problem with a briefing: leave out half of the
# questions and you have to open the mail anyway, so it did not help. The ban on
# padding does stay; long is allowed, long-winded is not.
# ------------------------------------------------------------------------------
TASK_SYSTEM_PROMPT = """You turn an e-mail or an e-mail thread into a task for the owner of this mailbox, in Tana.

You deliver exactly ONE task, even when several messages are offered. Those
messages together form the context of one assignment.

- "task": ONE short line that becomes the name of the task in the task list. Keep
  it short enough to read at a glance, start with a LOWER-CASE LETTER and do not
  put a full stop after it.

  At the top of the messages is the DIRECTION of the mail. It decides the form,
  and the difference is not cosmetic:

  If the mail came IN, the owner has to do something. Then write the line in the
  IMPERATIVE -- "answer", "call", "deliver", "review", "plan" -- and do NOT name
  a performer. This is their own task list, so that it is them goes without
  saying. Do name the sender, at the place where they belong grammatically:

    "answer Renée Müller about the data processing agreement"

  If the owner sent the mail THEMSELVES, they have delegated something and the
  ADDRESSEE has to deliver. Then write the line as a DESCRIPTION of what that
  person does, in the third person and the present tense. Do NOT name them; the
  script puts the name in front. So start straight away with the verb:

    "adds two new items about penetration testing to the FAQ"

- "briefing": everything the owner needs to work on this task WITHOUT fetching
  the original mail, divided over FIXED sections:

    reason       why this is on their desk: who, when, in which context
    request      what exactly is being asked or has to happen
    agreement    what has already been promised or agreed, and by whom
    needed       documents, data or people they need for this
    background   anything else that matters to do it well
    other        a list for what fits in none of the sections

  Write RUNNING text for each section, two or three sentences together if need
  be. Do not chop it into separate little lines: that reads like a shopping list,
  and this text has to be readable in one go.

  Sections that do not apply you leave EMPTY. Do not invent anything to fill
  them, and do not repeat a section in another one.

  Copy literally what is needed to get started: names of people and
  organisations, documents, amounts, version numbers, and where the thread got
  stuck. No word budget: better one sentence too many than one that the owner has
  to go and look up.

  Do leave out what is not information: greetings, signatures, courtesies, and
  repetition of what an earlier message already said.

- "mentionedDeadline": fill in only when the text EXPLICITLY mentions a term or
  date by which something must be done, such as "before 15 September" or "by next
  Friday at the latest". Copy it literally as it stands. If the text mentions
  nothing, an empty string. Never invent a date, and do not derive one from the
  date of the message either.

Write in {OUTPUT_LANGUAGE}, also when the source messages are in another
language. Businesslike and factual. Invent nothing."""
TASK_SYSTEM_PROMPT = TASK_SYSTEM_PROMPT.replace("{OUTPUT_LANGUAGE}", OUTPUT_LANGUAGE)


# ------------------------------------------------------------------------------
# Tool definition for structured output
#
# Reason for tool use instead of "answer with JSON": this way the API enforces
# the schema instead of hoping for it. Prefilling the assistant turn with "["
# does not work here, because Sonnet 5 does not support prefill.
# ------------------------------------------------------------------------------
SUMMARY_TOOL_DEFINITION = {
    "name": "deliver_summaries",
    "description": "Delivers the summary of each e-mail message offered, in the same order as the input.",
    "input_schema": {
        "type": "object",
        "properties": {
            "summaries": {
                "type": "array",
                "description": "One object per message, in the order of the input.",
                "items": {
                    "type": "object",
                    "properties": {
                        "essence": {
                            "type": "string",
                            "description": "One sentence that gives the core, starting with a verb in the third person and in lower case: 'proposes to', 'asks whether', 'reports that'. Never empty. No full stop at the end.",
                        },
                        "rest": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "The remaining sentences of the summary, each as a separate element. May be empty.",
                        },
                        "senderName": {
                            "type": "string",
                            "description": "Name from the signature, only when the given sender was an e-mail address. Otherwise an empty string.",
                        },
                    },
                    "required": ["essence", "rest", "senderName"],
                },
            }
        },
        "required": ["summaries"],
    },
}


# The sections of the briefing, in the order in which they end up in Tana.
# The name on the left is the key in the model's answer, the text on the right
# is the bold lead-in of the bullet.
#
# Fixed words and a fixed order, on purpose: if you let the model invent its own
# headings, every task gets a different layout and you lose the benefit of a
# fixed structure. You must be able to scan it at a glance, and that is only
# possible if "Request" is always in the same place.
BRIEFING_SECTIONS = (
    ("reason", "Reason"),
    ("request", "Request"),
    ("agreement", "Agreement"),
    ("needed", "Needed"),
    ("background", "Background"),
)

BRIEFING_SECTION_NAMES = tuple(the_name for the_name, _ in BRIEFING_SECTIONS)


TASK_TOOL_DEFINITION = {
    "name": "deliver_task",
    "description": "Delivers exactly one task, composed from all the messages offered together.",
    "input_schema": {
        "type": "object",
        "properties": {
            "task": {
                "type": "string",
                "description": "A short line in the imperative, in lower case: 'answer Renée Müller about the data processing agreement'. Becomes the name of the task. No full stop at the end.",
            },
            "briefing": {
                "type": "object",
                "description": "The briefing in fixed sections. Running text per section, not chopped up. Leave sections that do not apply empty.",
                "properties": {
                    "reason": {"type": "string", "description": "Why this is on their desk: who, when, in which context."},
                    "request": {"type": "string", "description": "What exactly is being asked or has to happen."},
                    "agreement": {"type": "string", "description": "What has already been promised or agreed, and by whom."},
                    "needed": {"type": "string", "description": "Documents, data or people needed for this."},
                    "background": {"type": "string", "description": "Anything else that matters to do it well."},
                    "other": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "What fits in none of the sections. Usually empty.",
                    },
                },
                "required": ["reason", "request", "agreement", "needed", "background", "other"],
            },
            "mentionedDeadline": {
                "type": "string",
                "description": "Only a term that the text EXPLICITLY mentions, copied literally. Otherwise an empty string. Never derive or invent.",
            },
        },
        "required": ["task", "briefing", "mentionedDeadline"],
    },
}


def build_the_user_prompt(the_message_batch):
    the_parts = []

    for the_index, the_message in enumerate(the_message_batch, start=1):
        the_parts.append(
            "=== MESSAGE {index} ===\n"
            "Sender: {sender}\n"
            "Date: {timestamp}\n"
            "Subject: {subject}\n"
            "Maximum number of words for essence and rest together: {words}\n"
            "--- text ---\n"
            "{body}".format(
                index=the_index,
                sender=the_message["senderName"] or "unknown",
                timestamp=the_message["timestamp"],
                subject=the_message["subject"] or "(no subject)",
                words=the_message["targetWords"],
                body=the_message["body"] or "(empty message)",
            )
        )

    return "\n\n".join(the_parts)


def the_requester_name_for(the_message):
    """The sender of an incoming message, as far as usable as a name.

    Empty for your own mail. If an e-mail address is left, we still try to derive
    a name from it; if that fails, no name. An address in a task line reads
    like nothing.

    Note: this is no longer who PERFORMS the task -- see the_actor_names_for --
    but who may be named in the sentence as the other party."""
    if the_message["senderIsMe"]:
        return ""

    the_name = derive_name_from_email_address(the_message["senderName"])

    if not the_name or "@" in the_name:
        return ""

    return the_name


def the_actor_names_for(the_messages):
    """Who has to do something? Returns (names, is_delegated).

    This is the core of the task variant:
    THE TITLE NAMES THE PERSON WHO HAS TO DO SOMETHING, AND THAT IS THE SAME
    PERSON AS THE TASK OWNER. Two cases, and they are each other's mirror image:

      incoming mail   -> the owner has to do something. "Your Name: answers the
                         questions from Renée Müller about the data processing
                         agreement"
      mail you sent   -> the owner delegated something and the OTHER has to
                         deliver. "Alex Moreau: adds two new items to the FAQ"

    Why this is better than the imperative that was here at first: a task from a
    mail you sent yourself is not an order to yourself but an open request to
    someone else, and you want to see that in your list without opening the node.

    The LAST message decides: that is the message the owner selected and the one
    that contains the question. The earlier ones are the run-up.
    """
    the_last_message = the_messages[-1]

    if the_last_message["senderIsMe"]:
        the_names = [
            the_clean_name
            for the_clean_name in (
                derive_name_from_email_address(the_name)
                for the_name in the_last_message["recipientNames"]
            )
            if the_clean_name and "@" not in the_clean_name
        ]
        if the_names:
            return the_names, True

    # Incoming mail, or sent mail without a usable addressee: then the owner is
    # the performer. We prefer to read their name from a message of their own in
    # the thread, so that the script is not tied to a fixed name.
    for the_message in the_messages:
        if the_message["senderIsMe"]:
            the_name = derive_name_from_email_address(the_message["senderName"])
            if the_name and "@" not in the_name:
                return [the_name], False

    return [THE_OWNER_NAME_OF_LAST_RESORT], False


def build_the_task_user_prompt(the_messages):
    """All messages in ONE call: together they form the context of the assignment.

    No word budget per message, unlike with the summaries. And no batches of ten:
    only one task comes out of it, so chopping it up would break the context.

    At the top is the PERFORMER: the person the task line has to be about. The
    model does not decide that itself, because the choice depends on the
    direction of the mail and we know that for certain -- see the_actor_names_for.
    That way the model only has to choose the verb.

    The requester is listed separately, so that the model can name that person in
    the sentence if that helps: "answers the questions from Renée Müller about
    ...". That is the other party, not the performer."""
    the_parts = []

    the_actor_names, the_task_is_delegated = the_actor_names_for(the_messages)

    if the_task_is_delegated:
        the_parts.append(
            "Direction: OUTGOING. The owner sent this mail themselves and has"
            " delegated something to {names}. Describe in the third person what"
            " that person has to deliver, and do not name them.".format(
                names=", ".join(the_actor_names)))
    else:
        the_parts.append(
            "Direction: INCOMING. The owner has to do something themselves. Write"
            " the line in the imperative and do not name a performer.")

    the_requester = the_requester_name_for(the_messages[-1])
    if the_requester:
        the_parts.append("Sender: " + the_requester)

    for the_index, the_message in enumerate(the_messages, start=1):
        the_parts.append(
            "=== MESSAGE {index} of {total} ===\n"
            "Sender: {sender}\n"
            "Date: {timestamp}\n"
            "Subject: {subject}\n"
            "--- text ---\n"
            "{body}".format(
                index=the_index,
                total=len(the_messages),
                sender=the_message["senderName"] or "the owner of this mailbox",
                timestamp=the_message["timestamp"],
                subject=the_message["subject"] or "(no subject)",
                body=the_message["body"] or "(empty message)",
            )
        )

    return "\n\n".join(the_parts)


SUMMARY_LIST_KEY = "summaries"

# How deep we keep unpacking. Two layers have been observed; five is generous
# and at the same time keeps a mangled answer out of an endless loop.
MAXIMUM_UNPACK_DEPTH = 5


def unpack_the_summary_list(the_tool_input):
    """Gets the list of summaries out of the tool_use block.

    tool_choice forces the model to USE the tool, but does not guarantee the
    schema. Empirically, with the same message offered three times: in about two
    of the three attempts Sonnet 5 puts a JSON STRING in "summaries", and that
    string contains the WHOLE object once more, so
    {"summaries": "{\\"summaries\\": [...]}"}.

    Two pitfalls that this gives:
      * if you loop over the string with a list comprehension, you iterate over
        single CHARACTERS and the first summary becomes the character "{"
      * if you decode the string only one layer, you are left with a dict
        without "essence" and every summary comes out empty

    That is why we peel layer by layer here: a string is decoded, and a dict
    that itself has a "summaries" key again we dive into."""
    the_value = the_tool_input.get(SUMMARY_LIST_KEY, [])

    for the_attempt in range(MAXIMUM_UNPACK_DEPTH):

        if isinstance(the_value, str):
            try:
                the_value = json.loads(the_value)
            except ValueError:
                # not valid JSON: treat it as a single string, not as a
                # sequence to walk over character by character
                return [the_value]
            continue

        if isinstance(the_value, dict) and SUMMARY_LIST_KEY in the_value:
            the_value = the_value[SUMMARY_LIST_KEY]
            continue

        break

    if isinstance(the_value, dict):
        # a single summary object instead of a list of one
        return [the_value]

    if not isinstance(the_value, list):
        return []

    return the_value


def normalise_the_summary(the_raw_summary):
    """Turns whatever the model returned into a usable dict, always.

    tool_choice forces the model to USE the tool, but does not guarantee the
    schema. Observed deviation: the summaries came back as a list of bare strings
    instead of objects, after which build_the_tana_paste tripped over .get on a
    str. "rest" also sometimes comes back as a single string instead of a list.
    This straightens out both cases instead of letting the whole batch fail."""
    if isinstance(the_raw_summary, str):
        return {"essence": the_raw_summary, "rest": [], "senderName": ""}

    if not isinstance(the_raw_summary, dict):
        return {"essence": "", "rest": [], "senderName": ""}

    the_rest = the_raw_summary.get("rest") or []
    if isinstance(the_rest, str):
        the_rest = [the_rest]

    return {
        "essence": str(the_raw_summary.get("essence") or ""),
        "rest": [str(the_sentence) for the_sentence in the_rest],
        "senderName": str(the_raw_summary.get("senderName") or ""),
    }


# HTTP codes for which trying again makes sense. 429 is a rate limit, 529 is
# "overloaded" at Anthropic, the 500 series is the server's side. With a 400 or
# a 401 waiting is pointless: then the request or the key is wrong.
RETRYABLE_HTTP_STATUS_CODES = (408, 409, 429, 500, 502, 503, 504, 529)

NUMBER_OF_ATTEMPTS = 3
SECONDS_BEFORE_THE_FIRST_RETRY = 2


def send_the_request_with_retries(the_request):
    """Sends the request and tries again on temporary errors.

    Without this a single 529 from the API costs the WHOLE run: with a thread of
    thirty messages the batches that had already succeeded are lost too, and the
    user only sees an error message. The waiting time doubles per attempt."""
    the_seconds_to_wait = SECONDS_BEFORE_THE_FIRST_RETRY
    the_last_problem = "unknown"

    for the_attempt_number in range(1, NUMBER_OF_ATTEMPTS + 1):

        try:
            with urllib.request.urlopen(the_request, timeout=180) as the_response:
                return json.loads(the_response.read().decode("utf-8"))

        except urllib.error.HTTPError as the_error:
            the_detail = the_error.read().decode("utf-8", errors="replace")
            the_last_problem = "HTTP {code}: {detail}".format(code=the_error.code, detail=the_detail[:400])

            if the_error.code not in RETRYABLE_HTTP_STATUS_CODES:
                sys.exit("The Claude API returned " + the_last_problem)

        except urllib.error.URLError as the_error:
            the_last_problem = "network error: {reason}".format(reason=the_error.reason)

        if the_attempt_number < NUMBER_OF_ATTEMPTS:
            time.sleep(the_seconds_to_wait)
            the_seconds_to_wait = the_seconds_to_wait * 2

    sys.exit("The Claude API kept failing after {count} attempts. Last problem: {problem}".format(
        count=NUMBER_OF_ATTEMPTS, problem=the_last_problem))


def call_claude_for(the_message_batch):
    the_request_payload = {
        "model": CLAUDE_MODEL_NAME,
        "max_tokens": 8000,
        "system": SYSTEM_PROMPT,
        "messages": [
            {"role": "user", "content": build_the_user_prompt(the_message_batch)},
        ],
        "tools": [SUMMARY_TOOL_DEFINITION],
        # make the tool mandatory, so that no free text comes back
        "tool_choice": {"type": "tool", "name": SUMMARY_TOOL_DEFINITION["name"]},
    }

    the_request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(the_request_payload).encode("utf-8"),
        headers={
            "x-api-key": os.environ["ANTHROPIC_API_KEY"],
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )

    the_response_body = send_the_request_with_retries(the_request)

    # the answer consists of content blocks; we look for the tool_use block
    for the_content_block in the_response_body.get("content", []):
        if the_content_block.get("type") == "tool_use":
            the_raw_summaries = unpack_the_summary_list(the_content_block["input"])
            return [normalise_the_summary(the_raw) for the_raw in the_raw_summaries]

    sys.exit("Claude returned no structured answer (no tool_use block in the response).")


def call_claude_for_the_task(the_messages):
    """One call with all the messages, and one task comes out."""
    the_request_payload = {
        "model": CLAUDE_MODEL_NAME,
        "max_tokens": 8000,
        "system": TASK_SYSTEM_PROMPT,
        "messages": [
            {"role": "user", "content": build_the_task_user_prompt(the_messages)},
        ],
        "tools": [TASK_TOOL_DEFINITION],
        "tool_choice": {"type": "tool", "name": TASK_TOOL_DEFINITION["name"]},
    }

    the_request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(the_request_payload).encode("utf-8"),
        headers={
            "x-api-key": os.environ["ANTHROPIC_API_KEY"],
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )

    the_response_body = send_the_request_with_retries(the_request)

    for the_content_block in the_response_body.get("content", []):
        if the_content_block.get("type") == "tool_use":
            return normalise_the_task(the_content_block["input"])

    sys.exit("Claude returned no structured answer (no tool_use block in the response).")


def normalise_the_task(the_raw_task):
    """The same caution as with the summaries.

    tool_choice enforces the use of the tool, not the schema; see the note at
    unpack_the_summary_list. Here it is simpler because only one object comes
    back, but a string instead of a list for "briefing" is exactly the same
    deviation as there."""
    if isinstance(the_raw_task, str):
        try:
            the_raw_task = json.loads(the_raw_task)
        except ValueError:
            return {"task": the_raw_task, "briefing": [], "mentionedDeadline": ""}

    if not isinstance(the_raw_task, dict):
        return {"task": "", "briefing": {}, "mentionedDeadline": ""}

    the_briefing = the_raw_task.get("briefing")

    # the model can turn it into a string here too; see unpack_the_summary_list
    if isinstance(the_briefing, str):
        try:
            the_briefing = json.loads(the_briefing)
        except ValueError:
            the_briefing = {"other": [the_briefing]}

    # old form, or a model that returns a list after all: then everything goes
    # under "other", so that the text is not lost
    if isinstance(the_briefing, list):
        the_briefing = {"other": the_briefing}

    if not isinstance(the_briefing, dict):
        the_briefing = {}

    the_other = the_briefing.get("other") or []
    if isinstance(the_other, str):
        the_other = [the_other]

    the_clean_briefing = {
        the_name: str(the_briefing.get(the_name) or "").strip()
        for the_name in BRIEFING_SECTION_NAMES
    }
    the_clean_briefing["other"] = [str(the_line) for the_line in the_other]

    return {
        "task": str(the_raw_task.get("task") or ""),
        "briefing": the_clean_briefing,
        "mentionedDeadline": str(the_raw_task.get("mentionedDeadline") or ""),
    }


# ------------------------------------------------------------------------------
# Build the Tana Paste
# ------------------------------------------------------------------------------
# A hash followed by a LETTER makes a supertag in Tana Paste. Followed by a
# digit it does not: "ticket #5222" stays plain text. Hence the look-ahead
# condition on a letter, with \W and \d excluded so that accents and umlauts do
# count as a letter.
INLINE_SUPERTAG_PATTERN = re.compile(r"#(?=[^\W\d_])", re.UNICODE)


def sanitise_for_tana_node(the_text):
    """Makes text safe as the content of a Tana node.

    Mail text is not neutral text: Tana Paste knows formatting characters that
    also occur in ordinary correspondence, and they are executed when pasting.
    Established empirically with a trial import on 30 July 2026:

      * "see #budget" created a NEW SUPERTAG "budget" in the Schema, including an
        automatically generated "Everything tagged" search node, and attached
        that tag to the node. The word itself disappeared from the text. This is
        the worst one: arbitrary mail text pollutes your schema.
      * a sentence with "::" in it became a FIELD instead of a node, and
        produced a node with an empty name.
      * "[[Alex Moreau]]" became a reference to the existing node.

    All three are neutralised here. A line break would also produce an extra
    node, so everything is flattened into one line.

    "**bold**" and "^^highlighted^^" stay: they only give formatting and no
    structure, and in a summary that is more gain than loss."""
    the_single_line = " ".join(the_text.split())

    # hash before a letter: would become a supertag. The hash goes, the word
    # stays, because "see budget" reads fine
    the_single_line = INLINE_SUPERTAG_PATTERN.sub("", the_single_line)

    # double colon: would turn the node into a field
    the_single_line = the_single_line.replace("::", ":")

    # double square brackets: would become a reference to a node that happens to
    # have that name, or to a new empty node
    the_single_line = the_single_line.replace("[[", "[").replace("]]", "]")

    return the_single_line.lstrip("-#*> ").strip()


# Characters that may stay untouched in the Message-ID. Note what is NOT in it:
# the round brackets.
#
# The link of a message goes into a field as a value and not as markdown, so a
# bracket can no longer cut the URL off halfway. The encoding stays anyway, for
# two reasons: the task variant may still write the link as markdown, and an
# encoded bracket is never a problem while a bare bracket is a problem in the
# wrong place. What you leave out here costs you an evening of searching later.
THE_SAFE_CHARACTERS_IN_A_MESSAGE_ID = "@.-_+!$&'*,;="


def build_the_message_url(the_message_identifier):
    """Builds the message:// URL with which Mail opens the message again.

    The angle brackets around the Message-ID are part of it and must be encoded.
    Note: Tana turns an imported message:// value into a link and strips the href
    after the first click, which is why the link field is plain text and the
    "Open link" command button opens Mail instead (see tana-schema.md)."""
    if not the_message_identifier:
        return ""
    the_encoded_identifier = urllib.parse.quote(
        the_message_identifier, safe=THE_SAFE_CHARACTERS_IN_A_MESSAGE_ID
    )
    return "message://%3c" + the_encoded_identifier + "%3e"


# Addresses from which no personal name can be taken, even if there is a dot in them.
ROLE_ACCOUNT_PREFIXES = ("noreply", "no-reply", "donotreply", "do-not-reply", "postmaster", "mailer-daemon")


def derive_name_from_email_address(the_text):
    """Turns "pieter.jansen@example.com" into the name "Pieter Jansen".

    Last resort, and deliberately the last place in the row. The order of
    preference is: the name that Contacts knows, then the name from the
    signature that the model found, and only then this mechanical derivation.

    Why it is needed: `Contactperson` on #Message is an "Instance of #Person" and
    only links on an exact NAME match. If there is an address in the field,
    nothing links by definition and every message gets a new loose node. In the
    thread test of 30 July that was the case for 7 of the 10 messages, while the
    matching person nodes were simply there in Tana.

    Only derive when the part before the @ consists of several pieces. That way
    support@, info@ and other role accounts are left alone: "Support" as a
    contact person is worse than leaving the address."""
    if "@" not in the_text:
        return the_text

    the_local_part = the_text.split("@", 1)[0].lower()

    if the_local_part.startswith(ROLE_ACCOUNT_PREFIXES):
        return the_text

    the_words = [the_word for the_word in re.split(r"[._-]+", the_local_part) if the_word]

    if len(the_words) < 2:
        return the_text

    # digits in it: an employee number or a second account. Then we are not sure
    # enough and we keep the address
    if any(not the_word.isalpha() for the_word in the_words):
        return the_text

    # a single letter is an initial: "j.smith" becomes "J. Smith"
    return " ".join(
        the_word.upper() + "." if len(the_word) == 1 else the_word[:1].upper() + the_word[1:]
        for the_word in the_words
    )


def with_a_lowercase_start(the_text):
    """Removes the capital from the first word, if it is an ordinary word.

    The prompt asks for a sentence that starts with a lower-case verb, but the
    model does not always manage that. This is the safety net, and it is
    deliberately careful: only if the first word looks like an ordinary word
    (a capital followed by lower-case letters) does that capital go.

    That way "NASA reports that" stays, and "GDPR request" too, while "Proposes"
    becomes "proposes" neatly. Otherwise you would get "nasa reports that", and
    that is worse than the capital you tried to repair."""
    if not the_text:
        return the_text

    the_first_word = the_text.split(" ", 1)[0]

    if len(the_first_word) > 1 and the_first_word[0].isupper() and the_first_word[1:].islower():
        return the_text[0].lower() + the_text[1:]

    return the_text


def the_readable_title_for(the_sender_name, the_essence):
    """Puts the sender in front of the essence, so that a running sentence results.

    "Sam Okafor: proposes to put the advice to the board"

    Why here and not in a title expression in Tana: the Contactperson field
    contains ALL the people involved, because that is what you want to search and
    click through on. With a group mail that is ten of them, and putting those in
    the title gives lines of two hundred characters with the core at the very
    end. The field is for querying, the title for reading; those two should not
    be the same. The title expression in Tana is therefore reduced to
    "${When} - ${Essence of the message}".

    Without a sender no prefix: messages that you sent yourself have no
    Contactperson, and "Wed, 4 Mar - : proposes" reads like nothing."""
    the_sentence = with_a_lowercase_start(the_essence)

    if not the_sender_name or "@" in the_sender_name:
        return the_sentence

    return "{sender}: {sentence}".format(sender=the_sender_name, sentence=the_sentence)


def build_the_tana_paste(the_messages, the_summaries):
    """Builds the Tana Paste for all messages.

    INDENTATION: the message nodes are at level 0, their fields at 2 and the field
    values at 4. That is not a matter of taste. If we put the messages at level 2
    (which looks logical with the %%tana%% line above), then message 2 and later
    become CHILDREN of message 1 instead of siblings. Established empirically
    with a trial import of three nodes: at level 2 Tana nested them, at level 0
    they became siblings. With a thread of ten messages you only see that when you
    look in Tana, because the output file still looks fine."""
    the_lines = ["%%tana%%"]

    for the_message, the_summary in zip(the_messages, the_summaries):

        the_essence = sanitise_for_tana_node(the_summary.get("essence", ""))
        if not the_essence:
            the_essence = sanitise_for_tana_node(the_message["subject"]) or "(no summary)"

        the_sender_name = the_message["senderName"]
        the_name_from_footer = (the_summary.get("senderName") or "").strip()

        # If there is still an e-mail address, Contacts did not know the sender
        # and we choose a name ourselves. Order of preference:
        #
        #   1. the signature, PROVIDED it gives a full name
        #   2. the name derived from the address
        #   3. the signature after all, even if it is only a first name
        #   4. the address itself
        #
        # Points 1 and 2 are in this order because a real signature has spelling
        # and diacritics right: you never get "Renée Müller" from
        # "r.muller@example.org", the derivation makes "R. Muller" of it.
        # But then the signature must contain a SURNAME. If someone signs with
        # only "Robin", that does not link to the person node "Robin Dekker",
        # while "robin.dekker@example.com" does. Hence the space as a test for
        # completeness.
        if "@" in the_sender_name:

            the_derived_name = derive_name_from_email_address(the_sender_name)

            if the_name_from_footer and " " in the_name_from_footer:
                the_sender_name = the_name_from_footer
            elif the_derived_name != the_sender_name:
                the_sender_name = the_derived_name
            elif the_name_from_footer:
                the_sender_name = the_name_from_footer

        # remove duplicates, keeping the order: Tana Paste does not support two
        # inline references to the same node from one node
        the_contact_names = []
        the_names_for_the_field = list(the_message["recipientNames"])
        if not the_message["senderIsMe"]:
            the_names_for_the_field.insert(0, the_sender_name)

        for the_name in the_names_for_the_field:
            # last resort, after Contacts and after the signature above
            the_clean_name = sanitise_for_tana_node(derive_name_from_email_address(the_name))
            if the_clean_name and the_clean_name not in the_contact_names:
                the_contact_names.append(the_clean_name)

        # the sender in front of the essence, so that a running sentence results
        the_readable_title = the_readable_title_for(the_sender_name, the_essence)

        # ---- the node itself -----------------------------------------------
        # The node name is overwritten by the title expression of #Message with
        # "${When} - ${Essence of the message}". We put the same text in anyway,
        # so that the node stays readable should that expression ever disappear.
        the_lines.append("- {title} #[[^{tag}]]".format(title=the_readable_title, tag=TANA_SUPERTAG_MESSAGE_ID))

        # ---- Contactperson -------------------------------------------------
        # Bare names without [[ ]]. Tested empirically on 30 July 2026: with this
        # instance field a bare name links to the existing person node with that
        # name, just like [[Name]] and [[^nodeId]]. If the name does not exist
        # yet, Tana makes a new UNTAGGED node, and again with every following
        # message. That is why it is worth turning an e-mail address into a real
        # name above.
        if TANA_FIELD_CONTACTPERSON_ID and len(the_contact_names) == 1:
            the_lines.append("  - [[^{field}]]:: {value}".format(field=TANA_FIELD_CONTACTPERSON_ID, value=the_contact_names[0]))
        elif TANA_FIELD_CONTACTPERSON_ID and len(the_contact_names) > 1:
            the_lines.append("  - [[^{field}]]::".format(field=TANA_FIELD_CONTACTPERSON_ID))
            for the_name in the_contact_names:
                the_lines.append("    - {value}".format(value=the_name))

        # ---- Media type ----------------------------------------------------
        if TANA_FIELD_MEDIA_TYPE_ID:
            the_lines.append("  - [[^{field}]]:: {value}".format(field=TANA_FIELD_MEDIA_TYPE_ID, value=TANA_MEDIA_TYPE_VALUE_EMAIL))

        # ---- When ----------------------------------------------------------
        if TANA_FIELD_WHEN_ID and the_message["timestamp"]:
            the_lines.append("  - [[^{field}]]:: [[date:{value}]]".format(field=TANA_FIELD_WHEN_ID, value=the_message["timestamp"]))

        # ---- Essence of the message -----------------------------------------
        # This holds the title WITH the sender in front, not the bare essence: this
        # field feeds the title expression, and the sender has to come back there.
        the_lines.append("  - [[^{field}]]:: {value}".format(field=TANA_FIELD_ESSENCE_ID, value=the_readable_title))

        # ---- Content of the message ----------------------------------------
        the_remaining_sentences = [
            sanitise_for_tana_node(the_sentence)
            for the_sentence in the_summary.get("rest", [])
            if sanitise_for_tana_node(the_sentence)
        ]

        if TANA_FIELD_CONTENT_ID and the_remaining_sentences:
            the_lines.append("  - [[^{field}]]::".format(field=TANA_FIELD_CONTENT_ID))
            for the_sentence in the_remaining_sentences:
                the_lines.append("    - {value}".format(value=the_sentence))

        # ---- Link to the Message --------------------------------------------
        # THE BARE ADDRESS, NO MARKDOWN. That is not sloppiness but a requirement.
        #
        # In Tana this field has a command button attached ("Open original
        # e-mail") with the system command `Open link` in it, and the parameter
        # `URL: ${Link to the Message}`. That button hands the address straight to
        # macOS, which opens Apple Mail.
        #
        # A title expression such as ${Link to the Message} returns the RAW
        # content of the field. If there is markdown in it, the button is offered
        # `<a href="message://...">message://...</a>` as the URL, and that is not
        # a valid address. Nothing happens then. Verified on 13 August 2026, and
        # it took a morning to find -- Tana's error message only says "Error
        # fetching API response" and points nowhere.
        #
        # Plain text solves a second problem at the same time. Until then Tana
        # destroyed a message:// link on the FIRST click: `<a href="...">(link)</a>`
        # became `<a>(link)</a>` and the address was irretrievably gone. That
        # explained everything that had not added up before -- no time limit, no
        # difference between clipboard and API, no manual editing; it was simply
        # the nodes that had been clicked once. Without an href there is nothing
        # left to destroy: the address is now just text, and the button does the
        # opening.
        #
        # WHY A FIELD OF ITS OWN, AND NO LONGER BEHIND THE ESSENCE.
        # Until 12 August 2026 the link hung behind the essence sentence as
        # markdown and so ended up in the title via the title expression. Nice to
        # click, but it made the link depend on how Tana parses that whole
        # sentence. Now it stands apart. Price: no longer clickable from the
        # title; you open the node and press the button.
        #
        # IT COMES LAST, equal to the field order in the supertag: you only use
        # the link when essence and summary are not enough. Tana shows template
        # fields in the order of the tag anyway, but this way /tmp/mailtotana-out.txt
        # reads in the same order as the node in Tana.
        the_message_url = build_the_message_url(the_message["messageId"])
        if TANA_FIELD_MESSAGE_LINK_ID and the_message_url:
            the_lines.append("  - [[^{field}]]:: {url}".format(
                field=TANA_FIELD_MESSAGE_LINK_ID,
                url=the_message_url,
            ))

    return "\n".join(the_lines) + "\n"


def build_the_task_paste(the_messages, the_task):
    """Builds the Tana Paste for a single task.

    Four fields we deliberately do NOT set: due date, task status, task priority
    and task owner get their default value as soon as the supertag is applied.
    Verified with a trial import on 5 August 2026.

    A stated deadline goes in as the FIRST line of the briefing and not in the
    due-date field. Reason: what is in a mail is usually the date by which
    something has to be done, and whether that also becomes your deadline is a
    judgement. This way you see it without looking for it, and you decide."""
    the_task_line = sanitise_for_tana_node(with_a_lowercase_start(the_task["task"]))

    if not the_task_line:
        # no task line is no task; then the subject of the last message will do,
        # so that there is something usable instead of an empty node
        the_task_line = sanitise_for_tana_node(the_messages[-1]["subject"]) or "(no task recognised)"

    # ---- The performer in the line, ONLY for delegated tasks -----------------
    # Settled on 13 August 2026. Two forms, and each is natural in its own case:
    #
    #   incoming mail   "answer Renée Müller about the data processing agreement"
    #   mail you sent   "Alex Moreau: adds two new items to the FAQ"
    #
    # For incoming mail there is NO name. You only work in your own graph, so that
    # you are the performer goes without saying; putting your name in front of
    # every line is noise. That is also why that line is in the imperative again:
    # without a name in front, a third person reads like a statement of fact
    # instead of a task.
    #
    # For mail you sent, the name is needed, because then the task is about
    # someone else. With several addressees only the FIRST is in the line: that is
    # the main addressee, and three names in a row make the title unreadable. In
    # task owner they all appear, because that is what you want to filter on.
    the_actor_names, the_task_is_delegated = the_actor_names_for(the_messages)
    the_actor_names = [
        the_clean_name for the_clean_name in
        (sanitise_for_tana_node(the_name) for the_name in the_actor_names)
        if the_clean_name
    ]

    if the_task_is_delegated and the_actor_names:
        the_task_line = "{name}: {line}".format(
            name=the_actor_names[0], line=the_task_line)

    the_lines = ["%%tana%%"]
    the_lines.append("- {task} #[[^{tag}]]".format(task=the_task_line, tag=TANA_SUPERTAG_TASK_ID))

    # ---- task owner ---------------------------------------------------------
    # Only set for a DELEGATED task, so for mail that you sent yourself. For
    # incoming mail we leave the field alone: the supertag fills in the default
    # value (you) by itself, and that is exactly right.
    #
    # All addressees, not only the first one from the title: you want to filter
    # on this ("what have I got outstanding with whom"), and then they must all
    # be there. Names that already exist as a node link by themselves; unknown
    # names become plain nodes. That is the same agreement as with Contactperson --
    # do not create a person node automatically.
    if TANA_FIELD_TASK_OWNER_ID and the_task_is_delegated and the_actor_names:
        the_lines.append("  - [[^{field}]]::".format(field=TANA_FIELD_TASK_OWNER_ID))
        for the_name in the_actor_names:
            the_lines.append("    - {value}".format(value=the_name))

    the_briefing_lines = []

    the_deadline = sanitise_for_tana_node(the_task.get("mentionedDeadline", ""))
    if the_deadline:
        the_briefing_lines.append("Stated deadline: " + the_deadline)

    # The sections in a fixed order, with a bold lead-in. Empty sections we skip:
    # a heading without text is worse than no heading.
    #
    # The lead-in is INSIDE the bullet and is not a node of its own. Tana does
    # have a description field on a node, but Tana Paste has no way of writing it;
    # that would cost a second round through the local API and so only work on the
    # Today route. Bold text gives the same reading picture and works everywhere.
    # Tested on 5 August 2026: "**Request:**" becomes <b>Request:</b>.
    for the_key, the_heading in BRIEFING_SECTIONS:
        the_text = sanitise_for_tana_node(the_task["briefing"].get(the_key, ""))
        if the_text:
            the_briefing_lines.append("**{heading}:** {text}".format(heading=the_heading, text=the_text))

    for the_line in the_task["briefing"].get("other", []):
        the_clean_line = sanitise_for_tana_node(the_line)
        if the_clean_line:
            the_briefing_lines.append(the_clean_line)

    if TANA_FIELD_BRIEFING_ID and the_briefing_lines:
        the_lines.append("  - [[^{field}]]::".format(field=TANA_FIELD_BRIEFING_ID))
        for the_line in the_briefing_lines:
            the_lines.append("    - {value}".format(value=the_line))

    # ---- Link to the Message --------------------------------------------------
    # The address of the LAST message: that is the message that was selected and
    # that contains the question. Without this link the task is cut loose from its
    # source, and with a task you want to be able to look back at what exactly it
    # said.
    #
    # Until 13 August 2026 this was markdown INSIDE the briefing, written out as
    # "(link to original e-mail)". That worked exactly once: Tana destroyed the
    # href on the first click and then the address was irretrievably gone. Now it
    # is bare text in a field of its own, like with #Message.
    #
    # NOTE: this is a DIFFERENT field from the one on #Message, with the same
    # name. Fields in Tana are separate attributes; one was created on #task of
    # its own. That the names are equal is no coincidence but a requirement: the
    # command button calls the field with the name expression
    # ${Link to the Message}, and that is how ONE button works on both supertags.
    # So do not rename this field without renaming the other one too.
    the_message_url = build_the_message_url(the_messages[-1]["messageId"])
    if TANA_FIELD_TASK_MESSAGE_LINK_ID and the_message_url:
        the_lines.append("  - [[^{field}]]:: {url}".format(
            field=TANA_FIELD_TASK_MESSAGE_LINK_ID,
            url=the_message_url,
        ))

    return "\n".join(the_lines) + "\n"


# ------------------------------------------------------------------------------
# Deliver directly under today's day node
#
# The local API runs inside the desktop app of Tana Outliner itself, on
# localhost, and is therefore only reachable while that app is open. Two calls
# are enough: ask for the day node (which is created if it does not exist yet)
# and import the Tana Paste under it.
#
# The Tana Paste does not have to change for this: the import endpoint takes
# exactly the same format that otherwise ends up on the clipboard. That is why
# the two destinations share the same code up to and including the last step.
#
# Never let an exception escape: the summary has already been made and paid for,
# and it must not be lost to a Tana that is not running. Every error gives a
# reason here, after which the caller falls back to the clipboard.
# ------------------------------------------------------------------------------
TANA_LOCAL_API_BASE = "http://localhost:8262"
SECONDS_TO_WAIT_FOR_TANA = 20

# How long we give Tana Outliner to start up. It is an Electron app that also
# has to load the workspace before the API answers, so a few seconds is too
# tight. Measured on 4 August 2026, cold start with Tana completely closed: 7.6
# seconds until "nodeSpaceReady". This limit is well above that, so that a slower
# machine or a bigger graph also falls within it. Above it the run falls back to
# the clipboard.
SECONDS_TO_WAIT_FOR_TANA_TO_START = 45
SECONDS_BETWEEN_THE_HEALTH_CHECKS = 0.5

TANA_APPLICATION_NAME = "Tana Outliner"


def the_local_api_is_ready():
    """Does the API answer, and has it loaded its workspace?

    /health needs no token, so this works even when no token has been set up yet.
    "nodeSpaceReady" is the difference between "the app has started" and "the
    app can really do something with your nodes"; right after starting it is
    still false and an import would fail.
    """
    try:
        with urllib.request.urlopen(TANA_LOCAL_API_BASE + "/health", timeout=3) as the_response:
            the_health = json.loads(the_response.read().decode("utf-8"))
        return bool(the_health.get("nodeSpaceReady"))
    except Exception:
        return False


def start_tana_and_wait():
    """Tries to start Tana Outliner and waits until the API is ready.

    Returns (succeeded, reason). If Tana is already running this costs nothing.

    Why start it and not fall back straight away: whoever picks the Today variant
    wants the result in Tana, not on their clipboard. That Tana happens to be
    closed is no reason to saddle the user with a paste buffer; that is the
    emergency brake, not the first answer.
    """
    if the_local_api_is_ready():
        return True, ""

    try:
        # "-g" keeps the app in the background, so that the attention stays in
        # Mail. "-a" with the name and not a path, because the name is fixed and
        # the path is not: an app can also live outside /Applications.
        subprocess.run(
            ["/usr/bin/open", "-g", "-a", TANA_APPLICATION_NAME],
            check=True,
            capture_output=True,
        )
    except FileNotFoundError:
        return False, "could not run /usr/bin/open"
    except subprocess.CalledProcessError as the_error:
        the_detail = (the_error.stderr or b"").decode("utf-8", errors="replace").strip()
        return False, "Tana Outliner could not be started ({detail})".format(
            detail=the_detail or "unknown reason"
        )

    the_deadline = time.monotonic() + SECONDS_TO_WAIT_FOR_TANA_TO_START

    while time.monotonic() < the_deadline:
        if the_local_api_is_ready():
            return True, ""
        time.sleep(SECONDS_BETWEEN_THE_HEALTH_CHECKS)

    return False, "Tana Outliner was still not ready after {seconds} seconds".format(
        seconds=SECONDS_TO_WAIT_FOR_TANA_TO_START
    )


def call_the_local_tana_api(the_path, the_payload=None):
    the_token = os.environ.get("TANA_LOCAL_API_TOKEN", "").strip()

    if not the_token:
        raise RuntimeError(
            "no Personal Token in the Keychain under 'tana-local-api-token'"
        )

    the_data = None
    the_headers = {"Authorization": "Bearer " + the_token}

    if the_payload is not None:
        the_data = json.dumps(the_payload).encode("utf-8")
        the_headers["content-type"] = "application/json"

    the_request = urllib.request.Request(
        TANA_LOCAL_API_BASE + the_path,
        data=the_data,
        headers=the_headers,
        method="POST" if the_payload is not None else "GET",
    )

    with urllib.request.urlopen(the_request, timeout=SECONDS_TO_WAIT_FOR_TANA) as the_response:
        return json.loads(the_response.read().decode("utf-8"))


def deliver_the_paste_to_today(the_tana_paste):
    """Returns (succeeded, reason). The reason is empty when it succeeded."""

    # First make sure there is something to talk to. If Tana is closed we start
    # it; only if that fails is it the clipboard's turn.
    the_running, the_reason = start_tana_and_wait()
    if not the_running:
        return False, the_reason

    try:
        the_day = call_the_local_tana_api(
            "/workspaces/{workspace}/calendar/node?granularity=day".format(workspace=TANA_WORKSPACE_ID)
        )
        the_day_node_id = the_day["nodeId"]

        the_result = call_the_local_tana_api(
            "/nodes/{parent}/import".format(parent=the_day_node_id),
            {"content": the_tana_paste},
        )

        the_number_created = len(the_result.get("createdNodes", []))
        if the_number_created == 0:
            return False, "Tana reported that nothing was created"

        return True, ""

    except urllib.error.HTTPError as the_error:
        the_detail = the_error.read().decode("utf-8", errors="replace")[:200]
        if the_error.code == 401:
            return False, "Tana refused the token (HTTP 401)"
        return False, "Tana returned HTTP {code}: {detail}".format(code=the_error.code, detail=the_detail)

    except urllib.error.URLError as the_error:
        return False, "Tana Outliner not reachable on localhost ({reason})".format(reason=the_error.reason)

    except RuntimeError as the_error:
        # our own message, already in plain language; adding the class name would
        # only be noise in a window the user reads
        return False, str(the_error)

    except Exception as the_error:
        return False, "{kind}: {message}".format(kind=type(the_error).__name__, message=the_error)


# ------------------------------------------------------------------------------
# Main routine
# ------------------------------------------------------------------------------
def the_missing_required_settings():
    """Which settings are missing, in words rather than variable names.

    Checked before anything is sent to the API, so a half configured install
    costs nothing. Most fields may be skipped -- that is what lets this run
    against somebody else's supertag -- but without a supertag there is nothing
    to create, and without the summarised title there is nothing to read.
    """
    the_missing = []

    if not TANA_WORKSPACE_ID:
        the_missing.append("the workspace")

    if os.environ.get("THE_OUTPUT_TYPE") == "task":
        if not TANA_SUPERTAG_TASK_ID:
            the_missing.append("the supertag for tasks")
        if not TANA_FIELD_BRIEFING_ID:
            the_missing.append("the field for the briefing")
    else:
        if not TANA_SUPERTAG_MESSAGE_ID:
            the_missing.append("the supertag for messages")
        if not TANA_FIELD_ESSENCE_ID:
            the_missing.append("the field for the summarised title")

    return the_missing


def main():
    the_input_path = sys.argv[1]
    the_output_path = sys.argv[2]

    the_missing = the_missing_required_settings()
    if the_missing:
        sys.exit(
            "Not configured yet: %s.\n\n"
            "Run the configuration again to fill this in:\n"
            "    python3 configure.py\n\n"
            "Settings file: %s" % (", ".join(the_missing), THE_CONFIGURATION_PATH))

    the_messages = read_the_exchange_file(the_input_path)

    if not the_messages:
        sys.exit("The exchange file contained no messages.")

    # ---- the only place where the two tools diverge ---------------------------
    #
    # MailToTana documents: one summary per message, sent to the API in batches
    # because the quality drops as soon as more than about ten have to go into
    # one answer.
    #
    # MailToTask briefs: ONE task from all the messages together, so also one
    # call. Chopping it up would break the context here, and only one object
    # comes out.
    if os.environ.get("THE_OUTPUT_TYPE") == "task":

        the_task = call_claude_for_the_task(the_messages)
        the_tana_paste = build_the_task_paste(the_messages, the_task)

    else:

        the_summaries = []
        for the_start in range(0, len(the_messages), MESSAGES_PER_API_CALL):
            the_batch = the_messages[the_start:the_start + MESSAGES_PER_API_CALL]
            the_batch_summaries = call_claude_for(the_batch)

            # the model can skip one; pad it out so that the zip() below does not
            # silently drop messages
            while len(the_batch_summaries) < len(the_batch):
                the_batch_summaries.append({"essence": "", "rest": [], "senderName": ""})

            the_summaries.extend(the_batch_summaries[:len(the_batch)])

        the_tana_paste = build_the_tana_paste(the_messages, the_summaries)

    # Always write it out, also with destination "today". The output file is the
    # evidence when tracking down an error, and the fall-back to the clipboard
    # reads from it.
    with open(the_output_path, "w", encoding="utf-8") as the_file:
        the_file.write(the_tana_paste)

    # see the note at WriteTextToFileAsUtf8 in the AppleScript: the summary is
    # confidential too and /tmp is accessible to everybody
    os.chmod(the_output_path, 0o600)

    # ---- the last step: where does it go --------------------------------------
    #
    # The last line on stdout tells the caller what SUCCEEDED, and that is not
    # always what was asked for. If delivery to Tana fails, this line says
    # "clipboard" with a reason after it, and the AppleScript puts the result on
    # the clipboard after all. That way a summary that was made is never lost
    # because Tana happened to be closed.
    if os.environ.get("THE_DESTINATION") != "today":
        print("clipboard")
        return

    the_delivered, the_reason = deliver_the_paste_to_today(the_tana_paste)

    if the_delivered:
        print("today")
    else:
        # One line, always. The reason can come from an error message of the
        # server and that contains line ends and tabs; those would break the
        # contract with the AppleScript, because that splits on the tab.
        print("clipboard\t" + " ".join(the_reason.split()))


if __name__ == "__main__":
    main()
PYTHON_EOF

exit 0
