--------------------------------------------------------------------------------
-- MailToTana
--
-- Summarises the selected mail in Apple Mail with Claude and writes the result
-- into Tana: either onto the clipboard as Tana Paste, or straight under today's
-- day node through Tana's local API.
--
-- Three shortcuts come out of one code base:
--
--     message -> clipboard    a node per mail, for you to paste where you want
--     message -> today        the same, delivered into Tana directly
--     task    -> today        one task with a briefing, made from the thread
--
-- What it gets you per message: a one-sentence summary with the sender's name in
-- front, everyone involved as separate values you can click through, the date,
-- the rest of the summary, and an address that reopens the original mail.
--
-- Apple Mail only, macOS only. It talks to Mail through AppleScript, so there is
-- no version of this for any other client.
--------------------------------------------------------------------------------
--
-- ARCHITECTURE: WHO DOES WHAT
--
--     Quick Action stub  ->  THIS SCRIPT  ->  mailtotana-helper.sh  ->  Tana
--       (a dozen lines,       (talks to          (zsh + Python:
--        no logic)             Mail)              the API, the paste)
--
-- This script is the only layer that can talk to Apple Mail, and that is exactly
-- its job: read the selection, expand the thread through the References and
-- In-Reply-To headers, pull sender, recipients, date, subject, Message-ID and
-- body from every message, and look names up in Contacts. The result goes to an
-- exchange file in /tmp as plain text, with RS/US/GS as separators.
--
-- What this script deliberately does NOT do: summarise, build JSON, call the API
-- or compose the Tana Paste. All of that happens in the Python helper inside
-- mailtotana-helper.sh. The reason is narrow and practical: getting mail text
-- full of quotes, backslashes and emoji safely into JSON is a source of silent
-- errors in AppleScript and zsh, and one line of standard library in Python.
--
-- Afterwards this script only puts the output on the clipboard, when that is
-- where it was asked to go.
--
--------------------------------------------------------------------------------
--
-- SETTINGS
--
-- There is nothing to configure in this file. Everything lives in
-- ~/.config/mailtotana/config.txt, which install.sh writes for you and which
-- the Python helper reads as well. See README.md.
--
-- This script knows no Tana identifiers at all. The paste is built entirely in
-- the helper; here there is only what Mail can tell us.
--
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- Settings
--
-- There is nothing to configure in this file. Everything lives in
-- ~/.config/mailtotana/config.txt, which install.sh writes and which the Python
-- helper reads as well. One file, one source of truth.
--
-- Only two settings are needed on this side, and both are needed BEFORE the
-- helper ever runs, which is why this script reads them itself rather than
-- waiting to be told: the addresses that are yours, and the ceiling on how many
-- messages one run may process.
--------------------------------------------------------------------------------
property PathOfTheConfigurationFileRelativeToHome : ".config/mailtotana/config.txt"

-- Read once per run and remembered. Reading a small file is cheap, but this
-- handler is called for every sender and every recipient of every message, and
-- that would add up to hundreds of reads on a long thread.
property TheRememberedSettings : missing value

on TheSettingNamed(theKey, theFallback)
	if TheRememberedSettings is missing value then my LoadTheSettings()

	repeat with thisPair in TheRememberedSettings
		if item 1 of thisPair is theKey then
			if item 2 of thisPair is "" then return theFallback
			return item 2 of thisPair
		end if
	end repeat

	return theFallback
end TheSettingNamed

on LoadTheSettings()
	set TheRememberedSettings to {}

	set theConfigurationPath to (POSIX path of (path to home folder)) & PathOfTheConfigurationFileRelativeToHome

	try
		set theRawText to (read (POSIX file theConfigurationPath) as «class utf8»)
	on error
		-- No settings file is not an error here. The run will fail later with a
		-- message that says what to do about it, which beats an AppleScript
		-- error number at the moment the user presses a shortcut.
		return
	end try

	set theSavedDelimiters to AppleScript's text item delimiters

	try
		set AppleScript's text item delimiters to linefeed
		set theLines to text items of theRawText

		repeat with thisLine in theLines
			set thisLine to my TrimmedText(thisLine as text)

			if thisLine is not "" and thisLine does not start with "#" and thisLine contains "=" then
				set AppleScript's text item delimiters to "="
				set theParts to text items of thisLine
				set theKey to my TrimmedText(item 1 of theParts)

				-- Rejoin the rest: a value may legitimately contain "=".
				set AppleScript's text item delimiters to "="
				set theValue to my TrimmedText((items 2 thru -1 of theParts) as text)

				set end of TheRememberedSettings to {theKey, theValue}
				set AppleScript's text item delimiters to linefeed
			end if
		end repeat
	on error
		set TheRememberedSettings to {}
	end try

	set AppleScript's text item delimiters to theSavedDelimiters
end LoadTheSettings

on TrimmedText(theText)
	set theResult to theText as text

	repeat while theResult is not "" and (character 1 of theResult is " " or character 1 of theResult is tab or character 1 of theResult is return)
		set theResult to text 2 thru -1 of theResult
	end repeat

	repeat while theResult is not "" and (character -1 of theResult is " " or character -1 of theResult is tab or character -1 of theResult is return)
		set theResult to text 1 thru -2 of theResult
	end repeat

	return theResult
end TrimmedText

-- Every address you send mail FROM, from the settings file.
--
-- This is how the routine knows a message is yours, and it drives two things:
-- you are not added as a Contactperson on your own mail, and a task made from a
-- message you sent is phrased as something the RECIPIENT must deliver rather
-- than something you must do.
property TheRememberedPersonalAddresses : missing value

on MyPersonalEmailAddresses()
	if TheRememberedPersonalAddresses is not missing value then return TheRememberedPersonalAddresses

	set TheRememberedPersonalAddresses to {}

	set theRawValue to my TheSettingNamed("my_email_addresses", "")
	if theRawValue is "" then return TheRememberedPersonalAddresses

	set theSavedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to ","

	repeat with thisAddress in (text items of theRawValue)
		set thisAddress to my TrimmedText(thisAddress as text)
		if thisAddress is not "" then set end of TheRememberedPersonalAddresses to thisAddress
	end repeat

	set AppleScript's text item delimiters to theSavedDelimiters

	return TheRememberedPersonalAddresses
