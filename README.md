# MailToTana

Summarise the e-mail you have selected in Apple Mail with Claude, and put the result in [Tana](https://tana.inc): one node per mail, or one task with a briefing. One keystroke, from inside Mail.

> **Shared as-is, with no support.** This is a personal tool that I use myself and decided to share. It is not a product. Issues are switched off on purpose. I will not answer questions, fix bugs, or review pull requests. If it breaks on your machine, you have the source: it is plain AppleScript, zsh and Python, and it is commented heavily enough to read. Fork it and make it yours. MIT licence, see `LICENSE`.

## What it does

Select one message (or one in a thread) in Apple Mail and press a shortcut. MailToTana expands the thread, strips quoted text and signatures, asks Claude for a summary whose length scales with the message, and writes Tana nodes.

There are three shortcuts, all from one code base:

| Quick Action | Result |
|---|---|
| **MailToTana** | one node per mail, as Tana Paste on your clipboard. You paste it where you want it. |
| **MailToTana to Today** | the same nodes, delivered straight under today's day node through Tana's local API. |
| **MailToTask** | one **task** made from the whole thread, with a structured briefing, under today's day node. |

### What a message node looks like

For a mail from "Alex Moreau" that asks whether an audit framework still applies to a new contract, you get a node like this (field names are yours; these are the defaults of `create-tana-schema.py`):

```
Wed, 7 Oct 2026 - Alex Moreau: asks whether the audit framework still applies to the new contract   #Message
  Essence of the message   Alex Moreau: asks whether the audit framework still applies to the new contract
  Contactperson            Alex Moreau, Renée Müller, Pieter Jansen
  When                     Wed, 7 Oct 2026, 09:14
  Media type               E-mail
  Content of the message   - The contract was renewed in September with changed data-processing terms.
                           - Alex wants an answer before the supplier meeting on Friday.
  Link to the Message      message://%3c...%3e        (one click on the button opens the original in Mail)
```

* **The title** is one sentence, starting with a verb, with the sender's name in front. You can scan a day page of mail in seconds.
* **Contactperson** holds everyone involved, as separate values, so you can click a person and see every mail they were part of. Names are looked up in your Contacts, so you get "Renée Müller" and not an address.
* **Content** is the rest of the summary, one sentence per line. Short mail often has nothing left over; then the field is not written at all.
* **Length scales with the mail.** A three-line note is kept almost whole; a 2000-word thread is cut to about 15%.

### What a task looks like

From a thread where a colleague asked you to review a document, **MailToTask** gives:

```
answer Renée Müller about the data processing agreement                  #task
  briefing or result
    **Reason:** Renée Müller sent the revised agreement on 5 October after the supplier changed the retention terms.
    **Request:** Check whether the new retention period of 24 months is acceptable and reply before the 15th.
    **Agreement:** Pieter Jansen already confirmed the security annex; only the retention clause is open.
    **Needed:** The signed annex from September and the current retention policy.
    **Stated deadline:** before 15 October
  Link to the Message   message://%3c...%3e
```

The direction of the mail decides the form. If the mail **came in**, the title is an instruction to you ("answer ...", "review ...") with no performer named. If **you sent** it, you delegated something: the title becomes "Alex Moreau: adds two new items to the FAQ" and the recipients go into the task-owner field, so you can see in your list what you are waiting for.

A task never gets a due date from the tool. A deadline that the mail mentions is written as the first line of the briefing, and you decide whether it becomes yours.

## What you need

* A Mac running macOS, with **Apple Mail** as your mail client. There is no version for other clients.
* **Tana Desktop**, running, with a **Personal Token** (profile, top right → API tokens → Personal Tokens). Tana serves a local API on `localhost:8262` while the app is open.
* An **Anthropic API key** with prepaid credit, from [platform.claude.com](https://platform.claude.com). This is separate from any Claude subscription and is billed per use. Watch your usage on that site; the tool refuses to process more than 20 messages in one run (configurable), so a stray selection cannot cost a lot.
* The tools macOS already has: zsh, Python 3 (Command Line Tools), `security`, `osacompile`. No Homebrew, no pip, no dependencies.

Both secrets live in your macOS Keychain, never in a file.

## Install

1. **Download** this repository (Code → Download ZIP) and unzip it somewhere. Keep that folder; the installer runs from it.

2. **Store your Anthropic API key** in the Keychain. In Terminal, all on one line, then paste the key when asked:

   ```
   security add-generic-password -a "$USER" -s anthropic-api-key -j "Used by MailToTana" -U -w
   ```

   If a Keychain dialog appears later, choose **Always Allow**, otherwise it keeps asking each time the tool runs.

3. **Make the supertags and fields in Tana**, unless you already have them. Either follow [`tana-schema.md`](tana-schema.md) by hand, or let a script do it (Tana must be running, with a Personal Token in the Keychain; see step 4 for how to store one):

   ```
   python3 create-tana-schema.py
   ```

   It only ever adds what is missing and never changes a field that already exists. If you already have a task supertag, point it at that one and it adds only the extra fields.

4. **Run the installer** from the unzipped folder:

   ```
   /bin/zsh install.sh
   ```

   It compiles the AppleScript, installs the helper in `~/bin`, creates the three Quick Actions, offers to assign keyboard shortcuts, runs a pre-flight check, offers to store your Tana token (it checks that Tana accepts it), and finally starts the configuration (next section).

5. **Restart Mail.** The first time you run an action, macOS asks for permission for Mail and Contacts. Approve both. If you decline Contacts, addresses appear instead of names.

6. Select a mail, press your shortcut.

### Manual step: the "Open original e-mail" button

Tana strips the link to Mail after the first click if it is stored as a real link, so the tool stores it as plain text, and a small command button turns that into one click. A button cannot be created through the API; you make it once in Tana. See [`tana-schema.md`](tana-schema.md), section "The button". Everything else works without it; you just cannot jump back to the original with one click.

## Fit it to your own supertags

All settings are in one file, `~/.config/mailtotana/config.txt`. The installer writes it by **asking your running Tana** which supertags and fields you have. For each role it shows the real fields of your supertag as a numbered menu, with `o) other` (type an ID yourself) and `s) skip` on every question. To redo this at any time:

```
python3 configure.py
```

You can also edit the file by hand; `config.example.txt` explains every key.

The idea behind it: **the code knows roles, not names.** It does not care what your supertag is called or what your fields are called, only what each one is for.

| Role | Setting | Required? |
|---|---|---|
| supertag for a mail | `tana_supertag_message` | yes |
| the summarised title (one sentence) | `tana_field_essence` | yes |
| people involved | `tana_field_contactperson` | no |
| channel label ("E-mail") | `tana_field_media_type` + `tana_media_type_value` | no |
| date sent | `tana_field_when` | no |
| rest of the summary | `tana_field_content` | no |
| address of the original mail | `tana_field_message_link` | no |
| supertag for a task | `tana_supertag_task` | only for MailToTask |
| briefing | `tana_field_briefing` | only for MailToTask |
| task owner | `tana_field_task_owner` | no |
| address, on the task | `tana_field_task_message_link` | no |

**An empty value skips that field**: nothing is written for it. So you can run it against a supertag that has only a title and a body. If a required setting is missing, the tool refuses to run and says in words what is missing.

Practical advice:

* **Use your own supertag.** You do not need a `#Message` supertag; any supertag will do as long as the roles above map to fields on it.
* **Make Contactperson an "Instance of" your person supertag.** Then names that already exist link up. With a plain text field every mail makes new loose nodes.
* **Always take field IDs from the supertag, not from a test node.** The installer does this for you. If you fill IDs in by hand and the first node you used the field on goes to the trash, the field definition goes with it.
* **Language:** `output_language = Dutch` (or any language Claude knows). The prompts are in English; this only sets the language of the answer. Your mail can be in any language regardless.
* **Your own addresses** go in `my_email_addresses`, comma separated. It is how the tool knows a mail is yours (no Contactperson on your own mail; a task from a mail you sent is a delegated task). Include old addresses and aliases; matching is exact.
* **Style of the summaries** is in two prompts at the top of the Python in `mailtotana-helper.sh` (`SYSTEM_PROMPT` and `TASK_SYSTEM_PROMPT`). Edit them, run `install.sh` again.
* **Different model, batch size, message ceiling:** the "Tuning" section of `config.txt`.

## How it works, briefly

```
Quick Action  ->  MailToTana.scpt  ->  mailtotana-helper.sh  ->  clipboard or Tana
 (no logic)        (talks to Mail)      (zsh + Python: Claude API, Tana Paste)
```

* The AppleScript is the only part that can talk to Mail. It expands the thread, reads each message and looks names up in Contacts, then writes a plain text exchange file in `/tmp`.
* The helper strips quotes and signatures, calls the Claude API (structured output through tool use, in batches of 10), and builds the Tana Paste. It is the only place that formats Tana Paste.
* For "to Today" it starts Tana if it is closed, asks for the day node and imports the paste there. If that fails for any reason it falls back to the clipboard: **a summary that has been paid for is never thrown away.**
* Text from mail is neutralised before it goes into Tana. A `#word` in a mail would otherwise create a supertag in your schema, `::` would create a field, and `[[ ]]` a reference.

The code comments explain the reasons behind each choice, including the things that cost an afternoon to find.

## Known limits

* macOS and Apple Mail only.
* Tana Desktop has to be running for the "to Today" variants (the tool starts it if it can).
* Tana creates roughly five nodes per second, so very long selections take a while. The default ceiling is 20 messages per run.
* The link back to the original mail is a `message://` address, which only works on the Mac whose Mail has that message.
* Built and tested on one person's setup. Things I have not tested: other Tana workspaces than mine, macOS versions other than the ones I use, mail accounts other than the ones I use.

## Uninstall

Delete the three Quick Actions from `~/Library/Services`, `~/Library/Scripts/MailToTana.scpt`, `~/bin/mailtotana-helper.sh`, and `~/.config/mailtotana`. Remove the two Keychain items (`anthropic-api-key`, `tana-local-api-token`) in Keychain Access.

## Files

| File | What it is |
|---|---|
| `install.sh` | installer; compiles, installs, builds the Quick Actions, runs the configuration |
| `configure.py` | asks your running Tana for supertags and fields, writes `config.txt` |
| `create-tana-schema.py` | optional; creates the supertags and fields this tool needs |
| `config.example.txt` | every setting, explained |
| `MailToTana.applescript` | the Mail side |
| `mailtotana-helper.sh` | the Claude and Tana side |
| `tana-schema.md` | the supertags and fields, and the manual button |

## Licence

MIT, see `LICENSE`. In plain words: use it, change it, share it, no warranty, and no support.
