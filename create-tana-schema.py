#!/usr/bin/env python3
"""Creates the supertags and fields this tool needs, if you do not have them yet.

    python3 create-tana-schema.py

Optional. Run it only when you are starting from nothing; then run configure.py,
which will find what this made.

WHY A SCRIPT AND NOT A TANA PASTE
A paste can create nodes and apply existing supertags, but it cannot define a
supertag template -- the fields, their types, their options. The local API can,
so that is what this uses.

TWO WAYS TO USE IT, and the second is the common one. You can have it create a
supertag from scratch, or point it at a supertag you already have and let it add
only the fields that are missing. Most people already have something for tasks
and would rather extend that than carry a second one.

Nothing is ever overwritten: a field that already exists by name is left exactly
as it is, including its type.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

THE_LOCAL_API = "http://localhost:8262"
THE_KEYCHAIN_SERVICE = "tana-local-api-token"

# ------------------------------------------------------------------------------
# What a supertag needs, as data
#
# "plain" throughout for the text fields, including the link back to the mail.
# A URL-typed field looks like the obvious choice there, but an import never
# produces a url-typed VALUE whatever the field says, so the type buys nothing
# and only invites questions. See tana-schema.md.
# ------------------------------------------------------------------------------
THE_MESSAGE_FIELDS = [
    ("Essence of the message", "plain",
     "One sentence: what the sender does or asks, with their name in front"),
    ("Contactperson", "instance",
     "Everyone involved: the sender and all recipients"),
    ("When", "date", "When the mail was sent"),
    ("Content of the message", "plain",
     "The AI summarized content of the message"),
    ("Media type", "options", "Which channel this came in by"),
    ("Link to the Message", "plain",
     "Reopens the original mail. Plain text on purpose"),
]

THE_MEDIA_TYPE_OPTIONS = ["E-mail", "WhatsApp", "SMS", "Teams chat", "Signal", "LinkedIn"]

THE_TASK_FIELDS = [
    ("briefing or result", "plain",
     "Everything needed to work on this without opening the mail"),
    ("task owner", "instance", "Who has to deliver"),
    ("Link to the Message", "plain",
     "Reopens the original mail. Plain text on purpose"),
]


def the_token():
    try:
        the_result = subprocess.run(
            ["/usr/bin/security", "find-generic-password",
             "-a", os.environ.get("USER", ""), "-s", THE_KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, check=True)
        return the_result.stdout.strip() or None
    except subprocess.CalledProcessError:
        return None


def ask_tana(the_path, the_token_value, the_payload=None):
    the_request = urllib.request.Request(
        THE_LOCAL_API + the_path,
        data=json.dumps(the_payload).encode("utf-8") if the_payload is not None else None,
        headers={"Authorization": "Bearer " + the_token_value,
                 "Content-Type": "application/json"},
        method="POST" if the_payload is not None else "GET")
    with urllib.request.urlopen(the_request, timeout=30) as the_answer:
        return json.loads(the_answer.read().decode("utf-8"))


def the_existing_field_names(the_tag_id, the_token_value):
    """Just the names. Enough to know what not to create again."""
    the_markdown = ask_tana("/tags/%s/schema" % the_tag_id, the_token_value).get("markdown", "")
    the_names = set()
    for the_line in the_markdown.splitlines():
        if the_line.startswith("- **") and "**" in the_line[4:]:
            the_names.add(the_line[4:].split("**", 1)[0].strip())
    return the_names


def ask_yes(the_question, the_default_is_yes=True):
    the_hint = "Y/n" if the_default_is_yes else "y/N"
    try:
        the_answer = input("%s (%s) " % (the_question, the_hint)).strip().lower()
    except EOFError:
        return the_default_is_yes
    if not the_answer:
        return the_default_is_yes
    return the_answer in ("y", "yes", "j", "ja")


def choose_or_create(the_role, the_tags, the_token_value):
    """Returns the tag id to work on, or None when the user wants to skip it."""
    print("")
    print("  %s" % the_role)
    print("")
    for the_number, (the_name, _) in enumerate(the_tags, 1):
        print("    %2d) %s" % (the_number, the_name))
    print("     n) new  -- create a supertag for this")
    print("     s) skip -- I do not want this one")

    while True:
        try:
            the_answer = input("  > ").strip().lower()
        except EOFError:
            return None

        if the_answer == "s":
            return None

        if the_answer == "n":
            the_name = input("    Name for the new supertag: ").strip()
            if not the_name:
                continue
            the_made = ask_tana("/workspaces/%s/tags" % THE_WORKSPACE_ID, the_token_value,
                                {"name": the_name,
                                 "description": "Created by MailToTana"})
            the_id = the_made.get("tagId") or the_made.get("id")
            print("    Created \"%s\" (%s)" % (the_name, the_id))
            return the_id

        if the_answer.isdigit() and 1 <= int(the_answer) <= len(the_tags):
            return the_tags[int(the_answer) - 1][1]

        print("    Not one of the options. Enter a number, n, or s.")


def add_the_missing_fields(the_tag_id, the_wanted, the_person_tag_id, the_token_value):
    the_present = the_existing_field_names(the_tag_id, the_token_value)

    for the_name, the_type, the_description in the_wanted:
        if the_name in the_present:
            print("    kept    %s (already there)" % the_name)
            continue

        the_payload = {"name": the_name, "dataType": the_type,
                       "description": the_description}

        if the_type == "instance":
            # Without a tag to point at, an instance field has nothing to offer.
            # Falling back to plain keeps the field useful instead of broken.
            if the_person_tag_id:
                the_payload["sourceTagId"] = the_person_tag_id
            else:
                the_payload["dataType"] = "plain"

        if the_type == "options":
            the_payload["options"] = THE_MEDIA_TYPE_OPTIONS

        try:
            ask_tana("/tags/%s/fields" % the_tag_id, the_token_value, the_payload)
            print("    added   %s" % the_name)
        except urllib.error.HTTPError as the_error:
            print("    FAILED  %s -- %s" % (the_name, the_error))


def main():
    global THE_WORKSPACE_ID

    the_token_value = the_token()
    if not the_token_value:
        sys.exit("No Tana token in the Keychain. Store it first, then run this again.")

    the_workspaces = ask_tana("/workspaces", the_token_value)
    if len(the_workspaces) == 1:
        THE_WORKSPACE_ID = the_workspaces[0]["id"]
        print("Workspace: %s" % the_workspaces[0]["name"])
    else:
        print("Workspaces:")
        for the_number, the_workspace in enumerate(the_workspaces, 1):
            print("  %2d) %s" % (the_number, the_workspace["name"]))
        the_choice = int(input("> ").strip() or "1")
        THE_WORKSPACE_ID = the_workspaces[the_choice - 1]["id"]

    the_tags = sorted(
        [(t["name"], t["id"]) for t in
         ask_tana("/workspaces/%s/tags" % THE_WORKSPACE_ID, the_token_value)],
        key=lambda the_pair: the_pair[0].lower())

    print("")
    print("Nothing here is overwritten. A field that already exists by name is")
    print("left exactly as it is.")

    # A tag for people, so that Contactperson and task owner can link to real
    # nodes instead of making a new loose one for every name they meet.
    print("")
    print("  Do you have a supertag for people? Contactperson and task owner will")
    print("  point at it, so that a name that already exists links up instead of")
    print("  becoming a new node every time.")
    the_person_tag_id = None
    for the_name, the_id in the_tags:
        if the_name.lower() in ("person", "people", "persoon", "contact", "employee"):
            if ask_yes("  Use \"%s\"?" % the_name):
                the_person_tag_id = the_id
                break
    if not the_person_tag_id:
        the_person_tag_id = choose_or_create(
            "Which supertag do you use for people?", the_tags, the_token_value)

    the_message_tag = choose_or_create(
        "Which supertag should hold your messages?", the_tags, the_token_value)
    if the_message_tag:
        add_the_missing_fields(the_message_tag, THE_MESSAGE_FIELDS,
                               the_person_tag_id, the_token_value)

    the_task_tag = choose_or_create(
        "Which supertag should hold your tasks?", the_tags, the_token_value)
    if the_task_tag:
        add_the_missing_fields(the_task_tag, THE_TASK_FIELDS,
                               the_person_tag_id, the_token_value)

    print("")
    print("Done. Now run:  python3 configure.py")
    print("It will find what this just made and write your settings.")
    return 0


THE_WORKSPACE_ID = ""

if __name__ == "__main__":
    sys.exit(main())