end MyPersonalEmailAddresses


--------------------------------------------------------------------------------
-- Paths and exchange files
--
-- The path to the helper is kept RELATIVE to the home folder here, and turned
-- into an absolute one by FullPathOfTheShellHelper(). The reason: the path is
-- handed over through "quoted form of", which wraps it in single quotes, and
-- inside single quotes the shell does not expand $HOME. A path like
-- "$HOME/bin/..." then looks for a file literally called $HOME:
--     /bin/zsh: can't open input file: $HOME/bin/mailtotana-helper.sh
-- So never leave a shell variable in here.
--------------------------------------------------------------------------------
property PathOfTheShellHelperRelativeToHome : "bin/mailtotana-helper.sh"
property PathOfTheInputExchangeFile : "/tmp/mailtotana-in.txt"
property PathOfTheOutputExchangeFile : "/tmp/mailtotana-out.txt"

--------------------------------------------------------------------------------
-- Showing progress
--
-- Two notifications: one when the run starts, one when the clipboard has been
-- filled. Both through "display notification", so they appear in the corner and
-- disappear by themselves.
--
-- Deliberately NOT "display alert". That is a modal window, so it lands in the
-- middle of the screen on top of whatever you were doing. Only a real failure
-- deserves that, and there is one for exactly that case: a notification cuts
-- long text off, and the cause of a shell error is at the end of it.
--
-- A floating window was tried, one that stayed up for the whole run with a
-- spinner in it. Showing it worked; getting rid of it did not. An Automator
-- workflow runs in a sandbox and may not send signals to processes outside its
-- own group: both "kill" on the process number and "pkill -f" on the script name
-- failed silently, and the windows stayed until their own timeout expired.
-- Measured with a sample every half second. A notification does not have that
-- problem, because it goes away on its own.
--------------------------------------------------------------------------------


on FullPathOfTheShellHelper()

	-- POSIX path of (path to home folder) already ends in a slash
	return (POSIX path of (path to home folder)) & PathOfTheShellHelperRelativeToHome

end FullPathOfTheShellHelper




--------------------------------------------------------------------------------
-- Separators for the exchange file
--
-- ASCII control characters rather than JSON. Escaping JSON by hand in AppleScript
-- breaks on the quotes, backslashes, tabs and emoji that turn up in mail bodies.
-- These characters do not occur in mail text, so splitting on them at the Python
-- end is lossless and needs no escaping at all.
--------------------------------------------------------------------------------
property RecordSeparator : character id 30 -- RS, between messages
property UnitSeparator : character id 31 -- US, between the fields of a message
property GroupSeparator : character id 29 -- GS, between multiple recipients


--------------------------------------------------------------------------------
-- The most messages one run will process
--
-- Tana's own documentation on Tana Paste: "It is not designed for inputting
-- large amounts of information." The ceiling started at fifty and came down to
-- twenty, for two reasons:
--
--   * Tana takes roughly 0.2 seconds over every node it creates. Twenty messages
--     is easily two hundred nodes, so some forty seconds of waiting.
--   * Every message is part of a paid API call. A selection that gets out of
--     hand by accident should not burn credits.
--
-- Which is why the check sits BEFORE the helper is called rather than inside it:
-- by the time the helper runs, the money has been spent.
--------------------------------------------------------------------------------
-- Ceiling on one run, from the settings file. Checked BEFORE any paid API
-- call, so a stray selection of a hundred messages costs nothing.
property TheRememberedMaximum : missing value

on MaximumNumberOfMessagesPerRun()
	if TheRememberedMaximum is missing value then
		try
			set TheRememberedMaximum to (my TheSettingNamed("maximum_messages_per_run", "20")) as integer
		on error
			set TheRememberedMaximum to 20
		end try
	end if
	return TheRememberedMaximum
end MaximumNumberOfMessagesPerRun


