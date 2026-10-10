#!/usr/bin/env python3
"""Writes ~/.config/mailtotana/config.txt by asking Tana what you have.

Run by install.sh, and runnable on its own when you only want to change a
setting:

    python3 configure.py

WHY THIS EXISTS AT ALL
The script needs node identifiers, not names: field IDs survive a rename in
Tana, names do not. But nobody knows their own field IDs, and looking them up by
hand is both tedious and easy to get wrong -- a field definition in Tana is
itself a node, and copying an ID off a test node gives you one that quietly
stops working the day you tidy up. So this asks your running Tana instead.

Every question offers your actual supertags and fields, plus two escapes:

    o   other -- type an identifier yourself, for the case the list misses it
    s   skip  -- leave this one empty, and nothing is written for that field

Existing answers are offered back as the default, so re-running this to change
one setting means pressing Return a lot.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

THE_LOCAL_API = "http://localhost:8262"
THE_KEYCHAIN_SERVICE = "tana-local-api-token"
THE_CONFIGURATION_PATH = os.path.expanduser("~/.config/mailtotana/config.txt")

# Pulled out of the schema markdown, which looks like:
#     - **Contactperson** (id:kKI5qZiirXUj):: Instance of #Person
#       - E-mail (id:AJkZynRcdPd8)        <- an option, indented
THE_FIELD_PATTERN = re.compile(r"^- \*\*(.+?)\*\*\s*\(id:([^)]+)\)")
THE_OPTION_PATTERN = re.compile(r"^\s+- (.+?)\s*\(id:([^)]+)\)")


# ------------------------------------------------------------------------------
# What we ask for, and in what words
#
# Kept as data rather than as a run of if-statements, so that the questions read
# as one list and a new field is one entry rather than a new branch. The
# explanation matters as much as the question: these are role names from one
# particular setup, and somebody mapping them onto their own supertag needs to
# know what actually lands in the field, not what it is called here.
# ------------------------------------------------------------------------------
THE_MESSAGE_FIELDS = [
    ("tana_field_essence", "the summarised title", False,
     "One sentence saying what the sender does or asks, with their name in\n"
     "    front. \"Alex Moreau: asks whether the audit framework still applies.\"\n"
     "    This is the line you read when scanning your day page, so point it at\n"
     "    whichever field your supertag shows in its title expression."),

    ("tana_field_contactperson", "everyone involved", True,
     "The sender and all recipients, as separate values, so you can click a\n"
     "    person and see every mail they were part of. An \"Options from\n"
     "    supertag\" field pointing at your person tag works best: names that\n"
     "    already exist link up instead of becoming new nodes."),

    ("tana_field_when", "the date and time sent", True,
     "When the mail was sent, written as a Tana date."),

    ("tana_field_content", "the AI summarized content of the message", True,
     "The body of the mail, summarised, as separate lines. Everything that\n"
     "    did not fit in the one-sentence title goes here. Short mails often\n"
     "    have nothing left over, and then this field is not written at all."),

    ("tana_field_message_link", "the link back to the mail", True,
     "The address that reopens the original message in Apple Mail. Plain\n"
     "    text, not a hyperlink -- see tana-schema.md for why, and for the\n"
     "    command button that turns it into one click."),

    ("tana_field_media_type", "the \"this came in by mail\" label", True,
     "A fixed label telling these nodes apart from WhatsApp, SMS or Teams\n"
     "    messages kept under the same supertag. Skip it if only email ever\n"
     "    gets this supertag."),
]

THE_TASK_FIELDS = [
    ("tana_field_briefing", "the briefing", False,
     "Everything needed to work on the task without opening the mail: what\n"
     "    prompted it, what is asked, what was agreed, what you need, and\n"
     "    relevant background."),

    ("tana_field_task_owner", "who has to deliver", True,
     "Only written for mail YOU sent: the recipients go here, because you are\n"
     "    waiting on them. For incoming mail this is left alone so your own\n"
     "    default applies."),

    ("tana_field_task_message_link", "the link back to the mail", True,
     "The same address as on the message supertag. A separate field, with\n"
     "    deliberately the same name, so one command button serves both."),
]


def the_token():
    """The Tana token from the Keychain, or None.

    Read here rather than passed in by the installer: a secret handed over as an
    argument or an environment variable shows up in the process table.
    """
    try:
        the_result = subprocess.run(
            ["/usr/bin/security", "find-generic-password",
             "-a", os.environ.get("USER", ""), "-s", THE_KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, check=True)
        return the_result.stdout.strip() or None
    except subprocess.CalledProcessError:
        return None


def ask_tana(the_path, the_token_value):
    the_request = urllib.request.Request(
        THE_LOCAL_API + the_path,
        headers={"Authorization": "Bearer " + the_token_value})
    with urllib.request.urlopen(the_request, timeout=20) as the_answer:
        return json.loads(the_answer.read().decode("utf-8"))


def the_fields_of(the_tag_id, the_token_value):
    """Gives [(name, id, [(option name, option id), ...]), ...] for a supertag.

    The schema endpoint answers in markdown rather than JSON, so this reads it
    line by line. Options come back indented under the field they belong to,
    which is how the media type values are offered later on.
    """
    the_markdown = ask_tana("/tags/%s/schema" % the_tag_id, the_token_value).get("markdown", "")

    the_fields = []
    for the_line in the_markdown.splitlines():
        the_field = THE_FIELD_PATTERN.match(the_line)
        if the_field:
            the_fields.append((the_field.group(1).strip(), the_field.group(2).strip(), []))
            continue

        the_option = THE_OPTION_PATTERN.match(the_line)
        if the_option and the_fields:
            the_fields[-1][2].append((the_option.group(1).strip(), the_option.group(2).strip()))

    return the_fields


# ------------------------------------------------------------------------------
# Asking
# ------------------------------------------------------------------------------
def ask_for_a_line(the_question, the_current_value=""):
    the_suffix = " [%s]" % the_current_value if the_current_value else ""
    try:
        the_answer = input("%s%s: " % (the_question, the_suffix)).strip()
    except EOFError:
        return the_current_value
    return the_answer or the_current_value


def choose_from(the_title, the_explanation, the_choices, the_current_value,
                the_skippable=True):
    """One menu. Returns the chosen identifier, or "" when skipped.

    the_choices is [(label, identifier), ...]. The current value, if it is still
    among the choices, is marked and used when the user just presses Return --
    which is what makes re-running this cheap.
    """
    print("")
    print("  %s" % the_title)
    if the_explanation:
        print("    %s" % the_explanation)
    print("")

    for the_number, (the_label, the_identifier) in enumerate(the_choices, 1):
        the_marker = "  <- current" if the_identifier == the_current_value else ""
        print("    %2d) %s%s" % (the_number, the_label, the_marker))

    print("     o) other -- type an identifier yourself")
    if the_skippable:
        print("     s) skip  -- leave this empty")

    while True:
        try:
            the_answer = input("  > ").strip().lower()
        except EOFError:
            return the_current_value

        if not the_answer:
            return the_current_value

        if the_answer == "o":
            return ask_for_a_line("    identifier", the_current_value)

        if the_answer == "s" and the_skippable:
            return ""

        if the_answer.isdigit() and 1 <= int(the_answer) <= len(the_choices):
            return the_choices[int(the_answer) - 1][1]

        print("    Not one of the options. Enter a number, o, or s.")


# ------------------------------------------------------------------------------
# Reading and writing the settings file
# ------------------------------------------------------------------------------
def read_the_existing_settings():
    the_settings = {}
    try:
        with open(THE_CONFIGURATION_PATH, encoding="utf-8") as the_file:
            for the_line in the_file:
                the_line = the_line.strip()
                if the_line and not the_line.startswith("#") and "=" in the_line:
                    the_key, _, the_value = the_line.partition("=")
                    the_settings[the_key.strip().lower()] = the_value.strip()
    except OSError:
        pass
    return the_settings


def write_the_settings(the_settings):
    """Writes the file from the template, so the explanations stay with it.

    Not a bare dump of key=value: somebody opening this file in a year should
    find out what each setting does without going back to the repository.
    """
    the_template_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "config.example.txt")
    try:
        with open(the_template_path, encoding="utf-8") as the_file:
            the_lines = the_file.read().splitlines()
    except OSError:
        the_lines = ["# MailToTana configuration"] + \
                    ["%s = " % the_key for the_key in sorted(the_settings)]

    the_written = set()
    the_result = []
    for the_line in the_lines:
        the_stripped = the_line.strip()
        if the_stripped and not the_stripped.startswith("#") and "=" in the_stripped:
            the_key = the_stripped.partition("=")[0].strip().lower()
            if the_key in the_settings:
                the_result.append("%s = %s" % (the_key, the_settings[the_key]))
                the_written.add(the_key)
                continue
        the_result.append(the_line)

    # Anything the template does not know about still has to survive.
    for the_key in sorted(set(the_settings) - the_written):
        the_result.append("%s = %s" % (the_key, the_settings[the_key]))

    os.makedirs(os.path.dirname(THE_CONFIGURATION_PATH), exist_ok=True)
    with open(THE_CONFIGURATION_PATH, "w", encoding="utf-8") as the_file:
        the_file.write("\n".join(the_result) + "\n")


# ------------------------------------------------------------------------------
def main():
    the_token_value = the_token()
    if not the_token_value:
        print("No Tana token in the Keychain yet, so your supertags cannot be")
        print("looked up. Store the token first, then run this again:")
        print("")
        print("    python3 configure.py")
        return 1

    the_settings = read_the_existing_settings()

    print("")
    print("Settings. Press Return to keep what is already there.")

    # ---- which workspace ------------------------------------------------------
    the_workspaces = ask_tana("/workspaces", the_token_value)
    if len(the_workspaces) == 1:
        the_settings["tana_workspace_id"] = the_workspaces[0]["id"]
        print("")
        print("  Workspace: %s (the only one)" % the_workspaces[0]["name"])
    else:
        the_settings["tana_workspace_id"] = choose_from(
            "Which workspace do the messages go into?", "",
            [(w["name"], w["id"]) for w in the_workspaces],
            the_settings.get("tana_workspace_id", ""), the_skippable=False)

    the_tags = ask_tana("/workspaces/%s/tags" % the_settings["tana_workspace_id"],
                        the_token_value)
    the_tag_choices = sorted([(t["name"], t["id"]) for t in the_tags],
                             key=lambda the_pair: the_pair[0].lower())

    # ---- the message supertag and its fields ----------------------------------
    the_settings["tana_supertag_message"] = choose_from(
        "Which supertag do you use for messages?",
        "Each mail becomes one node with this supertag.",
        the_tag_choices, the_settings.get("tana_supertag_message", ""),
        the_skippable=False)

    the_fields = the_fields_of(the_settings["tana_supertag_message"], the_token_value)
    the_field_choices = [(name, identifier) for name, identifier, _ in the_fields]

    for the_key, the_title, the_skippable, the_explanation in THE_MESSAGE_FIELDS:
        the_settings[the_key] = choose_from(
            "Which field holds %s?" % the_title, the_explanation,
            the_field_choices, the_settings.get(the_key, ""), the_skippable)

    # The value for the media type field, offered from that field's own options.
    if the_settings.get("tana_field_media_type"):
        the_options = next((options for _, identifier, options in the_fields
                            if identifier == the_settings["tana_field_media_type"]), [])
        if the_options:
            the_settings["tana_media_type_value"] = choose_from(
                "Which value means \"came in by mail\"?",
                "Written into that field on every message.",
                [(name, name) for name, _ in the_options],
                the_settings.get("tana_media_type_value", "E-mail"),
                the_skippable=False)
        else:
            the_settings["tana_media_type_value"] = ask_for_a_line(
                "  Which value means \"came in by mail\"?",
                the_settings.get("tana_media_type_value", "E-mail"))

    # ---- the task supertag, which is optional ---------------------------------
    the_settings["tana_supertag_task"] = choose_from(
        "Which supertag do you use for tasks?",
        "Used by the third shortcut, which turns a mail into one task with a\n"
        "    briefing. Skip this if you only want messages.",
        the_tag_choices, the_settings.get("tana_supertag_task", ""))

    if the_settings["tana_supertag_task"]:
        the_task_fields = the_fields_of(the_settings["tana_supertag_task"], the_token_value)
        the_task_choices = [(name, identifier) for name, identifier, _ in the_task_fields]

        for the_key, the_title, the_skippable, the_explanation in THE_TASK_FIELDS:
            the_settings[the_key] = choose_from(
                "Which field holds %s?" % the_title, the_explanation,
                the_task_choices, the_settings.get(the_key, ""), the_skippable)
    else:
        for the_key, _, _, _ in THE_TASK_FIELDS:
            the_settings[the_key] = ""

    # ---- about you ------------------------------------------------------------
    print("")
    print("  A few things about you.")
    print("")
    the_settings["output_language"] = ask_for_a_line(
        "  Language the summaries are written in",
        the_settings.get("output_language", "English"))
    print("")
    print("  Your own full name -- the person, not an address. It has to match")
    print("  the node you have in Tana for yourself, because it is used as the")
    print("  owner of a task that comes out of a thread you never wrote in.")
    the_settings["owner_name"] = ask_for_a_line(
        "  Your full name", the_settings.get("owner_name", ""))

    print("")
    print("  Every address you send mail FROM, separated by commas. This is how")
    print("  a message is recognised as yours. Include aliases and old addresses")
    print("  that still appear as the sender on archived mail.")
    the_settings["my_email_addresses"] = ask_for_a_line(
        "  Your addresses", the_settings.get("my_email_addresses", ""))

    write_the_settings(the_settings)

    print("")
    print("  Settings written to %s" % THE_CONFIGURATION_PATH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
