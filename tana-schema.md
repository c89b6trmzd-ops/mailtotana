# The Tana side: supertags, fields, and one button

MailToTana writes into supertags you own. This page lists what those supertags need, why a few choices are the way they are, and the one thing that has to be done by hand.

You do **not** need to use these names. The tool works with roles, not names (see "Fit it to your own supertags" in the README). Use `python3 create-tana-schema.py` to create everything below, or to add only the missing fields to a supertag you already have.

## Message supertag (one node per mail)

| Field | Type | Role | Required |
|---|---|---|---|
| Essence of the message | plain | the summarised title: one sentence, sender's name in front | **yes** |
| Contactperson | Instance of your person supertag | everyone involved, as separate values | no |
| When | date | when the mail was sent | no |
| Content of the message | plain | the AI summarised content of the message, one sentence per line | no |
| Media type | options | channel label; one option must equal `tana_media_type_value` (default `E-mail`) | no |
| Link to the Message | **plain** | address that reopens the mail in Apple Mail | no |

Suggested **title expression** on the supertag: `${When} - ${Essence of the message}`. The helper puts the sender's name inside the essence on purpose, so the title reads as one running sentence. Keeping the people out of the title expression matters: a group mail has ten of them, and the point of the sentence ends up at the far end of a very long line. The Contactperson field is for querying; the title is for reading.

## Task supertag (one task per thread), optional

| Field | Type | Role | Required |
|---|---|---|---|
| briefing or result | plain | the briefing, as bold lead-ins (Reason, Request, Agreement, Needed, Background) plus free lines | **yes** |
| task owner | Instance of your person supertag | only written for mail **you** sent; the recipients go here | no |
| Link to the Message | **plain** | same as above | no |

Due date, status and priority are never written by the tool; they get whatever default your supertag gives them. A deadline mentioned in the mail is added as the first line of the briefing instead, because what a mail says is usually the date *someone else* wants it by, and whether that becomes your deadline is your call.

For incoming mail the task-owner field is left alone, so your supertag's own default (normally you) applies.

## Why "Link to the Message" is plain text

Three facts, each learned the hard way:

1. An import never produces a URL-typed value, whatever type the field has. A URL-typed field therefore buys nothing.
2. Tana turns an imported `message://...` into a hyperlink and **removes the target after the first click**. The address is then gone for good. Plain text has nothing to remove.
3. A title expression such as `${Link to the Message}` returns the *raw* content of the field. If the content were markdown, the button below would be handed `<a href="...">` as its URL, and nothing would happen. Tana's error says only "Error fetching API response".

So the address is stored as bare text, and a command button does the opening.

There are two fields with the same name, one on the message supertag and one on the task supertag. That is deliberate: the button refers to the field by name, so **one button works on both**. If you rename one, rename the other.

Set the field to **Hide field → when empty**, so nodes without a link do not show an empty row.

## The button (manual, once)

This cannot be created through the API.

1. Create a **command node**. Name it something like "Open original e-mail".
2. Add the command **Open link** (system command `SYS_M035`).
3. Give it the parameter: `URL: ${Link to the Message}`
4. Put the button where you want it. I put mine inside the supertag's template, next to the link field, so every message and task node has it. If you have two supertags, either put one on each, or put one on each and give them the same name.

One click now hands the `message://` address to macOS, which opens the original mail in Apple Mail.

Do not use the "Make API request" command for this. It is blocked by Tana's content security policy for anything but `localhost`.

## Things worth knowing

* **Take field IDs from the supertag, never from a test node.** A field definition is itself a node, and it goes to the trash together with the first node it was used on. Writing to that ID afterwards produces orphaned values that show up as plain text. `configure.py` reads the supertag, so it cannot make this mistake.
* **Contactperson as "Instance of #Person".** A bare name links to an existing node with exactly that name. If the name does not exist yet, Tana makes a new untagged node, and makes it again for the next mail. The tool derives a proper name from an address whenever it can (`pieter.jansen@example.com` becomes "Pieter Jansen"), for that reason.
* **Text from mail is neutralised** before it is written, because Tana Paste executes things that also occur in ordinary correspondence: `#word` creates a supertag, `::` creates a field, `[[x]]` creates a reference. The tool strips those.
* **Two Personal Tokens work side by side** on one graph, so you can give each machine its own token and revoke one without silencing the other.