--------------------------------------------------------------------------------
-- MAIN ROUTINE
--
-- Processes the selected message and expands the thread around it through the
-- References and In-Reply-To headers.
--
-- A second mode was planned, "bulk", which would have processed exactly the
-- messages you clicked without expanding anything. It was dropped. Tana needs
-- roughly 0.2 seconds per node it creates, and a thread of ten messages is
-- already 107 nodes and some 24 seconds of waiting. Bulk would produce large
-- selections by its nature and so land in that range as a matter of course.
-- Walking through a selection with the shortcut turns out to be pleasanter than
-- one long wait.
--------------------------------------------------------------------------------
--
-- TWO AXES, THREE SHORTCUTS
--
-- theRequestedDestination is "clipboard" or "today":
--
--   clipboard : the result goes on the clipboard and you paste it where you want
--   today     : the helper writes it straight under today's day node through
--               Tana Outliner's local API
--
-- theOutputType is "message" or "task":
--
--   message : one node per mail. Documenting; an archive you can search.
--   task    : ONE task with a briefing complete enough to start work from
--             without opening the mail. Getting things done.
--
-- Everything up to that point is shared: the same selection, the same thread
-- expansion, the same Contacts lookups, the same exchange file. They only part
-- ways inside the Python helper, and what differs there is the INSTRUCTION to
-- the model: compress for an archive, against complete enough to act on.
--
-- So a change has to be made only ONCE. The three Quick Actions the installer
-- puts down differ in these two parameters and in their shortcut, nothing else;
-- there is no second copy of the code anywhere. Of the four possible
-- combinations only three are installed on purpose: a task on the clipboard has
-- no point, because a task is something you want in Tana.
--
-- If delivery into Tana fails, the helper falls back to the clipboard and says
-- why. A summary that has already been made, and paid for, must not be lost
-- because Tana happened to be closed.
--------------------------------------------------------------------------------
on MailToTanaMainRoutine(theRequestedDestination, theOutputType)

	local theSelectedMessages -- everything selected in Mail
	local theMessagesToProcess -- the messages that will actually be processed
	local theExchangeFileContent -- the complete text for the exchange file
	local theRecordForThisMessage -- the record for a single message
	local theNumberOfMessages -- counter, for the notifications
	local theShellCommandToRun -- the call into the shell helper
	local theGeneratedTanaPaste -- the end result, ready for the clipboard
	local thisMessage -- loop variable over the messages to process
	local theHelperReport -- the last line the helper reports
	local theActualDestination -- where it actually ended up
	local theFallbackReason -- why it was not the destination that was asked for


	----------------------------------------------------------------------------
	-- Read the selection and check there is one
	----------------------------------------------------------------------------
	tell application "Mail"
		set theSelectedMessages to selection
	end tell -- application "Mail"

	if (count of theSelectedMessages) is 0 then
		display notification "No message selected." with title "MailToTana" sound name "Basso"
		return
	end if -- (count of theSelectedMessages) is 0


	----------------------------------------------------------------------------
	-- Say that we have started
	--
	-- Here, and not after the gathering: on a long thread
	-- CollectThreadMessagesFor searches two mailboxes per predecessor, and does
	-- so in silence. The notification closes itself; there is nothing to dismiss.
	----------------------------------------------------------------------------
	display notification "Gathering and summarising..." with title "MailToTana" sound name "Tink"


	----------------------------------------------------------------------------
	-- What you pointed at, plus everything that led up to it
	--
	-- The References header only ever points BACKWARDS, never at replies. So the
	-- expansion starts from the NEWEST selected message; the whole chain hangs
	-- below that one.
	--
	-- Then the rest of your selection is added. An earlier version used only
	-- "item 1" of the selection and threw the rest away. Select a cluster of two
	-- with the older one on top and it processed only that older one, and your
	-- own reply vanished: a reply is a successor, and successors do not appear in
	-- References.
	--
	-- This is NOT the old bulk variant. That one processed a selection WITHOUT
	-- expanding any thread, and was a Quick Action of its own. Here: what you
	-- point at counts, and its history comes along.
	----------------------------------------------------------------------------
	set theMessagesToProcess to my CollectThreadMessagesFor(my TheNewestOf(theSelectedMessages))
	set theMessagesToProcess to my WithTheSelectionAdded(theMessagesToProcess, theSelectedMessages)
	set theMessagesToProcess to my SortedByDate(theMessagesToProcess)

	set theNumberOfMessages to count of theMessagesToProcess

	----------------------------------------------------------------------------
	-- The ceiling, and deliberately HERE
	--
	-- Before the helper is called, because that is what costs money: every
	-- message is part of a paid API call. Stopping after the helper has run is
	-- stopping after you have paid.
	----------------------------------------------------------------------------
	if theNumberOfMessages > (my MaximumNumberOfMessagesPerRun()) then
		try
			display alert "MailToTana: too many messages" message ((theNumberOfMessages as text) & " messages in this thread or selection, and the limit is " & ((my MaximumNumberOfMessagesPerRun()) as text) & "." & return & return & "Nothing has been processed and no API credits have been used." & return & return & "Select a smaller part of the chain and try again.") as warning giving up after 20
		end try
		return
	end if -- theNumberOfMessages > (my MaximumNumberOfMessagesPerRun())

	----------------------------------------------------------------------------
	-- Build the exchange file
	----------------------------------------------------------------------------
	set theExchangeFileContent to ""

	repeat with thisMessage in theMessagesToProcess

		set theRecordForThisMessage to my BuildExchangeRecordForMessage(thisMessage)

		if theExchangeFileContent is "" then
			set theExchangeFileContent to theRecordForThisMessage
		else
			set theExchangeFileContent to theExchangeFileContent & RecordSeparator & theRecordForThisMessage
		end if -- theExchangeFileContent is ""

	end repeat -- thisMessage in theMessagesToProcess

	my WriteTextToFileAsUtf8(theExchangeFileContent, PathOfTheInputExchangeFile)


	----------------------------------------------------------------------------
	-- Call the shell helper: Keychain, Claude API, building the Tana Paste
	--
	-- Absolute paths are mandatory here: do shell script runs /bin/sh with a bare
	-- environment and does not inherit the user's PATH.
	----------------------------------------------------------------------------
	-- Remove the output file first. Without this, the output of the PREVIOUS run
	-- survives whenever the helper exits cleanly but writes nothing, and you then
	-- paste the summary of a different message without noticing. A wrong result
	-- is worse than an error message.
	try
		do shell script "/bin/rm -f " & quoted form of PathOfTheOutputExchangeFile
	end try

	set theShellCommandToRun to "/bin/zsh " & quoted form of my FullPathOfTheShellHelper() & " " & quoted form of PathOfTheInputExchangeFile & " " & quoted form of PathOfTheOutputExchangeFile & " " & quoted form of theRequestedDestination & " " & quoted form of theOutputType

	try
		-- On its last line the helper reports where the result actually ENDED UP.
		-- With "today" the paste has already been delivered and there is nothing
		-- left to do here; with "clipboard" a reason may follow, separated by a
		-- tab.
		set theHelperReport to do shell script theShellCommandToRun
	on error theErrorMessage number theErrorNumber
		-- A dialog on purpose, not a notification: a notification cuts long text
		-- off, and with a shell error the cause is at the very end. The text in a
		-- dialog can be selected and copied.
		display alert "MailToTana: the helper failed" message ("Error number " & theErrorNumber & return & return & theErrorMessage & return & return & "Command:" & return & theShellCommandToRun) as critical
		return
	end try


	----------------------------------------------------------------------------
	-- Work out where it actually ended up
	----------------------------------------------------------------------------
	set theActualDestination to my TextBeforeTheTab(theHelperReport)
	set theFallbackReason to my TextAfterTheTab(theHelperReport)

	if theActualDestination is "today" then

		-- The helper has already put it under the day node. Bring Tana forward,
		-- because that is where you need to be now: a message that has just come
		-- in is something you want to link to something or move into a project,
		-- and you do that in Tana. If it is already in front, nothing changes.
		--
		-- The clipboard variant does the same, for the same reason.
		tell application "Tana Outliner" to activate

		if theOutputType is "task" then
			-- Naming the number of messages would mislead here: ONE task came out
			-- of it, however long the thread was.
			display notification "Task added to Today in Tana, from " & (theNumberOfMessages as text) & " message(s)." with title "MailToTask" sound name "Glass"
		else
			display notification (theNumberOfMessages as text) & " message(s) added to Today in Tana." with title "MailToTana" sound name "Glass"
		end if -- theOutputType is "task"

		return

	end if -- theActualDestination is "today"


	----------------------------------------------------------------------------
	-- Otherwise: the clipboard. Either asked for, or as a fallback.
	----------------------------------------------------------------------------
	set theGeneratedTanaPaste to my ReadTextFromFileAsUtf8(PathOfTheOutputExchangeFile)

	if theGeneratedTanaPaste is "" then
		display notification "The helper produced no Tana Paste." with title "MailToTana" sound name "Basso"
		return
	end if -- theGeneratedTanaPaste is ""

	-- Plain text on purpose. Tana Paste is a text format that Tana parses as it
	-- is pasted; if a rich text variant is on the clipboard as well, Tana may
	-- prefer that one and you get the formatting in your node instead of the
	-- structure. On top of that, {rich text:...} is not a valid record key
	-- outside a tell block of an app that knows the term.
	set the clipboard to theGeneratedTanaPaste

	tell application "Tana Outliner" to activate

	-- "as text" is mandatory here. With a number to the LEFT of the &, AppleScript
	-- produces a list rather than text, and display notification refuses it:
	-- {2, " message(s) ready..."} cannot be coerced to Unicode text. With text on
	-- the left it is fine; with a number it is not.
	if theFallbackReason is "" then

		display notification (theNumberOfMessages as text) & " message(s) ready. Paste with Cmd+V on the node you want." with title "MailToTana" sound name "Glass"

	else

		-- The result exists, just not where you asked for it. A DIALOG on
		-- purpose rather than a notification: a notification cuts off, and here
		-- two things both have to land -- that nothing was lost, AND that you now
		-- have to paste it yourself. A missed notification leaves you hunting
		-- through Tana for something that is sitting on your clipboard.
		try
			display alert "MailToTana: could not reach Tana" message (theFallbackReason & return & return & (theNumberOfMessages as text) & " message(s) are on the clipboard." & return & "Go to the node you want in Tana and paste with Cmd+V.") as warning giving up after 15
		end try

	end if -- theFallbackReason is ""

end MailToTanaMainRoutine


--------------------------------------------------------------------------------
-- Taking the helper's report apart
--
-- Shape: "today" or "clipboard", optionally followed by a tab and a reason.
--------------------------------------------------------------------------------
on TextBeforeTheTab(theText)

	local theOffset

	set theOffset to the offset of tab in theText

	if theOffset is 0 then
		return theText
	end if -- theOffset is 0

	if theOffset is 1 then
		return ""
	end if -- theOffset is 1

	return text 1 thru (theOffset - 1) of theText

end TextBeforeTheTab


on TextAfterTheTab(theText)

	local theOffset

	set theOffset to the offset of tab in theText

	if theOffset is 0 or theOffset is (count of characters of theText) then
		return ""
	end if -- theOffset is 0 or aan het eind

	return text (theOffset + 1) thru -1 of theText

end TextAfterTheTab


--------------------------------------------------------------------------------
-- When a message was sent
--
-- "date sent" is when the sender sent it, which is more meaningful than
-- "date received", which depends on when your client happened to fetch it. Same
-- order of preference as in BuildExchangeRecordForMessage.
--------------------------------------------------------------------------------
on TheDateOf(theMessage)

	tell application "Mail"
		try
			return date sent of theMessage
		on error
			try
				return date received of theMessage
			on error
				return (current date)
			end try
		end try
	end tell -- application "Mail"

end TheDateOf


--------------------------------------------------------------------------------
-- The Message-ID, so messages can be compared
--
-- Comparing the object references themselves is unreliable: the same message can
-- arrive as two different references, one from the selection and one from the
-- mailbox search. The Message-ID is the identity.
--------------------------------------------------------------------------------
on TheIdentifierOf(theMessage)

	tell application "Mail"
		try
			return message id of theMessage
		on error
			return ""
		end try
	end tell -- application "Mail"

end TheIdentifierOf


--------------------------------------------------------------------------------
-- The newest message in a list
--
-- The thread is expanded from this one, because References only points at
-- predecessors. Start at an older message and you miss everything after it.
--------------------------------------------------------------------------------
on TheNewestOf(theMessages)

	local theNewestMessage
	local theNewestDate
	local thisDate
	local thisMessage

	set theNewestMessage to item 1 of theMessages
	set theNewestDate to my TheDateOf(theNewestMessage)

	repeat with thisMessage in theMessages
		set thisDate to my TheDateOf(thisMessage)
		if thisDate > theNewestDate then
			set theNewestDate to thisDate
			set theNewestMessage to contents of thisMessage
		end if -- thisDate > theNewestDate
	end repeat -- thisMessage in theMessages

	return theNewestMessage

end TheNewestOf


--------------------------------------------------------------------------------
-- Add the selection to what the thread expansion already found
--
-- Only what is not already there, recognised by Message-ID.
--------------------------------------------------------------------------------
on WithTheSelectionAdded(theCollectedMessages, theSelectedMessages)

	local theResult
	local theKnownIdentifiers
	local thisIdentifier
	local thisMessage

	set theResult to theCollectedMessages
	set theKnownIdentifiers to {}

	repeat with thisMessage in theCollectedMessages
		set end of theKnownIdentifiers to my TheIdentifierOf(thisMessage)
	end repeat -- thisMessage in theCollectedMessages

	repeat with thisMessage in theSelectedMessages
		set thisIdentifier to my TheIdentifierOf(thisMessage)
		if thisIdentifier is not in theKnownIdentifiers then
			set end of theResult to contents of thisMessage
			set end of theKnownIdentifiers to thisIdentifier
		end if -- thisIdentifier is not in theKnownIdentifiers
	end repeat -- thisMessage in theSelectedMessages

	return theResult

end WithTheSelectionAdded


--------------------------------------------------------------------------------
-- Sort chronologically, oldest first
--
-- Needed since the selection is merged in. Before that the order came from the
-- References header, which happens to be chronological; for a merged set that no
-- longer holds, and you would get messages out of order on your day page.
--
-- Insertion sort: AppleScript has no sort function, and for at most twenty
-- messages this was quicker to write than anything else.
--------------------------------------------------------------------------------
on SortedByDate(theMessages)

	local theResult
	local theDates
	local thisMessage
	local thisDate
	local thePosition
	local theIndex

	set theResult to {}
	set theDates to {}

	repeat with thisMessage in theMessages

		set thisMessage to contents of thisMessage
		set thisDate to my TheDateOf(thisMessage)

		-- find where this message belongs
		set thePosition to (count of theResult) + 1
		repeat with theIndex from 1 to (count of theResult)
			if thisDate < (item theIndex of theDates) then
				set thePosition to theIndex
				exit repeat
			end if -- thisDate < (item theIndex of theDates)
		end repeat -- theIndex from 1 to (count of theResult)

		if thePosition > (count of theResult) then

			set end of theResult to thisMessage
			set end of theDates to thisDate

		else if thePosition is 1 then

			-- Inserting at the front needs its OWN branch. To AppleScript
			-- "items 1 thru 0" is not an empty list but an error, "can't be
			-- retrieved", which cost one failed run on a thread of five.
			set theResult to {thisMessage} & theResult
			set theDates to {thisDate} & theDates

		else

			set theResult to (items 1 thru (thePosition - 1) of theResult) & {thisMessage} & (items thePosition thru -1 of theResult)
			set theDates to (items 1 thru (thePosition - 1) of theDates) & {thisDate} & (items thePosition thru -1 of theDates)

		end if -- thePosition > (count of theResult)

	end repeat -- thisMessage in theMessages

	return theResult

end SortedByDate


--------------------------------------------------------------------------------
-- Turn one message into a record for the exchange file
--
-- Field order, separated by UnitSeparator:
--   1 messageId      Message-ID without angle brackets; the helper builds the
--                    message:// URL from this
--   2 dateTimestamp  "YYYY-MM-DD HH:MM", from date sent (falls back to received)
--   3 senderName     name from Contacts, otherwise the bare email address
--   4 recipients     names of the to-recipients, separated by GroupSeparator
--   5 subject        subject line, unchanged
--   6 body           the full plain text of the message
--   7 senderIsMe     "1" when you are the sender, otherwise empty. This drives
--                    only the Contactperson field; the name in field 3 stays, so
--                    the title still knows who wrote it.
--------------------------------------------------------------------------------
on BuildExchangeRecordForMessage(theMessage)

	local theMessageIdentifier -- Message-ID of this message
	local theMessageTimestamp -- date and time in Tana notation
	local theMessageDate -- the raw date of the message
	local theSenderEmailAddress -- the sender's email address
	local theSenderDisplayName -- the sender's name, if we know it
	local theListOfRecipientAddresses -- all to-addresses
	local theRecipientDisplayNames -- their names, GS-separated
	local thisRecipientEmailAddress -- loop variable over the recipients
	local thisRecipientDisplayName -- the name for one recipient
	local theMessageSubject -- subject line
	local theMessageBody -- the plain text of the message
	local theSenderIsMyself -- "1" when you are the sender, otherwise empty

	tell application "Mail"

		-- Message-ID. Mail gives it without angle brackets; the helper adds the
		-- encoded brackets when it builds the message:// URL.
		try
			set theMessageIdentifier to message id of theMessage
		on error
			set theMessageIdentifier to ""
		end try

		-- Date. "date sent" is when the sender sent it, which is more meaningful
		-- than "date received", which depends on when your mail client happened
		-- to fetch it.
		-- "current date" as the last resort: without a date,
		-- FormatDateAsTanaTimestamp below fails on a missing value, and then one
		-- message with a broken header takes the whole run down with it
		try
			set theMessageDate to date sent of theMessage
		on error
			try
				set theMessageDate to date received of theMessage
			on error
				set theMessageDate to (current date)
			end try
		end try

		try
			set theSenderEmailAddress to extract address from sender of theMessage
		on error
			set theSenderEmailAddress to ""
		end try

		try
			set theMessageSubject to subject of theMessage
		on error
			set theMessageSubject to ""
		end try

		try
			set theMessageBody to content of theMessage
		on error
			set theMessageBody to ""
		end try

		-- Only the to-recipients, on purpose: people on cc are rarely the contact
		-- for the conversation and would clutter the field. A message without
		-- to-recipients (a draft, or bcc only) gives an empty list.
		try
			set theListOfRecipientAddresses to address of to recipients of theMessage
		on error
			set theListOfRecipientAddresses to {}
		end try

	end tell -- application "Mail"

	set theMessageTimestamp to my FormatDateAsTanaTimestamp(theMessageDate)


	----------------------------------------------------------------------------
	-- Sender: always a name, plus a flag saying whether it was you
	--
	-- Those two are deliberately SEPARATE, because they drive different things.
	-- An earlier version blanked the name for your own mail, which did both at
	-- once: no Contactperson (right) but also no name in the title (wrong). A
	-- reply you sent should read "Alex Moreau: confirms that ..."; that you wrote
	-- it is exactly the information. It is only the Contactperson field you do
	-- not belong in: that you were involved in your own mail adds nothing.
	----------------------------------------------------------------------------
	set theSenderDisplayName to my FindFullNameForEmailAddress(theSenderEmailAddress)

	if theSenderEmailAddress is in my MyPersonalEmailAddresses() then
		set theSenderIsMyself to "1"
	else
		set theSenderIsMyself to ""
	end if -- theSenderEmailAddress is in my MyPersonalEmailAddresses()


	----------------------------------------------------------------------------
	-- Recipients: the same, and do not list the sender twice
	--
	-- Tana Paste does not support two inline references to the same node from one
	-- node, so duplicate names have to go before we get there.
	----------------------------------------------------------------------------
	set theRecipientDisplayNames to ""

	repeat with thisRecipientEmailAddress in theListOfRecipientAddresses

		set thisRecipientEmailAddress to thisRecipientEmailAddress as string

		if thisRecipientEmailAddress is not in my MyPersonalEmailAddresses() then

			set thisRecipientDisplayName to my FindFullNameForEmailAddress(thisRecipientEmailAddress)

			if thisRecipientDisplayName is not equal to theSenderDisplayName then

				if theRecipientDisplayNames is "" then
					set theRecipientDisplayNames to thisRecipientDisplayName
				else
					set theRecipientDisplayNames to theRecipientDisplayNames & GroupSeparator & thisRecipientDisplayName
				end if -- theRecipientDisplayNames is ""

			end if -- thisRecipientDisplayName is not equal to theSenderDisplayName

		end if -- thisRecipientEmailAddress is not in my MyPersonalEmailAddresses()

	end repeat -- thisRecipientEmailAddress in theListOfRecipientAddresses


	return theMessageIdentifier & UnitSeparator & theMessageTimestamp & UnitSeparator & theSenderDisplayName & UnitSeparator & theRecipientDisplayNames & UnitSeparator & theMessageSubject & UnitSeparator & theMessageBody & UnitSeparator & theSenderIsMyself

end BuildExchangeRecordForMessage


-- This run's memory: two parallel lists, because AppleScript has no dictionary.
-- With a handful of addresses per run, a linear search beats anything cleverer.
property TheRememberedAddresses : {}
property TheRememberedNames : {}


--------------------------------------------------------------------------------
-- Look up a name for an email address in the Contacts app
--
-- Returns the name it found, or the address unchanged when Contacts knows
-- nothing. The caller always gets something usable back.
--
-- Lowercasing the address matters: searching on an email address in Contacts is
-- case sensitive.
--------------------------------------------------------------------------------
on FindFullNameForEmailAddress(theEmailAddressToLookUp)

	local theFoundName -- the name as Contacts knows it
	local theLowercasedAddress -- the address in lower case, for the search
	local thisIndex -- loop variable over the memory

	-- safety net: whatever goes wrong, the caller keeps a usable value
	set theFoundName to theEmailAddressToLookUp

	if theEmailAddressToLookUp does not contain "@" then
		return theEmailAddressToLookUp
	end if -- theEmailAddressToLookUp does not contain "@"

	----------------------------------------------------------------------------
	-- Check this run's memory first
	--
	-- This is the most expensive step in the whole chain. Measured with 1471
	-- cards in Contacts: 20 lookups took 15 seconds, so over 0.7 seconds each,
	-- because "whose value of emails contains" walks every card.
	--
	-- The same people keep turning up in a thread: ten messages with three people
	-- involved is forty lookups for a handful of unique addresses. Remembering
	-- within the run takes most of that away. For comparison: scanning a mailbox
	-- of 981 messages costs 0.25 seconds, so one Contacts lookup is three times
	-- as expensive as walking a whole mailbox.
	--
	-- Deliberately NO memory that survives between runs: a name you correct in
	-- Contacts has to be right on the very next run. The property starts empty
	-- every time, because the script is loaded fresh with "load script".
	--
	-- The key is the RAW address as Mail hands it over, not the lowercased one.
	-- That saves a character loop over the address on every hit, and Mail gives
	-- the same address consistently within a thread. If an address does turn up
	-- in two spellings, it costs one extra lookup at most; the answer stays
	-- right.
	----------------------------------------------------------------------------
	repeat with thisIndex from 1 to (count of TheRememberedAddresses)
		if item thisIndex of TheRememberedAddresses is theEmailAddressToLookUp then
			return item thisIndex of TheRememberedNames
		end if -- item thisIndex of TheRememberedAddresses is theEmailAddressToLookUp
	end repeat -- thisIndex from 1 to (count of TheRememberedAddresses)

	my EnsureTheContactsAppIsRunning()

	set theLowercasedAddress to my LowercasedTextOf(theEmailAddressToLookUp)

	-- The address goes into the query in lower case, because searching on an
	-- email address is case sensitive. Without this, an address like
	-- "Pieter.Jansen@example.com" misses a card that holds it in lower case.
	tell application "Contacts"
		try
			set theFoundName to name of (first person whose value of emails contains theLowercasedAddress)
		on error
			-- Contacts does not know this address. The ADDRESS stays here, on
			-- purpose. The helper can do more with it than we can: it also sees
			-- the mail's signature, and a real name from there beats one derived
			-- from the address. Only when there is no signature does the helper
			-- derive one. See derive_name_from_email_address in the helper.
			set theFoundName to theLowercasedAddress
		end try
	end tell -- application "Contacts"

	-- remember a FAILED lookup too: an address Contacts does not know costs the
	-- full search time again on every repeat, and within this run the answer is
	-- not going to change
	set end of TheRememberedAddresses to theEmailAddressToLookUp
	set end of TheRememberedNames to theFoundName

	return theFoundName

end FindFullNameForEmailAddress


--------------------------------------------------------------------------------
-- Make sure Contacts is running
--
-- Without this, every lookup fails with "Contacts got an error: Application
-- isn't running" (-600). That error lands in the try above, the bare email
-- address stays, and the Contactperson field in Tana links to nothing. It once
-- cost a whole thread: all three messages came out with addresses instead of
-- names while the cards were sitting in Contacts all along.
--
-- Contacts is deliberately LEFT RUNNING afterwards. Anyone sending mail to Tana
-- rarely does it once, and starting and quitting the app costs time on every
-- run. And if you had Contacts open yourself, it is not this script's business
-- to close it on you.
--
-- Check whether it is running before starting it. The "is running" property of
-- an application does NOT launch the app, unlike almost every other call; that
-- is exactly what the property is for.
--
-- Checked once per run. A property in a script loaded with "load script" starts
-- from its source value every run, so this remembers nothing between runs.
--------------------------------------------------------------------------------
property TheContactsAppHasBeenChecked : false


on EnsureTheContactsAppIsRunning()

	if TheContactsAppHasBeenChecked then
		return
	end if -- TheContactsAppHasBeenChecked

	set TheContactsAppHasBeenChecked to true

	try
		if not (application "Contacts" is running) then
			-- "launch" and not "activate": the app comes alive but not to the front
			tell application "Contacts" to launch
		end if -- not (application "Contacts" is running)
	end try

end EnsureTheContactsAppIsRunning


--------------------------------------------------------------------------------
-- Lowercase a piece of text
--
-- AppleScript has nothing for this, and calling out to the shell is too
-- expensive: this runs per sender and per recipient of every message in a
-- thread.
--
-- ASCII only, which is enough: email addresses are made of it.
--------------------------------------------------------------------------------
property UppercaseAlphabet : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
property LowercaseAlphabet : "abcdefghijklmnopqrstuvwxyz"


on LowercasedTextOf(theText)

	local theResult -- the converted text
	local thisCharacter -- loop variable over the characters
	local theOffset -- positie van het teken in het hoofdletteralfabet

	set theResult to ""

	repeat with thisCharacter in theText

		set theOffset to the offset of thisCharacter in UppercaseAlphabet

		if theOffset is not 0 then
			set theResult to theResult & (character theOffset of LowercaseAlphabet)
		else
			set theResult to theResult & thisCharacter
		end if -- theOffset is not 0

	end repeat -- thisCharacter in theText

	return theResult

end LowercasedTextOf




--------------------------------------------------------------------------------
-- Collect all the messages of a thread
--
-- Apple Mail has no conversation or thread object in its dictionary, so this
-- follows RFC 5322: the References header of a message holds the Message-IDs of
-- every predecessor in the thread, In-Reply-To that of the direct one.
--
-- A deliberate limitation: this gives you the HISTORY, not the replies that came
-- after this message. So select the newest message of a thread and you have the
-- whole chain. Finding replies would need a full scan of every mailbox, and is
-- not worth it for this.
--
-- The search covers the mailbox the message is in, plus the Sent mailbox of the
-- same account, because that is where your own replies live.
--
-- A deliberate choice, and not one to widen: the search space stays those two
-- mailboxes. Archive folders and other accounts are NOT searched. Only what is
-- visible in your online mail environment counts, so a thread that partly sits
-- in an archive comes in incomplete, and that is intended. Any widening costs a
-- scan over mailboxes that do not matter and makes the running time
-- unpredictable.
--------------------------------------------------------------------------------
on CollectThreadMessagesFor(theStartingMessage)

	local theRawHeaderBlock -- the full header of the starting message
	local theListOfReferencedIds -- Message-IDs of every predecessor
	local theCollectedMessages -- the result, oldest first
	local theMailboxOfTheMessage -- the mailbox the starting message is in
	local theAccountOfTheMessage -- the account that mailbox belongs to
	local theMailboxesToSearch -- the mailboxes we search
	local theFoundMessages -- search result per Message-ID
	local thisReferencedId -- loop variable over the Message-IDs found
	local thisMailbox -- loop variable over the mailboxes to search
	local theIdOfTheStartingMessage -- to recognise a self-reference

	set theCollectedMessages to {}

	tell application "Mail"

		try
			set theRawHeaderBlock to all headers of theStartingMessage
		on error
			set theRawHeaderBlock to ""
		end try

		-- Some clients put their own Message-ID in the References header. Without
		-- this check the starting message then appears twice in the Tana Paste:
		-- once as a predecessor and once at the end.
		try
			set theIdOfTheStartingMessage to message id of theStartingMessage
		on error
			set theIdOfTheStartingMessage to ""
		end try

		try
			set theMailboxOfTheMessage to mailbox of theStartingMessage
		on error
			-- without a mailbox there is nothing to search; just this message
			return {theStartingMessage}
		end try

		set theMailboxesToSearch to {theMailboxOfTheMessage}

		-- add your own Sent mailbox, if it can be found
		try
			set theAccountOfTheMessage to account of theMailboxOfTheMessage
			set end of theMailboxesToSearch to (sent mailbox of theAccountOfTheMessage)
		on error
			-- no account attached (a local "On My Mac" mailbox, say); then search
			-- only the mailbox the message is in
		end try

	end tell -- application "Mail"

	set theListOfReferencedIds to my ExtractMessageIdsFromRawHeaders(theRawHeaderBlock)


	----------------------------------------------------------------------------
	-- Find the message belonging to each Message-ID we found
	----------------------------------------------------------------------------
	repeat with thisReferencedId in theListOfReferencedIds

		set thisReferencedId to thisReferencedId as string

		-- skip a self-reference; the starting message is added at the end anyway
		if thisReferencedId is not theIdOfTheStartingMessage then

			repeat with thisMailbox in theMailboxesToSearch

				tell application "Mail"
					try
						set theFoundMessages to (every message of thisMailbox whose message id is thisReferencedId)
					on error
						set theFoundMessages to {}
					end try
				end tell -- application "Mail"

				if (count of theFoundMessages) > 0 then
					set end of theCollectedMessages to (item 1 of theFoundMessages)
					exit repeat
				end if -- (count of theFoundMessages) > 0

			end repeat -- thisMailbox in theMailboxesToSearch

		end if -- thisReferencedId is not theIdOfTheStartingMessage

	end repeat -- thisReferencedId in theListOfReferencedIds


	-- the starting message closes the line: References are in chronological
	-- order, so this gives oldest first with the selected message last
	set end of theCollectedMessages to theStartingMessage

	return theCollectedMessages

end CollectThreadMessagesFor


--------------------------------------------------------------------------------
-- Pull Message-IDs out of the References and In-Reply-To headers
--
-- Headers may be folded over several lines: a continuation line starts with a
-- space or a tab. Those are unfolded into one line first, and then the tokens
-- between angle brackets are taken out.
--
-- The brackets themselves come off, because Mail's "message id" property gives
-- the ID without them and that is what we have to compare against.
--------------------------------------------------------------------------------
on ExtractMessageIdsFromRawHeaders(theRawHeaderBlock)

	local theUnfoldedHeaderLines -- headers with their continuation lines attached
	local theReferencesHeaderText -- the complete References header
	local theInReplyToHeaderText -- the complete In-Reply-To header
	local theRelevantHeaderText -- both, References first
	local theListOfMessageIds -- the result, oldest predecessor first
	local theTextBetweenBrackets -- one Message-ID without its brackets
	local thisHeaderLine -- loop variable over the header lines
	local theSavedDelimiters -- to put the text item delimiters back
	local theBracketFragments -- pieces of text after splitting on "<"
	local thisBracketFragment -- loop variable over those pieces

	set theListOfMessageIds to {}

	if theRawHeaderBlock is "" then
		return theListOfMessageIds
	end if -- theRawHeaderBlock is ""


	----------------------------------------------------------------------------
	-- Unfold, and keep the two relevant headers apart
	--
	-- Apart, rather than in the order they appear: the order within the header
	-- block is not fixed and differs per mail client. References holds the whole
	-- chain in chronological order, In-Reply-To only the direct predecessor.
	-- Putting References first always means the oldest predecessor comes first,
	-- and the thread lands in Tana in the right order.
	----------------------------------------------------------------------------
	set theUnfoldedHeaderLines to ""
	set theReferencesHeaderText to ""
	set theInReplyToHeaderText to ""

	repeat with thisHeaderLine in (paragraphs of theRawHeaderBlock)

		set thisHeaderLine to thisHeaderLine as string

		if thisHeaderLine starts with " " or thisHeaderLine starts with tab then
			-- continuation of the previous header: stick it on
			set theUnfoldedHeaderLines to theUnfoldedHeaderLines & " " & thisHeaderLine
		else
			-- a new header starts: write the previous one out first
			if theUnfoldedHeaderLines starts with "References:" then
				set theReferencesHeaderText to theReferencesHeaderText & " " & theUnfoldedHeaderLines
			else if theUnfoldedHeaderLines starts with "In-Reply-To:" then
				set theInReplyToHeaderText to theInReplyToHeaderText & " " & theUnfoldedHeaderLines
			end if -- theUnfoldedHeaderLines starts with "References:"
			set theUnfoldedHeaderLines to thisHeaderLine
		end if -- thisHeaderLine starts with " " or tab

	end repeat -- thisHeaderLine in (paragraphs of theRawHeaderBlock)

	-- the last header falls outside the loop and has to be written out here
	if theUnfoldedHeaderLines starts with "References:" then
		set theReferencesHeaderText to theReferencesHeaderText & " " & theUnfoldedHeaderLines
	else if theUnfoldedHeaderLines starts with "In-Reply-To:" then
		set theInReplyToHeaderText to theInReplyToHeaderText & " " & theUnfoldedHeaderLines
	end if -- theUnfoldedHeaderLines starts with "References:"

	set theRelevantHeaderText to theReferencesHeaderText & " " & theInReplyToHeaderText

	if theRelevantHeaderText does not contain "<" then
		return theListOfMessageIds
	end if -- theRelevantHeaderText does not contain "<"


	----------------------------------------------------------------------------
	-- Take out the tokens between angle brackets
	----------------------------------------------------------------------------
	set theSavedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "<"
	set theBracketFragments to text items of theRelevantHeaderText
	set AppleScript's text item delimiters to theSavedDelimiters

	repeat with thisBracketFragment in theBracketFragments

		set thisBracketFragment to thisBracketFragment as string

		if thisBracketFragment contains ">" then

			set theSavedDelimiters to AppleScript's text item delimiters
			set AppleScript's text item delimiters to ">"
			set theTextBetweenBrackets to text item 1 of thisBracketFragment
			set AppleScript's text item delimiters to theSavedDelimiters

			-- de-duplicate: a Message-ID can appear in both References and
			-- In-Reply-To
			if theTextBetweenBrackets is not "" and theTextBetweenBrackets is not in theListOfMessageIds then
				set end of theListOfMessageIds to theTextBetweenBrackets
			end if -- not empty and not already known

		end if -- thisBracketFragment contains ">"

	end repeat -- thisBracketFragment in theBracketFragments

	return theListOfMessageIds

end ExtractMessageIdsFromRawHeaders


--------------------------------------------------------------------------------
-- Turn a date into the notation Tana Paste expects
--
-- Tana Paste takes "[[date:2026-06-10 14:30]]" for a date with a time. This
-- returns only the inner part; the helper puts the brackets around it.
--------------------------------------------------------------------------------
on FormatDateAsTanaTimestamp(theDateToFormat)

	local theYearNumber -- year, four digits
	local theMonthNumber -- month number, 1 through 12
	local theDayNumber -- day of the month
	local theHourNumber -- hours, 24-hour clock
	local theMinuteNumber -- minutes

	set theYearNumber to year of theDateToFormat
	set theMonthNumber to (month of theDateToFormat) as integer
	set theDayNumber to day of theDateToFormat
	set theHourNumber to hours of theDateToFormat
	set theMinuteNumber to minutes of theDateToFormat

	return (theYearNumber as string) & "-" & my PadNumberToTwoDigits(theMonthNumber) & "-" & my PadNumberToTwoDigits(theDayNumber) & " " & my PadNumberToTwoDigits(theHourNumber) & ":" & my PadNumberToTwoDigits(theMinuteNumber)

end FormatDateAsTanaTimestamp


--------------------------------------------------------------------------------
-- Pad a number out to two digits with a leading zero
--------------------------------------------------------------------------------
on PadNumberToTwoDigits(theNumberToPad)

	if theNumberToPad < 10 then
		return "0" & (theNumberToPad as string)
	else
		return theNumberToPad as string
	end if -- theNumberToPad < 10

end PadNumberToTwoDigits


--------------------------------------------------------------------------------
-- Write text to a file as UTF-8
--
-- The explicit «class utf8» is needed: AppleScript strings are UTF-16 inside,
-- and without this coercion accents and emoji land in the file mangled.
--------------------------------------------------------------------------------
on WriteTextToFileAsUtf8(theTextToWrite, thePosixPathToWriteTo)

	local theFileReference -- handle van het geopende bestand

	set theFileReference to open for access (POSIX file thePosixPathToWriteTo) with write permission

	try
		set eof theFileReference to 0
		write theTextToWrite to theFileReference as «class utf8»
	on error theErrorMessage number theErrorNumber
		close access theFileReference
		error theErrorMessage number theErrorNumber
	end try

	close access theFileReference

	-- Readable by you only. This file holds the FULL text of the mail, and /tmp
	-- is open to every local user; with the default permissions (644) any other
	-- account on this Mac could read your post.
	try
		do shell script "/bin/chmod 600 " & quoted form of thePosixPathToWriteTo
	end try

end WriteTextToFileAsUtf8


--------------------------------------------------------------------------------
-- Read text from a file as UTF-8
--
-- Returns empty text when the file does not exist or is empty, so the caller can
-- treat that as the error condition.
--------------------------------------------------------------------------------
on ReadTextFromFileAsUtf8(thePosixPathToReadFrom)

	local theFileContent -- de gelezen tekst

	try
		set theFileContent to (read (POSIX file thePosixPathToReadFrom) as «class utf8»)
	on error
		set theFileContent to ""
	end try

	return theFileContent

end ReadTextFromFileAsUtf8


--------------------------------------------------------------------------------
-- Running it straight from Script Editor, for testing
--
-- Ignored when the script is called through "load script": the workflow stub
-- then calls MailToTanaMainRoutine() directly, with the destination belonging to
-- that Quick Action.
--------------------------------------------------------------------------------
on run
	MailToTanaMainRoutine("clipboard", "message")
end run
